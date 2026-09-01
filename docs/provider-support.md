# Provider support — protocols, endpoint resolution, and error classification

Status: notes + remaining fixes (2026-08-27). Written after an end-to-end test session against
the live daemon using the `yuke-ts-sdk` client and two free providers (`opencode`, `minimax`).
Source of truth: `src/provider/` and the cited provider documentation.
Last verified: 2026-08-31.
Scope: how the daemon talks to upstream providers, and where its error classification is
misleading. Code references are `src/provider/...`.

## Supported protocols

The daemon speaks three upstream protocols, selected per provider by the `protocol` field in
`providers.json`. Each maps to a fixed endpoint suffix (`src/provider/instance/resolve.zig`):

| `protocol`            | endpoint suffix      | SSE reducer                          |
| --------------------- | -------------------- | ------------------------------------ |
| `anthropic-messages`  | `/messages`          | `src/provider/stream/anthropic.zig`  |
| `openai-completions`  | `/chat/completions`  | `src/provider/stream/openai_chat.zig`|
| `openai-responses`    | `/responses`         | `src/provider/stream/openai_responses.zig` |

### Endpoint resolution — `base_url` must already include the version segment

The request URL is `base_url ++ suffix` — the daemon appends only the suffix above, never a version
segment. So `base_url` must carry the provider's own version prefix.

- Correct: `base_url = "https://api.anthropic.com/v1"` → `…/v1/messages`.
- Pitfall found in this session: `minimax` was configured `https://api.minimax.io/anthropic`
  (no `/v1`), so the daemon called `…/anthropic/messages` → **HTTP 404** → surfaced as
  `provider` / "the provider returned an unexpected status". Fixing `base_url` to
  `https://api.minimax.io/anthropic/v1` resolved it (`…/anthropic/v1/messages` → 200).

A 404 from a provider almost always means a `base_url` that is missing (or doubling) a path
segment. There is no per-provider path override today; the suffix table is the whole contract.

## Transport-level errors (protocol-agnostic)

HTTP status is classified once, before any reducer runs, in
`src/provider/transport/http.zig` (`mapStatus`) → `src/provider/failure.zig` (`classify`). This is
shared by all three protocols and is accurate:

| upstream status | mapped error         | outcome `code`     | class             |
| --------------- | -------------------- | ------------------ | ----------------- |
| 401             | `AuthFailed`         | `auth`             | permanent         |
| 402             | `QuotaExhausted`     | `quota_exhausted`  | permanent         |
| 403             | `PermissionDenied`   | `auth`             | permanent         |
| 408, 504        | `Timeout`            | `timeout`          | transient         |
| 429             | (body-classified)    | `rate_limited`     | transient/permanent |
| 500–503, 505–599| `ServerError`        | `provider`         | transient (retried) |
| other non-200   | `BadStatus`          | `provider`         | permanent         |

Observed this session (both verified end-to-end through the SDK):

- **opencode, openai-completions, valid key** — `/chat/completions` accepted the key (401 → 200
  after the key was refreshed). The free tier then rate-limited (see below).
- **opencode, anthropic-messages** (`/zen/v1/messages`) — returns a **sticky HTTP 500**
  (`{"type":"error",{"message":"Internal server error"}}`) for the free models. The daemon
  classified this correctly: `outcome: failed / provider` "the provider returned a server error",
  retried a few times (~9s) then failed. So opencode's Anthropic endpoint exists but is
  server-broken for the free models; its OpenAI-completions endpoint is the working one.
- **minimax, anthropic-messages** — works cleanly for plain prompts and tool use once `base_url`
  carries `/v1`.

## In-stream error frames — the real gap

Some providers return HTTP 200 and then emit an **error object inside the SSE stream** instead of
(or after) content. The two reducers handle this inconsistently, and neither extracts the error
subtype — so a rate-limit or quota signal is lost or mislabeled.

### openai-completions — mislabeled as "malformed"

opencode's free tier, once its usage cap is hit, sends this mid-stream on a 200 response:

