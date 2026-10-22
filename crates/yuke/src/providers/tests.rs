use std::path::PathBuf;

use super::*;
use crate::config::without_comments;

fn built_in(id: &str) -> Provider {
    catalog::PROVIDERS
        .iter()
        .find(|provider| provider.id == id)
        .unwrap()
        .clone()
}

fn provider<'p>(providers: &'p Providers, id: &str) -> &'p Provider {
    providers.0.iter().find(|provider| provider.id == id).unwrap()
}

/// Parse the file text `text`, which can hold comments, and apply it to the built-in providers.
fn parse_text(text: &str) -> Result<Providers, String> {
    let file: File = serde_json::from_str(&without_comments(text)).map_err(|error| error.to_string())?;
    Providers::from_file(file)
}

/// The providers of a file with `entries` as its provider list.
fn parse(entries: &str) -> Result<Providers, String> {
    parse_text(&format!(r#"{{ "providers": [{entries}] }}"#))
}

fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("providers", name)
}

#[test]
fn a_missing_file_gives_the_built_in_providers_and_a_bad_file_names_its_path() {
    let folder = folder("load");

    assert_eq!(Providers::load(&folder), Ok(Providers(catalog::PROVIDERS.to_vec())));
    std::fs::write(folder.join("providers.json"), "{ \"providers\": 5 }").unwrap();
    let error = Providers::load(&folder).unwrap_err();
    assert!(
        error.starts_with(&format!("{}: invalid type", folder.join("providers.json").display())),
        "{error}"
    );
}

#[test]
fn a_written_field_replaces_the_built_in_value_and_an_omitted_one_keeps_it() {
    let providers = parse_text(
        r#"{
          // A proxy in front of OpenAI.
          "providers": [{
            "id": "openai", "base_url": "http://127.0.0.1:8080/v1", "name": "Proxy",
            "headers": [{ "name": "x-team", "value": "core" }], "session_header": "session_id"
          }]
        }"#,
    )
    .unwrap();

    let mut expected = built_in("openai");
    expected.base_url = "http://127.0.0.1:8080/v1".into();
    expected.name = "Proxy".into();
    expected.headers = vec![Header::new("x-team", "core")].into();
    expected.session_header = SessionHeader::SessionId;
    assert_eq!(provider(&providers, "openai"), &expected);
    assert_eq!(providers.0.len(), catalog::PROVIDERS.len());
}

#[test]
fn a_model_with_a_built_in_id_replaces_that_model_and_a_new_id_adds_one() {
    let providers = parse(
        r#"{ "id": "openai", "models": [
            { "id": "gpt-5.5", "upstream_id": "proxy-gpt", "limits": { "max_output_tokens": 1000 } },
            { "id": "mini", "name": "Mini", "reasoning_levels": [null, "high"],
              "cost": [{ "input": 1, "output": 2 }, { "min_prompt_tokens": 1000, "input": 3 }],
              "flags": { "supports_tool_search": true, "can_disable_reasoning": false,
                         "supports_cache_breakpoint": true } }
        ] }"#,
    )
    .unwrap();

    let openai = provider(&providers, "openai");
    let replaced = Model {
        id: "gpt-5.5".into(),
        upstream_id: "proxy-gpt".into(),
        name: "gpt-5.5".into(),
        protocol: Protocol::OpenaiResponses,
        limits: Limits {
            context_window: None,
            max_output_tokens: Some(1000),
        },
        cost: Cow::Borrowed(catalog::UNKNOWN_COST),
        caps: Caps::default(),
        reasoning_levels: Cow::Borrowed(&[]),
        dialect: Dialect::default(),
        modalities: catalog::Modalities::default(),
    };
    let added = Model {
        id: "mini".into(),
        upstream_id: "mini".into(),
        name: "Mini".into(),
        limits: Limits::default(),
        cost: vec![
            PriceBand {
                input: Some(1.0),
                output: Some(2.0),
                ..PriceBand::default()
            },
            PriceBand {
                min_prompt_tokens: 1000,
                input: Some(3.0),
                ..PriceBand::default()
            },
        ]
        .into(),
        reasoning_levels: vec![None, Some(Effort::High)].into(),
        caps: Caps {
            tool_search: Some(true),
            disable_reasoning: Some(false),
            cache_breakpoint: Some(true),
            ..Caps::default()
        },
        ..replaced.clone()
    };
    assert_eq!(providers.lookup("openai/gpt-5.5").unwrap().model, &replaced);
    assert_eq!(providers.lookup("openai/mini").unwrap().model, &added);
    let kept = built_in("openai");
    assert_eq!(openai.models.len(), kept.models.len() + 1);
    assert_eq!(
        providers.lookup("openai/gpt-5.6").unwrap().model,
        catalog::lookup_in(catalog::PROVIDERS, "openai/gpt-5.6").unwrap().model
    );
}

