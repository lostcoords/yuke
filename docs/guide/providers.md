---
description: Connect a provider with an API key, an account login, or a local model server.
---

# Providers

Edit `~/.config/yuke/providers.json` to add a provider or change a built-in one. Without this file, yuke uses the built-in providers. To use another folder, see [Configuration](config.md).

## Credentials

Use `/login` in yuke to store an API key or an account login in `auth.json` in the [data folder](config.md). Set the provider variable to use an API key from the environment. A stored API key takes priority over the variable.

| Provider | Credential |
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
| `openai-codex` | ChatGPT account login |
| `xai-grok` | xAI (Grok) account login |

An account login uses a device code: open the page that yuke shows, enter the code, and confirm. You can also run `yuke login openai-codex` or `yuke login xai-grok` from the shell.

Run `/logout` or `yuke logout <provider>` to remove a stored login or API key. A variable stays: to stop using it, unset it.

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

The file accepts JSON with `//` and `/* */` comments. Unknown fields, duplicate IDs, and bad routes stop startup.

### Provider fields

| Field | Meaning |
|---|---|
| `id` | Required. It has no `/`, whitespace, or control character. |
| `name` | Display name. Defaults to the ID. |
| `base_url` | An `http` or `https` URL. Required for a new provider. |
| `api_key_env` | The environment variable for an API key. Omit it for a provider that needs no credential. |
| `endpoints` | Protocol endpoints. Required for a new provider. Each protocol appears at most once. |
| `headers` | Extra headers as `[{ "name": "x-team", "value": "core" }]`. A header must not replace a header that yuke writes. |
| `session_header` | `none` (default), `session_id`, or `x_opencode_session`. |
| `models` | Model entries. Required for a new provider. |

### Endpoint fields

| Field | Meaning |
|---|---|
| `protocol` | Required: `anthropic_messages` (`/messages`), `openai_chat` (`/chat/completions`), or `openai_responses` (`/responses`). yuke appends the protocol path to the base URL. |
| `credential_header` | `x_api_key`, `authorization_bearer`, or `api_key`. Required when the provider sends a credential. |
| `cache_breakpoint` | Boolean, default `false`. Marks an explicit prompt-cache breakpoint. `openai_chat` does not support `true`. |
| `responses_dialect` | `standard` (default) or `codex`. Only on `openai_responses`. |
| `chat_dialect` | `standard` (default) or `mistral`. Only on `openai_chat`. |

### Model fields

| Field | Meaning |
|---|---|
| `id` | Required. The model part of the selector. It has no whitespace or control character. |
| `upstream_id` | The model name that the host receives. Defaults to `id`. |
| `name` | Display name. Defaults to `id`. |
| `protocol` | Required when the provider has more than one endpoint. |
| `limits` | `context_window` and `max_output_tokens`. Omitted values are unknown. |
| `cost` | Price bands in USD per million tokens. See [Cost](#cost). |
| `reasoning_levels` | The efforts that the model takes, from `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. |
| `flags` | Capability facts. Omitted facts are unknown. See below. |

`/model` offers `default`, each effort of `reasoning_levels`, and `off` when the model can turn reasoning off.

### Model flags

| Flag | Meaning |
|---|---|
| `supports_tool_search` | Whether the model supports deferred tool search. |
| `can_disable_reasoning` | `false` rejects an explicit off choice. |
| `supports_cache_breakpoint` | Whether the model accepts an explicit cache marker. |
| `thinking_format` | Chat Completions only: `none` (default), `openai`, `openrouter`, `deepseek`, `zai`, or `qwen`. |
| `reasoning_replay` | Chat Completions only: `none` (default), `reasoning_content`, or `reasoning_details`. |
| `max_tokens_field` | Chat Completions only: `max_tokens` (default) or `max_completion_tokens`. |
| `anthropic_thinking` | Messages only: `toggle`, `adaptive`, or `budget`. |
| `reasoning_budget_min`, `reasoning_budget_max` | Bounds for `anthropic_thinking: "budget"`. |

### Cost

`cost` is a list of price bands. The first band starts at `0`, so it can omit `min_prompt_tokens`. Each later band sets a higher `min_prompt_tokens`. The last band that the prompt size reaches prices the whole request. Prices are `input`, `output`, `reasoning`, `cache_read`, and `cache_write`. A missing price is unknown, not zero. For example:

```json
"cost": [
  { "input": 4, "output": 20, "cache_read": 0.4 },
  { "min_prompt_tokens": 272001, "input": 8, "output": 30, "cache_read": 0.8 }
]
```