```
data: {"type":"error","error":{"type":"FreeUsageLimitError","message":"Rate limit exceeded. Please try again later."}}
```

`openai_chat.zig::decode` (around L59–L66) checks for `[DONE]`, then requires a `choices` array and
returns `error.Protocol` when it is absent. The error frame has no `choices`, so it becomes
`error.Protocol` → `outcome: failed / protocol` **"the provider stream was malformed"**. That
reads like a yuke bug; the truth is the provider rate-limited us.

There are actually **two** in-stream error shapes in the OpenAI-compatible world, and the daemon
mishandles both (verified against the OpenRouter spec, whose SSE dialect opencode/zen follows —
same `reasoning_details`, `cost`, and error framing):

- **Bare shape** (what opencode actually sent): `{"type":"error","error":{"type":"FreeUsageLimitError",…}}`
  — no `choices` → `error.Protocol` → "malformed" (as above).
- **Unified shape** (the OpenRouter-documented one): the chunk carries **both** a top-level `error`
  *and* a `choices` array with an empty delta and `finish_reason:"error"`:
  ```json
  {"object":"chat.completion.chunk","error":{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}
  ```
  Here `decode` finds `choices`, processes the empty delta, maps `finish_reason:"error"`, and
  **never looks at the top-level `error`** — so a rate limit can end the turn *silently* as a
  near-normal stop, which is worse than the malformed case. `error.metadata.error_type` is the
  canonical, cross-format classifier (`rate_limit_exceeded` = 429, `token_limit_exceeded` = 400
  quota).

Its SSE also carries `: keep-alive` comment lines and `reasoning` / `reasoning_details` deltas with
empty `content` — those are tolerated today (comment lines never reach `decode`; unknown delta
fields are ignored), so they are not the problem. The error frame is.

### openai-completions — trailing frame after `[DONE]` (fixed)

Some OpenAI-compatible providers append a bookkeeping frame after `[DONE]`. The reducer now
ignores frames after the terminal event, so a valid completion does not become a malformed-stream
failure. Keep a regression test for this provider behavior.

### anthropic-messages — honest but still generic

`anthropic.zig::decode` (L79–L90) recognizes `type: "error"` as a first-class event and returns
`error.Provider` → `outcome: failed / provider` "the provider request failed". Better than the
OpenAI path (not mislabeled "malformed"), and unknown event types are graceful no-ops (L79). But it
returns a blanket `error.Provider`; it never reads the nested `error.type`, so it also cannot produce
a `rate_limited` / `quota_exhausted` / `auth` outcome for an in-stream error.

Anthropic's spec is explicit that these arrive *after* a 200, as an `event: error` with a typed
body — so branching on `error.type` is the intended handling. The types worth mapping
(status shown for reference; the streaming ones ride a 200): `rate_limit_error` (429) →
`rate_limited`; `overloaded_error` (529) → transient/retryable (mirror the 529→`ServerError`
handling `mapStatus` already has); `authentication_error` (401) / `permission_error` (403) →
`auth`; `billing_error` (402) → `quota_exhausted`; `invalid_request_error` (400) →
`invalid_request`; `api_error` (500) → `provider`.

## Recommended fixes

The remaining fixes below address in-stream error frames (rate limit and quota).

Both reducers expose `pub const Error = error{ Protocol, Provider, OutOfMemory }`. The shared
classifier in `failure.zig` already maps `RateLimited` → `rate_limited`, `QuotaExhausted` →
`quota_exhausted`, and `AuthFailed` → `auth`. So the error-frame fix is: (1) detect the in-stream
error object, (2) read its subtype, (3) return a specific error the classifier already understands.

1. **Widen the reducer error sets** to include the codes the classifier maps, e.g.
   `error{ Protocol, Provider, RateLimited, QuotaExhausted, AuthFailed, OutOfMemory }`, and confirm
   `failure.zig::classify` covers each (it already lists the `http.Error` variants of these).