#[test]
fn endpoints_replace_the_whole_list_and_every_model_still_needs_one() {
    let providers = parse(
        r#"{ "id": "openai", "endpoints": [
            { "protocol": "openai_responses", "credential_header": "api_key", "responses_dialect": "codex" }
        ] }"#,
    )
    .unwrap();

    assert_eq!(
        *provider(&providers, "openai").endpoints,
        [Endpoint {
            protocol: Protocol::OpenaiResponses,
            credential_header: Some(CredentialHeader::ApiKey),
            cache_breakpoint: false,
            responses_dialect: ResponsesDialect::Codex,
            chat_dialect: ChatDialect::Standard,
        }]
    );
    assert_eq!(
        parse(r#"{ "id": "openai", "endpoints": [{ "protocol": "openai_chat", "credential_header": "api_key" }] }"#),
        Err(format!(
            "provider openai: model {}: the catalog provider declares no endpoint for the model protocol",
            built_in("openai").models[0].id
        ))
    );
}

#[test]
fn a_new_provider_takes_defaults_for_the_fields_that_it_omits() {
    let providers = parse(
        r#"{ "id": "local", "base_url": "http://127.0.0.1:8080/v1",
             "endpoints": [{ "protocol": "openai_chat", "chat_dialect": "mistral" },
                           { "protocol": "anthropic_messages", "cache_breakpoint": true }],
             "models": [
               { "id": "qwen/small", "protocol": "openai_chat", "flags": {
                 "thinking_format": "qwen", "reasoning_replay": "reasoning_content",
                 "max_tokens_field": "max_completion_tokens" } },
               { "id": "big", "protocol": "anthropic_messages", "limits": { "max_output_tokens": 64000 },
                 "flags": { "anthropic_thinking": "budget", "reasoning_budget_min": 1024, "reasoning_budget_max": 32000 } }
             ] }"#,
    )
    .unwrap();

    let local = provider(&providers, "local");
    assert_eq!(local.name, "local");
    assert_eq!(local.auth, Auth::ApiKey(None));
    assert_eq!(local.base_url, "http://127.0.0.1:8080/v1");
    assert_eq!(local.session_header, SessionHeader::None);
    assert!(local.headers.is_empty());
    let model = providers.lookup("local/qwen/small").unwrap().model;
    assert_eq!(model.upstream_id, "qwen/small");
    assert_eq!(model.protocol, Protocol::OpenaiChat);
    assert_eq!(
        model.dialect.chat,
        ChatFlags {
            thinking_format: ThinkingFormat::Qwen,
            reasoning_replay: ReasoningReplayMode::ReasoningContent,
            max_tokens_field: MaxTokensField::MaxCompletionTokens,
        }
    );
    assert_eq!(*model.cost, *catalog::UNKNOWN_COST);
    assert_eq!(
        providers.lookup("local/big").unwrap().model.dialect.anthropic_thinking,
        AnthropicThinking::Budget {
            min: Some(1024),
            max: Some(32000)
        }
    );
    assert_eq!(
        *local.endpoints,
        [
            Endpoint {
                protocol: Protocol::OpenaiChat,
                credential_header: None,
                cache_breakpoint: false,
                responses_dialect: ResponsesDialect::Standard,
                chat_dialect: ChatDialect::Mistral,
            },
            Endpoint {
                protocol: Protocol::AnthropicMessages,
                credential_header: None,
                cache_breakpoint: true,
                responses_dialect: ResponsesDialect::Standard,
                chat_dialect: ChatDialect::Standard,
            }
        ]
    );
}

