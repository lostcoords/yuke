---
description: Connect cloud providers and local model servers with API keys or account logins.
---

# Providers

`providers.json` in the [profile](profile.md) changes built-in providers or adds providers, such as local servers. yuke reads it at startup and on profile reload. A missing file uses the built-in catalog.

Provider routes and credentials use separate files. `providers.json` holds routes, model facts, and API-key variable names. `auth.json` in the data directory holds stored credentials. Login and logout do not rewrite `providers.json`.

## Credentials

For an API-key provider, set its variable in the shell that starts yuke. An empty or non-UTF-8 variable counts as unset. A variable takes priority over a stored API key.

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

`openai-codex` and `xai-grok` use an account login:

```sh
yuke login openai-codex
yuke login xai-grok
```

Run the command for the provider that you want. Open the URL that it prints. Confirm the device code. yuke waits for approval and stores the login in `auth.json`.

`yuke login` requires a provider ID. It does not list providers or ask for API keys. For an API-key provider, it reports the variable to set. An RPC client can store an API key through `auth/set_api_key`.

`yuke logout <provider>` removes that provider's stored credential from `auth.json`. It does not unset a variable or revoke a token at the provider. A running server can keep a token supplied through `credential/update`. The RPC method `auth/logout` also clears that server's pushed token. See the [protocol reference](https://github.com/lostcoords/yuke/blob/main/crates/protocol/README.md).

The catalog reports these states:

| State | Meaning |
|---|---|
| `ready` | The provider needs no credential, or a credential is present. yuke does not test the credential. |
| `needs_api_key` | The provider variable is unset or unusable, and no API key is stored. |
| `needs_login` | No stored login or pushed access token is present. |

The default catalog lists ready providers. An RPC client can request all providers with `catalog/list` and `all: true`.

## The file

This example adds a gateway with two protocols:

```json
{
  "providers": [{
    "id": "gateway",
    "name": "Team gateway",
    "base_url": "https://gateway.example/v1",
    "api_key_env": "GATEWAY_API_KEY",
    "endpoints": [
      { "protocol": "anthropic_messages", "credential_header": "x_api_key", "cache_breakpoint": true },
      { "protocol": "openai_chat", "credential_header": "authorization_bearer" }
    ],
    "models": [
      { "id": "big", "upstream_id": "vendor/big", "protocol": "anthropic_messages", "limits": { "context_window": 200000, "max_output_tokens": 32000 } },
      { "id": "small", "upstream_id": "vendor/small", "protocol": "openai_chat", "reasoning_levels": [null, "high"] }
    ]
  }]
}
```

Set `GATEWAY_API_KEY` before you start yuke. Replace the example host and upstream model IDs with values that your gateway serves. The selector is `provider/model`, such as `gateway/big`.

The file accepts JSON with `//` and `/* */` comments. The schema is strict. Unknown fields, duplicate IDs, and bad routes stop startup. A written `null` is not an omitted provider field. Errors name the file and the bad field.

Use `/reload` to reload the profile after an edit. A failed reload keeps the previous providers and plugins.

Restrict access to this file if custom headers contain sensitive values. Keep secrets out of URLs and version control.

### Provider fields

| Field | Meaning |
|---|---|
| `id` | Required. A nonempty ID with no `/`, whitespace, or control character. |
| `name` | Display name. A new provider defaults to its ID. |
| `base_url` | An `http` or `https` URL with a host and no user, query, or fragment. Required for a new provider. |
| `api_key_env` | The environment variable for an API key. A built-in provider keeps its variable when omitted. A new provider needs no credential when omitted. OAuth providers cannot set this field. |
| `endpoints` | Protocol endpoints. Required for a new provider. Each protocol appears at most once. |
| `headers` | Extra headers as `[{ "name": "x-team", "value": "core" }]`. Header names and values must be valid. A header must not replace a credential or session header that yuke writes. |
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
| `reasoning_levels` | Named levels from `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. `null` lists an off choice. The default reasoning choice sends no control. |
| `flags` | Protocol behavior and capability facts. See below. |

### Model flags

| Flag | Meaning |
|---|---|
| `supports_tool_search` | Boolean. Whether the model supports deferred tool search. The protocol and route must also support it. |
| `can_disable_reasoning` | Boolean. `false` rejects an explicit off choice. |
| `supports_cache_breakpoint` | Boolean. Whether the model accepts an explicit cache marker. |
| `thinking_format` | Chat Completions format: `none`, `openai`, `openrouter`, `deepseek`, `zai`, `qwen`, `together`, or `ant_ling`. Default: `none`. |
| `reasoning_replay` | Chat Completions replay: `none`, `reasoning`, `reasoning_content`, or `reasoning_details`. Default: `none`. |
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
| `budget` | Send `thinking: { "type": "enabled", "budget_tokens": ... }` within the configured bounds. |

An allowed off choice sends `thinking: { "type": "disabled" }`. The default choice sends no reasoning control.

## Local server

A local server that needs no credential omits both `api_key_env` and `credential_header`:

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

Replace the port and model ID with those of your server. Then run a task:

```sh
yuke -p 'Say hello.' --model local/my-model --reasoning default
```

## Cost

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

## Change a built-in provider

An entry with a built-in `id` changes that provider. A written field replaces the built-in value. An omitted field keeps it. `endpoints` replaces the whole endpoint list. Each model entry replaces the whole model with that ID, or adds a new model. Models not listed stay unchanged.

For example, this entry sends all OpenAI model requests through a proxy while it keeps the built-in models and credential settings:

```json
{
  "providers": [{ "id": "openai", "base_url": "http://127.0.0.1:8080/v1" }]
}
```

## Failure diagnostics

CLI startup errors go to stderr. Runtime notices reach the terminal UI or the RPC client. A headless task reports a failed turn through its exit status and, with `--json`, its `end` value.

Capture the error from your command or client. Check the provider's service status and the route configuration before you retry. Do not publish credentials or private task content in a diagnostic report.