2. **openai_chat.zig::decode** — check for a top-level `error` object **before** the `choices`
   handling (this is load-bearing: the unified shape carries `error` *and* `choices`, so a check
   that runs only when `choices` is absent would miss it and end the turn silently):
   ```zig
   if (json.fieldGet(root, "error")) |e| return mapOpenAiError(e);
   // …existing choices handling…
   ```
   `mapOpenAiError` reads, in order, `error.metadata.error_type` (canonical), then `error.type`,
   then the numeric `error.code`: `rate_limit_exceeded` / `429` → `error.RateLimited`;
   `token_limit_exceeded` / `insufficient_quota` / `402` → `error.QuotaExhausted`; an auth shape /
   `401` / `403` → `error.AuthFailed`; anything else → `error.Provider` (still not "malformed").
   opencode's bare `{"type":"error","error":{"type":"FreeUsageLimitError",…}}` lacks `metadata`, so
   also treat a `*UsageLimit*` / `*RateLimit*` `error.type` as rate-limited.

3. **anthropic.zig** — in the `.@"error"` arm (L83), read the nested `error.type` and route through
   the same `mapProviderError` rather than returning a blanket `error.Provider`. Anthropic's
   `overloaded_error` should map to a transient/retryable class (mirrors the 529 handling that
   `mapStatus` already treats as `ServerError`).

4. **Optional — a neutral terminal error event.** If callers should see a partial transcript before
   the failure (the OpenAI case delivered `"pong"` before the error frame), add an error variant to
   `StreamEvent` (`event.zig`) so the reducer can flush pending blocks and then emit a typed
   terminal error, instead of unwinding via a Zig error and discarding in-flight output. Larger
   change; only worth it if partial-before-error UX matters.

Net effect: an exhausted free tier reports `rate_limited` (retryable/needs-wait) or
`quota_exhausted` instead of the misleading `protocol` "malformed stream", and the two protocols
classify in-stream errors the same way.

## Testing notes

- Free providers used: `minimax` (anthropic-messages, working) and `opencode`
  (openai-completions). opencode Zen is **OpenAI-compatible only** — free models are served on
  `/chat/completions`; it has no working Anthropic endpoint for them (`/messages` returns a sticky
  HTTP 500), so `opencode` must stay `openai-completions`.
- **opencode model IDs drift** — the live `/v1/models` catalog is the source of truth. During this
  session `big-pickle` ("Model is disabled") and `x-preview-f-free` ("not supported") had been
  retired and returned 401; `providers.json` was updated to the current free set
  (`deepseek-v4-flash-free`, `hy3-free`, `laguna-s-2.1-free`, `mimo-v2.5-free`,
  `nemotron-3-ultra-free`, `nemotron-3.5-lightning-free`; `muse-spark-1.2-contributor-free` on the
  `openai-responses` provider). A retired id reads as `auth`, not `unknown_model`, because the
  gateway answers 401 — so re-check the live catalog before assuming a key problem.
- The key lives in `OPENCODE_API_KEY` (per `providers.json` `source.env`). The daemon reads it from
  its own process environment at request time.
- To reproduce the in-stream OpenAI error: exhaust the opencode free quota (a handful of calls),
  then send another prompt — the daemon reports `protocol` "malformed stream" (pre-fix) for what is
  really a rate limit.

## Sources

The in-stream error formats above were verified against provider documentation, not just the one
opencode sample observed in testing:

- Anthropic — errors, HTTP status/type table, and mid-stream `event: error` (overloaded_error 529,
  rate_limit_error 429): <https://platform.claude.com/docs/en/api/errors>
- Anthropic SDK — confirmation that mid-stream SSE errors ride a 200 (status_code stays 200):
  <https://github.com/anthropics/anthropic-sdk-python/issues/1258>
- OpenRouter — mid-stream error SSE structure (`error` + `choices[finish_reason:"error"]`) and the
  canonical `error.metadata.error_type` (`rate_limit_exceeded` 429, `token_limit_exceeded` 400):
  <https://openrouter.ai/docs/api_reference/errors-and-debugging>