#[test]
fn an_api_key_variable_replaces_the_key_of_a_built_in_provider() {
    let providers = parse(r#"{ "id": "openai", "api_key_env": "PROXY_KEY" }"#).unwrap();

    assert_eq!(
        provider(&providers, "openai").auth,
        Auth::ApiKey(Some("PROXY_KEY".into()))
    );
}

/// A valid new provider, with `changes` written over its fields.
fn local(changes: &serde_json::Value) -> String {
    let mut entry = serde_json::json!({
        "id": "local",
        "base_url": "http://h/v1",
        "endpoints": [{ "protocol": "anthropic_messages" }],
        "models": [{ "id": "m", "limits": { "max_output_tokens": 10 } }],
    });
    for (field, value) in changes.as_object().unwrap() {
        entry[field] = value.clone();
    }
    entry.to_string()
}

/// Check that each entry list stops the parse with its text.
fn assert_errors<const N: usize>(cases: [(String, &str); N]) {
    for (entries, expected) in cases {
        assert_eq!(parse(&entries), Err(expected.to_owned()), "{entries}");
    }
}

#[test]
fn a_bad_provider_field_stops_the_load_and_names_the_field() {
    assert_errors([
        (
            r#"{ "id": "a/b" }"#.to_owned(),
            "provider a/b: id: \"a/b\" must not be empty, and must have no white space, no control character, and no slash",
        ),
        (
            r#"{ "id": "" }"#.to_owned(),
            "provider : id: \"\" must not be empty, and must have no white space, no control character, and no slash",
        ),
        (
            r#"{ "id": "openai" }, { "id": "openai" }"#.to_owned(),
            "provider openai: the file has this id twice",
        ),
        (
            r#"{ "id": "local", "endpoints": [{ "protocol": "openai_chat" }], "models": [] }"#.to_owned(),
            "provider local: base_url: a new provider needs it",
        ),
        (
            r#"{ "id": "openai", "base_url": "ftp://h" }"#.to_owned(),
            "provider openai: base_url: the URL must start with http:// or https://",
        ),
        (
            r#"{ "id": "openai", "base_url": "https:///v1" }"#.to_owned(),
            "provider openai: base_url: the URL has no host",
        ),
        (
            r#"{ "id": "openai", "base_url": "https://u@h/v1" }"#.to_owned(),
            "provider openai: base_url: the URL must have no user",
        ),
        (
            r#"{ "id": "openai", "base_url": "http://h:bad/v1" }"#.to_owned(),
            "provider openai: base_url: the URL port must be a number from 0 to 65535",
        ),
        (
            r#"{ "id": "openai", "base_url": "https://h/v1?a=1" }"#.to_owned(),
            "provider openai: base_url: the URL must have no query and no fragment",
        ),
        (
            r#"{ "id": "openai", "base_url": "https://h/v 1" }"#.to_owned(),
            "provider openai: base_url: the URL must have no white space and no control character",
        ),
        (
            r#"{ "id": "xai-grok", "api_key_env": "XAI_KEY" }"#.to_owned(),
            "provider xai-grok: api_key_env: the provider uses a login of `yuke login`",
        ),
        (
            r#"{ "id": "openai", "api_key_env": "" }"#.to_owned(),
            "provider openai: api_key_env: \"\" is not a variable name: write a name with no '=' and no NUL",
        ),
        (
            r#"{ "id": "openai", "endpoints": [] }"#.to_owned(),
            "provider openai: endpoints: the list is empty",
        ),
    ]);
}

#[test]
fn a_bad_endpoint_or_header_stops_the_load_and_names_the_field() {
    assert_errors([
        (
            r#"{ "id": "openai", "endpoints": [
                { "protocol": "openai_responses", "credential_header": "api_key" },
                { "protocol": "openai_responses", "credential_header": "api_key" }] }"#
                .to_owned(),
            "provider openai: endpoints[1].protocol: another endpoint has this protocol",
        ),
        (
            r#"{ "id": "openai", "endpoints": [{ "protocol": "openai_chat", "cache_breakpoint": true }] }"#.to_owned(),
            "provider openai: endpoints[0].cache_breakpoint: Chat Completions has no breakpoint",
        ),
        (
            r#"{ "id": "openai", "endpoints": [{ "protocol": "openai_chat", "responses_dialect": "codex" }] }"#
                .to_owned(),
            "provider openai: endpoints[0].responses_dialect: only an openai_responses endpoint takes it",
        ),
        (
            r#"{ "id": "openai", "endpoints": [{ "protocol": "openai_responses", "chat_dialect": "mistral" }] }"#
                .to_owned(),
            "provider openai: endpoints[0].chat_dialect: only an openai_chat endpoint takes it",
        ),
        (
            r#"{ "id": "openai", "endpoints": [{ "protocol": "openai_responses" }] }"#.to_owned(),
            "provider openai: endpoints[0].credential_header: the provider sends a credential, so name its header",
        ),
        (
            local(
                &serde_json::json!({ "endpoints": [{ "protocol": "anthropic_messages", "credential_header": "x_api_key" }] }),
            ),
            "provider local: endpoints[0].credential_header: the provider sends no credential: set api_key_env, or \
             remove the header",
        ),
        (
            local(&serde_json::json!({ "headers": [{ "name": "content-type", "value": "x" }] })),
            "provider local: headers: 'content-type' is not a valid header name or value, or yuke writes this header \
             itself",
        ),
    ]);
}

