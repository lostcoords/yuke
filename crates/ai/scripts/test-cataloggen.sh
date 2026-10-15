#!/usr/bin/env bash
# Pin the translator's string encoding and nullable value semantics without network I/O.
set -euo pipefail

scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
crate=$(cd -- "$scripts/.." && pwd)
workspace=$(cd -- "$crate/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
# The fixture builds inside a copy of the workspace, and shares its target directory for the dependencies.
mkdir -p "$tmp/crates/ai"
cp -- "$workspace/Cargo.toml" "$workspace/Cargo.lock" "$tmp/"
cp -- "$crate/Cargo.toml" "$tmp/crates/ai/"
cp -R -- "$crate/src" "$tmp/crates/ai/src"
cp -R -- "$crate/examples" "$tmp/crates/ai/examples"

cat > "$tmp/catalog.json" <<'JSON'
{
  "catalog_rev": "fixture",
  "providers": [{
    "id": "fixture",
    "name": "quote \" slash \\ literal \\b \b\f\n\r\t\u0000\u001b café 🚀",
    "auth": {"kind": "api_key", "env": null},
    "base_url": "https://fixture.invalid/v1",
    "headers": [{"name": "x-fixture", "value": "quote \" value"}],
    "session_header": "none",
    "endpoints": [
      {"protocol": "anthropic_messages", "key_header": "x_api_key", "cache": "anthropic_breakpoint", "responses_dialect": "standard", "chat_dialect": "standard"},
      {"protocol": "openai_chat", "key_header": null, "cache": null, "responses_dialect": "standard", "chat_dialect": "mistral"}
    ],
    "models": [{
      "id": "selector-id", "upstream_id": "wire-id", "name": "Fixture", "protocol": "anthropic_messages",
      "limits": {"context_window": null, "max_output_tokens": 0},
      "cost": [{"min_prompt_tokens": 0, "input": 0, "output": null, "reasoning": 2.5, "cache_read": null, "cache_write": null}],
      "flags": {"supports_tools": false, "supports_tool_search": false, "supports_system_updates": false, "can_disable_reasoning": false, "anthropic_thinking": "budget", "reasoning_budget_min": -1, "reasoning_budget_max": 0, "thinking_format": "openrouter", "max_tokens_field": "max_completion_tokens"},
      "modalities": {"input": ["text", "image", "future-kind"], "output": []},
      "reasoning_levels": [null, "high", "future-level"]
    }]
  }]
}
JSON

# An OAuth endpoint selects bearer format even when the source names another key header.
jq '.providers[0].models += [
      (.providers[0].models[0] | .id = "supported" | .flags.supports_system_updates = true),
      (.providers[0].models[0] | .id = "absent" | del(.flags.supports_system_updates)),
      (.providers[0].models[0] | .id = "null" | .flags.supports_system_updates = null)
    ] | .providers += [(.providers[0] | .id = "oauth-fixture" | .auth = {kind: "oauth", flow: "fixture"})]' \
    "$tmp/catalog.json" > "$tmp/input.json"
bash "$scripts/generate-catalog.sh" "$tmp/input.json" "$tmp/crates/ai/src/catalog/fixture.rs"
cat > "$tmp/crates/ai/src/catalog/fixture_test.rs" <<'RUST'
//! Regression check for the catalog translator.
use super::fixture::PROVIDERS;
use super::AnthropicThinking;
use crate::request::{ChatDialect, Effort, MaxTokensField, Modality, ReasoningReplayMode, ThinkingFormat};
use crate::route::CredentialHeader;

#[test]
fn catalog_translation_preserves_strings_nulls_false_and_zero() {
    let provider = &PROVIDERS[0];
    let model = &provider.models[0];
    assert_eq!(super::fixture::REVISION, "fixture");
    assert_eq!(provider.name, "quote \" slash \\ literal \\b \u{8}\u{c}\n\r\t\0\u{1b} café 🚀");
    assert_eq!(provider.auth, super::Auth::ApiKey(None));
    assert_eq!(provider.headers, &[crate::transport::Header::from_static("x-fixture", "quote \" value")]);
    assert_eq!(provider.endpoints[0].credential_header, Some(CredentialHeader::XApiKey));
    assert_eq!(provider.endpoints[1].credential_header, None);
    assert_eq!(provider.endpoints[1].chat_dialect, ChatDialect::Mistral);
    for endpoint in PROVIDERS[1].endpoints {
        assert_eq!(endpoint.credential_header, Some(CredentialHeader::AuthorizationBearer));
    }
    assert_eq!(model.id, "selector-id");
    assert_eq!(model.upstream_id, "wire-id");
    assert_eq!(model.caps.tools, Some(false));
    assert_eq!(model.caps.tool_search, Some(false));
    assert_eq!(model.caps.system_updates, Some(false));
    assert_eq!(provider.models[1].caps.system_updates, Some(true));
    assert_eq!(provider.models[2].caps.system_updates, None);
    assert_eq!(provider.models[3].caps.system_updates, None);
    assert_eq!(model.caps.disable_reasoning, Some(false));
    assert_eq!(model.caps.cache_breakpoint, None);
    assert_eq!(model.limits.context_window, None);
    assert_eq!(model.limits.max_output_tokens, Some(0));
    assert_eq!(model.cost[0].input, Some(0.0));
    assert_eq!(model.cost[0].output, None);
    // A Rust float literal needs its fraction, which an integral price lacks.
    assert_eq!(model.cost[0].reasoning, Some(2.5));
    assert_eq!(model.dialect.anthropic_thinking, AnthropicThinking::Budget { min: Some(-1), max: Some(0) });
    assert_eq!(model.dialect.chat.thinking_format, ThinkingFormat::Openrouter);
    assert_eq!(model.dialect.chat.reasoning_replay, ReasoningReplayMode::None);
    assert_eq!(model.dialect.chat.max_tokens_field, MaxTokensField::MaxCompletionTokens);
    // A null level means no effort, and a name outside the request efforts stays out.
    assert_eq!(model.reasoning_levels, &[None, Some(Effort::High)]);
    assert!(provider.endpoints[0].cache_breakpoint);
    assert!(!provider.endpoints[1].cache_breakpoint);
    assert_eq!(model.modalities.input, &[Modality::Text, Modality::Image]);
}
RUST
printf '\n#[cfg(test)]\nmod fixture;\n#[cfg(test)]\nmod fixture_test;\n' >> "$tmp/crates/ai/src/catalog.rs"
CARGO_TARGET_DIR="$workspace/target/cataloggen" "${CARGO:-cargo}" test --quiet \
    --manifest-path "$tmp/Cargo.toml" -p yuke-ai --lib catalog_translation_preserves

# A failed input must not replace the last generated table.
cp -- "$tmp/crates/ai/src/catalog/fixture.rs" "$tmp/expected.rs"
: > "$tmp/empty.json"
if bash "$scripts/generate-catalog.sh" "$tmp/empty.json" "$tmp/crates/ai/src/catalog/fixture.rs"; then
    printf 'empty input replaced the generated table\n' >&2
    exit 1
fi
cmp -- "$tmp/expected.rs" "$tmp/crates/ai/src/catalog/fixture.rs"
