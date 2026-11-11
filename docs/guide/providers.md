---
description: Connect a provider with an API key, an account login, or a local model server.
---

# Providers

Edit `~/.config/yuke/providers.json` to add a provider or change a built-in one. Without this file, yuke uses the built-in providers. To use another folder, see [Configuration](config.md).

## Credentials

| Source | Credential |
|---|---|
| `/login` in yuke | An API key or an account login. yuke stores it in `auth.json` in the [data folder](config.md). |
| `yuke login <provider>` | An account login. yuke stores it in `auth.json`. |
| The provider variable | An API key from the environment, such as `ANTHROPIC_API_KEY`. |
| An RPC client | An API key or a login through `auth/set_api_key` or `auth/login`, or a token through `credential/update`. See the [protocol reference](https://github.com/lostcoords/yuke/blob/main/crates/protocol/README.md). |

A stored API key takes priority over the variable.

| Provider | Variable |
|---|---|
| `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |
| `deepseek` | `DEEPSEEK_API_KEY` |
| `groq` | `GROQ_API_KEY` |
| `xai` | `XAI_API_KEY` |
| `mistral` | `MISTRAL_API_KEY` |
| `togetherai` | `TOGETHER_API_KEY` |
| `cerebras` | `CEREBRAS_API_KEY` |
| `fireworks-ai` | `FIREWORKS_API_KEY` |
| `minimax` | `MINIMAX_API_KEY` |
| `opencode`, `opencode-go` | `OPENCODE_API_KEY` |

Run `/logout` or `yuke logout <provider>` to remove a stored credential. To stop using a variable, unset it. To revoke a token, revoke it at the provider.

The catalog reports these states:

| State | Meaning |
|---|---|
| `ready` | The provider needs no credential, or a credential is present. `credential` names it: `none`, `variable`, `stored_api_key`, or `login`. yuke does not test the credential. |
| `needs_api_key` | The provider variable is unset or unusable, and no API key is stored. |
| `needs_login` | No stored login or pushed access token is present. |

## Add a provider

This example adds a gateway:

```json
{
  "providers": [{
    "id": "gateway",
    "base_url": "https://gateway.example/v1",
    "api_key_env": "GATEWAY_API_KEY",
    "endpoints": [{
      "protocol": "openai_chat",
      "credential_header": "authorization_bearer"
    }],
    "models": [{ "id": "big", "upstream_id": "vendor/big" }]
  }]
}
```

yuke reads the key from `GATEWAY_API_KEY` or from `/login`.

Use `/reload` to reload the profile after an edit. The reload fails while a turn runs. A failed reload keeps the previous providers and plugins.

### Local server

If the server needs no credential, omit `api_key_env` and `credential_header`:

```json
{
  "providers": [{
    "id": "local",
    "base_url": "http://127.0.0.1:8080/v1",
    "endpoints": [{ "protocol": "openai_chat" }],
    "models": [{ "id": "my-model" }]
  }]
}
```

## Change a built-in provider

Write an entry with the ID of a [built-in provider](https://github.com/lostcoords/yuke/blob/main/crates/ai/src/catalog/generated.rs). yuke **keeps** the built-in value of each field that you omit. When you write `endpoints` or a model entry, yuke **replaces** the built-in one **as a whole**. If you replace `endpoints`, keep an endpoint for the protocol of each model.

For example, this entry sends OpenAI requests through a proxy:

```json
{
  "providers": [{ "id": "openai", "base_url": "http://127.0.0.1:8080/v1" }]
}
```

## Fields

The file accepts JSON with `//` and `/* */` comments. The schema is strict. Unknown fields, duplicate IDs, and bad routes stop startup.

Each entry of the `providers` list accepts these fields.

### Provider fields

| Field | Meaning |
|---|---|
| `id` | Required. A nonempty ID with no `/`, whitespace, or control character. |
| `name` | Display name. A new provider defaults to its ID. |
| `base_url` | An `http` or `https` URL with a host and no user, query, or fragment. Required for a new provider. |
| `api_key_env` | The environment variable for an API key. A built-in provider keeps its variable when omitted. A new provider needs no credential when omitted. OAuth providers cannot set this field. |
| `endpoints` | Protocol endpoints. Required for a new provider. Each protocol appears at most once. |
| `headers` | Extra headers as `[{ "name": "x-team", "value": "core" }]`. Header names and values must be valid. yuke writes values as is, with no variable expansion. A header must not replace a header that yuke writes: the credential and session headers, and `accept`, `accept-encoding`, `connection`, `content-length`, `content-type`, `host`, `te`, `transfer-encoding`, `upgrade`, and `user-agent`. |
| `session_header` | `none` (default for a new provider), `session_id`, or `x_opencode_session`. |
| `models` | Model entries. Required for a new provider. |

Use `api_key_env` for an API-key route. For an account login, use a built-in OAuth provider.

### Endpoint fields

| Field | Meaning |
|---|---|
| `protocol` | Required: `anthropic_messages` (`/messages`), `openai_chat` (`/chat/completions`), or `openai_responses` (`/responses`). yuke appends the protocol path to the base URL. |
| `credential_header` | `x_api_key`, `authorization_bearer`, or `api_key`. Required when the provider sends a credential, including an account login. Omit it for a provider that needs no credential. |
| `cache_breakpoint` | Boolean, default `false`. Mark an explicit prompt-cache breakpoint. `openai_chat` does not support this field set to `true`. |
| `responses_dialect` | `standard` (default) or `codex`. Only on `openai_responses`. |
| `chat_dialect` | `standard` (default) or `mistral`. Only on `openai_chat`. |

### Model fields

| Field | Meaning |
|---|---|
| `id` | Required. The model part of the selector. It can contain `/`, but not whitespace or control characters. |
| `upstream_id` | The model name that the host receives. Defaults to `id`. |
| `name` | Display name. Defaults to `id`. |
| `protocol` | Required when the provider has more than one endpoint. Otherwise, defaults to the only endpoint's protocol. |
| `limits` | `context_window` and `max_output_tokens`. Omitted values are unknown. |
| `cost` | Price bands in USD per million tokens. Omitted prices are unknown, not zero. See [Cost](#cost). |
| `reasoning_levels` | The efforts that the model takes, from `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. `/model` offers `default`, `off`, and these efforts. An empty list accepts any effort, but `/model` then offers only `default` and `off`. The `default` choice sends no control. |
| `flags` | Protocol behavior and capability facts. See below. |

### Model flags

| Flag | Meaning |
|---|---|
| `supports_tool_search` | Boolean. Whether the model supports deferred tool search. The protocol and route must also support it. |
| `can_disable_reasoning` | Boolean. `false` rejects an explicit off choice. |
| `supports_cache_breakpoint` | Boolean. Whether the model accepts an explicit cache marker. |
| `thinking_format` | Chat Completions format: `none`, `openai`, `openrouter`, `deepseek`, `zai`, or `qwen`. Default: `none`. |
| `reasoning_replay` | Chat Completions replay: `none`, `reasoning_content`, or `reasoning_details`. Default: `none`. |
| `max_tokens_field` | Chat Completions output limit field: `max_tokens` (default) or `max_completion_tokens`. |
| `anthropic_thinking` | Messages thinking shape: `toggle`, `adaptive`, or `budget`. |
| `reasoning_budget_min`, `reasoning_budget_max` | Optional bounds for `anthropic_thinking: "budget"`. |

Omitted capability facts are unknown.

For `anthropic_messages`, a named reasoning level uses this shape:

| `anthropic_thinking` | Request |
|---|---|
| absent | Set `output_config.effort` to the level. |
| `toggle` | Send `thinking: { "type": "adaptive" }`, without an effort or display field. |
| `adaptive` | Send `thinking: { "type": "adaptive", "display": "summarized" }` and set `output_config.effort`. |
| `budget` | Send `thinking: { "type": "enabled", "budget_tokens": 16000 }`, kept within the configured bounds and at least 1024. The budget must be below `limits.max_output_tokens`. Otherwise, yuke sets `output_config.effort`. |

An allowed off choice sends `thinking: { "type": "disabled" }`. The default choice sends no reasoning control.

### Cost

`cost` is a list of price bands. The first band starts at `0`; you can omit `min_prompt_tokens` there. Each later band starts at a higher prompt size. Prices must not be negative.

| Band field | Meaning |
|---|---|
| `min_prompt_tokens` | The smallest prompt size that uses the band. |
| `input`, `output` | Prices for uncached input tokens and output tokens. |
| `reasoning` | Price for reasoning tokens. Use the output price when the vendor bills reasoning at that rate. |
| `cache_read`, `cache_write` | Prices for cached input tokens and tokens written to the prompt cache. |

The prompt size includes cached input tokens. The last band that the prompt reaches prices the whole request. A missing price stays unknown. For example:

```json
"cost": [
  { "input": 4, "output": 20, "reasoning": 20, "cache_read": 0.4, "cache_write": 5 },
  { "min_prompt_tokens": 272001, "input": 8, "output": 30, "reasoning": 30, "cache_read": 0.8, "cache_write": 10 }
]
```

## Failure diagnostics

CLI startup errors go to stderr. Runtime notices reach the terminal UI or the RPC client. A headless task reports a failed turn through its exit status and, with `--json`, its `end` value.

Capture the error from your command or client. Check the provider's service status and the route configuration before you retry. Do not publish credentials or private task content in a diagnostic report.