#[test]
fn a_bad_model_stops_the_load_and_names_the_model_and_the_field() {
    assert_errors([
        (
            r#"{ "id": "openai", "models": [{ "id": "a" }, { "id": "a" }] }"#.to_owned(),
            "provider openai: model a: the provider has this id twice",
        ),
        (
            r#"{ "id": "openai", "models": [{ "id": "a b" }] }"#.to_owned(),
            "provider openai: model a b: id: \"a b\" must not be empty, and must have no white space, no control character",
        ),
        (
            r#"{ "id": "openai", "models": [{ "id": "a", "cost": [{ "min_prompt_tokens": 5 }] }] }"#.to_owned(),
            "provider openai: model a: cost: the first band starts at 0, each next band starts higher, and no price is \
             negative",
        ),
        (
            r#"{ "id": "openai", "models": [{ "id": "a", "flags": { "max_tokens_field": "max_tokens" } }] }"#
                .to_owned(),
            "provider openai: model a: flags: thinking_format, reasoning_replay, and max_tokens_field need the \
             openai_chat protocol",
        ),
        (
            r#"{ "id": "openai", "models": [{ "id": "a", "flags": { "anthropic_thinking": "toggle" } }] }"#.to_owned(),
            "provider openai: model a: flags.anthropic_thinking: it needs the anthropic_messages protocol",
        ),
        (
            local(&serde_json::json!({
                "models": [{ "id": "m", "flags": { "anthropic_thinking": "adaptive", "reasoning_budget_max": 9 } }]
            })),
            "provider local: model m: flags: the reasoning budget needs \"anthropic_thinking\": \"budget\"",
        ),
        (
            local(&serde_json::json!({ "models": [{ "id": "m" }] })),
            "provider local: model m: the catalog model names no output limit, which its protocol requires",
        ),
        (
            r#"{ "id": "local", "base_url": "http://h/v1", "models": [{ "id": "m" }],
                 "endpoints": [{ "protocol": "openai_chat" }, { "protocol": "openai_responses" }] }"#
                .to_owned(),
            "provider local: model m: protocol: the provider has more than one endpoint, so name one",
        ),
    ]);
}

#[test]
fn an_unknown_field_or_value_is_an_error() {
    for (entries, expected) in [
        (r#"{ "id": "openai", "base_ur": "x" }"#, "unknown field `base_ur`"),
        (
            r#"{ "id": "openai", "models": [{ "id": "a", "flags": { "vision": true } }] }"#,
            "unknown field `vision`",
        ),
        (
            r#"{ "id": "openai", "models": [{ "id": "a", "cost": [{ "inptu": 1 }] }] }"#,
            "unknown field `inptu`",
        ),
        (
            r#"{ "id": "openai", "session_header": "cookie" }"#,
            "unknown variant `cookie`",
        ),
        (
            r#"{ "id": "openai", "models": [{ "id": "a", "reasoning_levels": ["huge"] }] }"#,
            "unknown variant `huge`",
        ),
    ] {
        let error = parse(entries).unwrap_err();
        assert!(error.contains(expected), "{entries}: {error}");
    }
    assert!(
        parse_text(r#"{ "provider": [] }"#)
            .unwrap_err()
            .contains("unknown field `provider`")
    );
}

#[test]
fn an_entry_with_only_the_id_of_a_built_in_provider_keeps_that_provider() {
    for built_in in catalog::PROVIDERS {
        let providers = parse(&format!(r#"{{ "id": "{}" }}"#, built_in.id)).unwrap();
        assert_eq!(provider(&providers, &built_in.id), built_in);
    }
}

#[test]
fn a_written_null_is_an_error_and_keeps_no_built_in_value() {
    for field in [
        "name",
        "api_key_env",
        "base_url",
        "headers",
        "session_header",
        "endpoints",
        "models",
    ] {
        // Without the check, a null reads as an omitted field and the parse succeeds.
        let parsed = parse(&format!(r#"{{ "id": "openai", "{field}": null }}"#));
        assert!(parsed.is_err(), "{field}");
    }
}

#[test]
fn a_changed_login_provider_keeps_its_login_and_other_providers_have_none() {
    let providers = parse(
        r#"{ "id": "xai-grok", "base_url": "http://[::1]:8080/v1" },
           { "id": "local", "base_url": "http://h/v1", "endpoints": [{ "protocol": "openai_chat" }], "models": [] }"#,
    )
    .unwrap();

    let (provider, flow) = providers.login("xai-grok").unwrap();
    assert_eq!(flow, Flow::Xai);
    assert_eq!(provider.base_url, "http://[::1]:8080/v1");
    let supported = providers.login_providers();
    assert_eq!(
        providers.login("local").unwrap_err(),
        format!("yuke has no login for local. {supported}")
    );
    assert_eq!(
        providers.login("openai").unwrap_err(),
        format!("openai takes an API key: set OPENAI_API_KEY. {supported}")
    );
    assert!(
        supported.contains("xai-grok") && supported.contains("openai-codex"),
        "{supported}"
    );
}
