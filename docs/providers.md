# Providers

`providers.json` in the [profile](profile.md) holds credentials, changes a built-in provider, or adds a provider, such as a local server. yuke reads it at startup and on `/reload-providers`. A missing file is fine.

## Credentials

A built-in provider reads its key from a variable for each run. An empty variable counts as unset.

`anthropic` `ANTHROPIC_API_KEY` · `openai` `OPENAI_API_KEY` · `openrouter` `OPENROUTER_API_KEY` · `deepseek` `DEEPSEEK_API_KEY` · `groq` `GROQ_API_KEY` · `xai` `XAI_API_KEY` · `mistral` `MISTRAL_API_KEY` · `togetherai` `TOGETHER_API_KEY` · `cerebras` `CEREBRAS_API_KEY` · `fireworks-ai` `FIREWORKS_API_KEY` · `minimax` `MINIMAX_API_KEY` · `opencode`, `opencode-go` `OPENCODE_API_KEY`

`openai-codex` and `xai-grok` use an account login. A built-in provider with no entry in the file shows only when its variable holds a value or when it has an account login.

| Command | Does |
|---|---|
| `yuke login` | Lists each provider and its state. |
| `yuke login <provider>` | Starts the account login, or asks for a key. Writes the result to `providers.json`. |
| `yuke logout <provider>` | Removes the credential that the file holds. It cannot unset a variable. |
| `/login`, `/logout` | The same in the TUI. |

| State | Fix |
|---|---|
| `needs key` | Set the variable, or run `yuke login <provider>`. |
| `needs login` | Run `yuke login <provider>`. |
| `needs route` | A field is missing or two fields conflict. Fix the entry. |

## The file

```json
{
  "providers": [{
    "id": "gateway",
    "base_url": "https://gateway.example/v1",
    "endpoints": [
      { "protocol": "anthropic_messages", "key_header": "x_api_key", "cache": "anthropic_breakpoint" },
      { "protocol": "openai_chat", "key_header": "authorization_bearer" }
    ],
    "auth": { "api_key": { "source": { "env": "GATEWAY_API_KEY" } } },
    "models": [
      { "id": "big", "upstream_id": "vendor/big", "protocol": "anthropic_messages", "limits": { "context_window": 200000, "max_output_tokens": 32000 } },
      { "id": "small", "upstream_id": "vendor/small", "protocol": "openai_chat", "reasoning_levels": [null, "high"] }
    ]
  }]
}
```

The selector is `provider/model`, for example `gateway/big`. A local server, such as Ollama, has no `auth` and no `key_header`.

- The mode must be `0600`, and the file must not be a symlink. Otherwise yuke does not start.
- The schema is strict. An unknown field or a bad value stops startup, and the error names it, for example `UnknownField`. A failed `/reload-providers` keeps the current providers.
- `yuke login` and `yuke logout` write the whole file again.

| Provider field | Meaning |
|---|---|
| `id` | Required. No `/` and no whitespace. |
| `base_url` | `http` or `https`, with a host. No user, query, or fragment. |
| `endpoints` | The paths the host serves. |
| `auth` | The credential. |
| `api_key` | A literal key: the short form of `auth`. Do not use it with `auth`. |
| `headers` | `[{ "name", "value" }]`. It must not set the key header or the session header. |
| `session_header` | `none`, `session_id`, or `x_opencode_session`. |
| `models` | The models. |

| `auth` | Meaning |
|---|---|
| absent | A built-in provider reads its variable. Another provider sends no credential. |
| `{ "api_key": { "source": { "env": "NAME" } } }` | The key comes from `NAME`. |
| `{ "api_key": { "source": { "literal": "..." } } }` | The key is in the file. |
| `{ "api_key": {} }` | The provider needs a key and has none: `needs key`. |
| `{ "oauth": ... }` | An account login. Only `yuke login` writes it. |

| Endpoint field | Meaning |
|---|---|
| `protocol` | Required, once per list: `anthropic_messages` (`/messages`), `openai_chat` (`/chat/completions`), or `openai_responses` (`/responses`). |
| `key_header` | `x_api_key` or `authorization_bearer`. Required with an API key. Omit it with an account login. |
| `cache` | `unsupported`, `automatic`, `anthropic_breakpoint`, or `openai_breakpoint`. |
| `responses_dialect` | `standard` (default) or `codex`. Only on `openai_responses`. |

| Model field | Meaning |
|---|---|
| `id`, `upstream_id` | Required. The selector name, and the name the host receives. |
| `protocol` | The endpoint. Required when the provider has more than one endpoint. |
| `limits` | `context_window`, `max_output_tokens`. Omitted means unknown. |
| `cost` | `input`, `output`, `cache_read`, `cache_write`, in USD per million tokens. Omitted means unknown, not zero. |
| `reasoning_levels` | Some of `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. `null` turns reasoning off. |
| `flags` | See below. |

| Flag | Default | Values |
|---|---|---|
| `supports_tools` | `true` | |
| `supports_vision` | `false` | |
| `supports_tool_search` | unknown | Needs `supports_tools`. Not on `openai_chat`. |
| `thinking_format` | `none` | `openai`, `openrouter`, `deepseek`, `zai`, `qwen`, `together`, `string_thinking`, `ant_ling` |
| `reasoning_replay` | `none` | `reasoning`, `reasoning_content`, `reasoning_details` |
| `anthropic_adaptive` | `false` | Adaptive thinking in place of a token budget. |
| `reasoning_budget_min`, `reasoning_budget_max` | none | The thinking-token budget. |
| `max_tokens_field` | `max_tokens` | `max_completion_tokens` |

## Change a built-in provider

An entry with a built-in `id` changes that provider. A field you write replaces the built-in value, and a field you omit keeps it. `endpoints` replaces the whole list. A model with a built-in `id` replaces that model, and a new `id` adds a model. For example, `{ "id": "openai", "base_url": "http://127.0.0.1:8080/v1" }` sends the requests of every `openai` model through a proxy.
