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

An account login uses a device code: open the page that yuke shows, enter the code, and confirm. You can also run `yuke login openai-codex` or `yuke login xai-grok` from the shell. See [Command line](cli.md).

Run `/logout` or `yuke logout <provider>` to remove a stored login or API key. A variable stays: to stop using it, unset it.

## Add a provider

This example adds a gateway:

```json
{
  "providers": [{
    "id": "gateway",
    "baseUrl": "https://gateway.example/v1",
    "apiKeyEnv": "GATEWAY_API_KEY",
    "endpoints": [{
      "protocol": "openai_chat",
      "credentialHeader": "authorization_bearer"
    }],
    "models": [{ "id": "big", "upstreamId": "vendor/big" }]
  }]
}
```

yuke reads the key from `GATEWAY_API_KEY` or from `/login`.

Use `/reload` to reload the profile after an edit. The reload fails while a turn runs. A failed reload keeps the previous providers and plugins.

To use a model of this provider, pass `--model gateway/big` to `yuke -p`, or choose it with `/model`.

### Local server

If the server needs no credential, omit `apiKeyEnv` and `credentialHeader`:

```json
{
  "providers": [{
    "id": "local",
    "baseUrl": "http://127.0.0.1:8080/v1",
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
  "providers": [{ "id": "openai", "baseUrl": "http://127.0.0.1:8080/v1" }]
}
```

## Fields

The file accepts JSON with `//` and `/* */` comments. Unknown fields and bad routes stop startup. A `null` value is an error: omit a field to keep its built-in value.

yuke applies the entries in file order. A provider ID that an earlier entry has changes the result of that entry, and a model ID that an earlier model of the provider has replaces that model. In both cases the last value wins.

### Provider fields

| Field | Meaning |
|---|---|
| `id` | Required. It is not empty and has no `/`. |
| `name` | Display name. Defaults to the ID. |
| `baseUrl` | A URL that starts with `http://` or `https://`. yuke checks only this scheme. Required for a new provider. |
| `apiKeyEnv` | The environment variable for an API key. It is not empty and has no `=`. Omit it for a provider that needs no credential. On `openai-codex` and `xai-grok`, it is an error: these providers use an account login. |
| `endpoints` | Protocol endpoints. Required for a new provider. Each protocol appears at most once. |
| `headers` | Extra headers as `[{ "name": "x-team", "value": "core" }]`. A header must not replace a header that yuke writes. |
| `sessionHeader` | `none` (default), `session_id`, or `x_opencode_session`. |
| `models` | Model entries. Required for a new provider. |

### Endpoint fields

| Field | Meaning |
|---|---|
| `protocol` | Required: `anthropic_messages` (`/messages`), `openai_chat` (`/chat/completions`), or `openai_responses` (`/responses`). yuke appends the protocol path to the base URL. |
| `credentialHeader` | `x_api_key`, `authorization_bearer`, or `api_key`. Required when the provider sends a credential. |
| `cacheBreakpoint` | Boolean, default `false`. Marks an explicit prompt-cache breakpoint. `openai_chat` does not support `true`. |
| `responsesDialect` | `standard` (default) or `codex`. Only on `openai_responses`. |
| `chatDialect` | `standard` (default) or `mistral`. Only on `openai_chat`. |

### Model fields

| Field | Meaning |
|---|---|
| `id` | Required and not empty. The model part of the selector. |
| `upstreamId` | The model name that the host receives. Defaults to `id`. |
| `name` | Display name. Defaults to `id`. |
| `protocol` | Required when the provider has more than one endpoint. |
| `limits` | `contextWindow` and `maxOutputTokens`. Omitted values are unknown. |
| `cost` | Price bands in USD per million tokens. See [Cost](#cost). |
| `reasoningLevels` | The efforts that the model takes, from `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. A `null` item means no effort. An empty list, the default, accepts any effort. See below. |
| `flags` | Capability facts. Omitted facts are unknown. See below. |

A list that is not empty limits the efforts: yuke rejects an effort that the list does not name. A `null` item adds no choice to `/model`. An empty list lets `--reasoning` take any effort, but `/model` then offers only `default` and `off`.

`/model` offers `default`, each effort of `reasoningLevels`, and `off` when the model can turn reasoning off.

### Model flags

| Flag | Meaning |
|---|---|
| `supportsToolSearch` | Whether the model supports deferred tool search. |
| `canDisableReasoning` | `false` rejects an explicit off choice. |
| `supportsCacheBreakpoint` | Whether the model accepts an explicit cache marker. |
| `thinkingFormat` | Chat Completions only: `none` (default), `openai`, `openrouter`, `deepseek`, `zai`, or `qwen`. |
| `reasoningReplay` | Chat Completions only: `none` (default), `reasoning_content`, or `reasoning_details`. |
| `maxTokensField` | Chat Completions only: `max_tokens` (default) or `max_completion_tokens`. |
| `anthropicThinking` | Messages only: `toggle`, `adaptive`, or `budget`. |
| `reasoningBudgetMin`, `reasoningBudgetMax` | Bounds for `anthropicThinking: "budget"`. |

### Cost

`cost` is a list of price bands. The first band starts at `0`, so it can omit `minPromptTokens`. Each later band sets a higher `minPromptTokens`. A price is not negative. The last band that the prompt size reaches prices the whole request. Prices are `input`, `output`, `reasoning`, `cacheRead`, and `cacheWrite`. A missing price is unknown, not zero. For example:

```json
"cost": [
  { "input": 4, "output": 20, "cacheRead": 0.4 },
  { "minPromptTokens": 272001, "input": 8, "output": 30, "cacheRead": 0.8 }
]
```

## Network

yuke checks the certificate of an `https` host against root certificates:

- On macOS, yuke reads the roots from the file in `SSL_CERT_FILE`. Without this variable, it reads `/etc/ssl/cert.pem`.
- On Linux, `SSL_CERT_FILE` or `SSL_CERT_DIR` names the exact roots. Without them, yuke reads the system bundle file. It reads the certificate folders of the system only when no bundle file exists. A root that only a folder holds needs `SSL_CERT_DIR`.

This applies to model requests, logins, and the `fetch` of plugins. Set one of these variables when a private gateway or a network that inspects TLS signs with its own root.

yuke does not read `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, or `NO_PROXY`. To send the requests of a provider through a proxy or a gateway, set its `baseUrl`. The `git` program that installs plugins uses its own proxy settings.
