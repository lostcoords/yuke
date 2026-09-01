# The provider model

Status: current design and plan. Stages 0 to 9 are implemented. Stage 10 is not.
Sections 1 to 5 describe the target model and keep the names the migration used; the code is the
authority for what exists.
Source of truth: `src/daemon/registry.zig`, `src/catalog/`, `src/cloud/`, and `src/provider/model.zig`
for what is built. This document owns the target and the sequence for what is not.
Last verified: 2026-08-31.

This document defines how a provider reaches the daemon. It replaces the layer model in
[`providers-plan.md`](providers-plan.md) section 1. The cloud, relay, and enrollment decisions in
that document stay current.

## 0. Locked decisions

1. `providers.json` is the single local credential store. The daemon reads it and writes it. A key
   stays in plain text, because most harnesses work that way.
   The daemon does not wipe a secret from memory. A reader of daemon memory already reads the file,
   so the wipe bought nothing and forced a whole-document check that was itself wrong.
2. The account bundle is independent. It never merges with `providers.json`.
3. The open catalog never carries a credential. It completes a local provider that names an id and
   a key.
4. The open catalog is not a cloud feature, so it lives outside `src/cloud/`.
5. The two origins are separate namespaces. Neither hides the other.
6. The model selector carries its origin and stays opaque to a client.
7. Every wire change lands in one batch, at Stage 6.

## 1. Why the current model needs a change

A provider has three independent kinds of data. Every current type mixes all three:

- `cloud.catalog.Provider` holds knowledge **and** a route.
- `cloud.bundle.Provider` holds knowledge, a route, **and** a credential.
- `provider.config.LocalProvider` holds knowledge, a route, **and** a credential.

Each of the three uses a different nullability for the same concept. The merge then joins them with
a chain of `orelse`, so an unknown value, an absent value, and a default value become one value.
`no_cost` shows the result: a catalog model with no price gets four nulls, and a local model with no
price gets four zeros. "Unknown price" and "free" then depend on the source.

Every other symptom follows from this: the triple `orelse` in `localRoute`, the three duplicate
model converters, `ProviderSource` that nothing reads, and `needs_login` that means four things.

## 2. The three axes

| Axis | Content | Holds a secret | Cacheable |
|---|---|---|---|
| Knowledge | which providers and models exist, their limits, capabilities, and request dialect | never | yes |
| Route | how to call: base URL, protocol, pinned headers, cache policy, auth mechanism | never | yes |
| Credential | the secret, and the owner of its lifecycle | always | no |

Each source contributes to some axes and not to others. That is the whole model.

## 3. The two compositions

There are two independent compositions. They never share a merge path.

```
open catalog + providers.json  ->  resolveLocal()    // field by field, the catalog completes
account bundle                 ->  resolveAccount()  // pass-through, never composed
```

**The account bundle is independent.** It carries knowledge, a route, and a credential together.
Nothing completes it, and it never merges with `providers.json`.

**The open catalog carries no credential.** It never produces a provider on its own. It completes a
local provider that names an id and a key.

**`providers.json` identifies the local provider and may supply a credential.** An entry that names
only an id and a key needs the catalog. An entry that names a route and models needs nothing. A
keyless entry supplies no credential, and the catalog then decides whether the route needs one.

The two origins are separate namespaces. A local `anthropic` and an account `anthropic` are
different providers, and both appear. Section 7 covers the identity that follows.

## 4. What each source contributes

| Source | Knowledge | Route | Credential | Lives |
|---|---|---|---|---|
| Open catalog (`GET /api/v1/catalog?executable=true`) | yes | a template | never | SQLite |
| `providers.json` | optional | optional overrides | usually | a local file the daemon reads and writes |
| Account bundle (`GET /api/v1/providers`) | yes | yes | yes | memory only |

The open catalog is not a cloud feature. The daemon fetches it from the control plane today, but it
is anonymous, it holds no secret, and it works the same from SQLite or from a file. It therefore
lives in `src/catalog/`, and `src/cloud/` keeps only account-scoped code.

The module graph must stay acyclic:

```
net         (std only)
database    (leaf)
provider    (internal only)
catalog  ->  database, net, provider
cloud    ->  net, paths, provider
daemon   ->  catalog, cloud, database, net, provider
```

`src/net/http.zig` holds the shared control-plane HTTP client. It served the catalog fetch, the
bundle fetch, and `yuke login` while it lived in `src/cloud/`, so it pointed `catalog` at `cloud`.
The shared model vocabulary lives in `src/provider/model.zig`, which both sources already import.
Those two moves keep `cloud` and `catalog` independent in both directions.

## 5. The types

These names describe the target model. The code is the authority for what exists.

```zig
/// An unknown value is a value. Never use zero, false, or an empty string as an unknown.
pub fn Known(comptime T: type) type {
    return union(enum) { unknown, value: T };
}

/// One model, as knowledge. It holds no route and no secret.
pub const ModelSpec = struct {
    id: []const u8,
    upstream_id: []const u8,
    name: []const u8,
    limits: Limits,
    caps: Caps,
    cost: Cost,
    reasoning_levels: []const ReasoningLevel,
    dialect: Dialect,
};

/// The open catalog publishes a complete route. It never publishes a credential.
pub const RouteTemplate = struct {
    base_url: []const u8,
    protocol: Protocol,
    auth: AuthMechanism,
    headers: []const Header = &.{},
    cache: CachePolicy = .unsupported,
};

/// `providers.json` overrides the template. Null means "use the catalog value".
pub const RoutePatch = struct {
    base_url: ?[]const u8 = null,
    protocol: ?Protocol = null,
    auth: ?AuthMechanism = null,
    headers: ?[]const Header = null,
    cache: ?CachePolicy = null,
};

/// This mechanism builds the credential header. It names no vendor.
pub const AuthMechanism = union(enum) { none, api_key: ApiKeyHeader };

/// The credential carries the secret. An OAuth grant carries its own identity headers.
pub const Credential = union(enum) {
    api_key: []const u8,
    oauth: OAuth,
};

/// A ready provider carries its route, so a state and a route cannot disagree.
pub const Availability = union(enum) {
    ready: Route,
    unavailable: Reason,
};

pub const Reason = enum { needs_credential, needs_route, expired, revoked };

/// One provider the daemon offers.
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    origin: Origin,
    models: []const ModelSpec,
    availability: Availability,
};

/// Stage 6 replaced this proposal with an opaque `origin:provider/model` string. See section 8.
```

The merge became `localAvailability` in `src/daemon/registry.zig`. The sketch below shows the intent:

```zig
/// Complete a local route from the catalog template. The file wins field by field.
fn composeRoute(patch: RoutePatch, template: ?RouteTemplate) ?Route {
    const t = template orelse return standalone(patch);
    return .{
        .base_url = patch.base_url orelse t.base_url,
        .protocol = patch.protocol orelse t.protocol,
        .auth = patch.auth orelse t.auth,
        .headers = patch.headers orelse t.headers,
        .cache = patch.cache orelse t.cache,
    };
}

/// No catalog row exists, so the file must carry the whole route.
fn standalone(p: RoutePatch) ?Route {
    return .{
        .base_url = p.base_url orelse return null,
        .protocol = p.protocol orelse return null,
        .auth = p.auth orelse return null,
        .headers = p.headers orelse &.{},
        .cache = p.cache orelse .unsupported,
    };
}
```

### The patch and effective rule

A source patch uses `?T`, and null means "the source does not specify this".
An effective type uses no optional. It states an unknown value with `Known(T)`.

`Capability` and `Price` are `Known(bool)` and `Known(f64)`. Do not add a separate type for each.

### What the collapse removes

`ModelView` and its three converters become one `ModelSpec`. The registry projects each source's
flags into one `Caps` and one `Dialect`, and `instance.ModelFlags` stays as the local file shape.
`ProviderState` plus an optional route become `Availability`. Two arms of `instance.Auth` go: an
`xai_oauth` route emits the same bytes as `api_key` with `authorization_bearer`, and a `codex_oauth`
route is a bearer whose credential adds one header. A new OAuth provider then needs no enum arm and
no branch in `authHeaders`.

## 6. Credentials

`providers.json` is the single local credential store. The daemon reads it and writes it. A key
stays in plain text, because most harnesses work that way and the file is mode 0600.

The account bundle stays in memory. It carries live keys and access tokens, and `yuked.db` is mode
0644.

A public provider row carries no secret. A run resolves the credential when it starts, so an
environment credential is read per run. A provider with a missing environment value reports
`needs_credential`, and it does not disappear from the list.

## 7. Identity

An account provider uses the account slug as its id. The daemon removed `public_id`, which was the
only stable identity the bundle offered and which nothing read.

A user can rename an account slug, and a stored `session_configs.model` then names an id that no
longer exists. Section 11 records the proposed answer, and Stage 6 settles it.

## 8. Staged work

This table is the sequence. Each stage keeps `zig build test` and `zig build test-js` green, and no
stage leaves a half-migration.

| Stage | Work | State |
|---|---|---|
| 0 | Three cloud bugs: a request timeout, a false 503 success, a stranded catalog | done |
| 1 | Delete dead code: the catalog `rev`, `small_model`, `public_id` | done |
| 2 | This document | done |
| 3 | Move the open catalog out of `src/cloud/`, and break the module cycle | done |
| 4 | The patch and effective split: `Known(T)`, `ModelSpec`, one `Dialect` | done, with Stage 5 |
| 5 | The registry rewrite: two resolvers, `Availability`, no `claimed()` | done |
| 6 | Wire v2: an opaque `selector` and the `Availability` states | done |
| 7 | The credential layer and the `providers.json` writer | done |
| 8 | The `auth.*` endpoints | done |
| 9 | The scheduler | done |
| 10 | Local OAuth | next |

### Stage 6 — wire v2

Every client-visible change lands together, so `schema/wire.json`, the TS SDK, and the TUI move once.

- **`ModelInfo` gains `selector`, an opaque token.** The daemon owns the format, which is
  `origin:provider/model`. A client echoes the value back and never parses or builds one. This
  replaces the earlier `ModelRef` proposal: a struct still makes a client assemble three fields,
  while an opaque token makes the format a daemon detail that can change with no client change.
- `ProviderState` becomes the projection of `Availability`, so `needs_credential`, `needs_route`,
  `expired`, and `revoked` reach the client instead of one `needs_login`.
- `ProviderInfo.source` already carried the origin, so a client can show `anthropic (local)` and
  `anthropic (cloud)` with no new field.

The selector stays a string in every durable place. `message.TurnProvenance.model` records it on
every assistant message, so a struct would have migrated stored transcript data to remove one
string split. That cost does not buy anything the opaque token does not already give.

A stored selector from before this stage names no origin, so it resolves to nothing and the session
reports its model as unavailable. That matches the rename rule in section 11, and the project is
pre-release, so no migration rewrites those rows.

Verify: `zig build gen-schema` is clean, and a client selects a model on both origins.

### Stage 7 — the credential layer

Done. The stage matched the plan, with two changes that the plan did not anticipate.

- `AuthMechanism { none, api_key }` replaces `instance.Auth`. An OAuth grant is now a bearer whose
  `Credential` carries its own identity headers, so `codex_oauth` and `xai_oauth` are gone and
  `authHeaders` has no per-vendor branch. A new OAuth provider needs no enum arm.
- `Route` holds a `CredentialSource`, not a secret. A run resolves it at the start, so a rotated
  environment key needs no rebuild.
- `providers.json` has an atomic writer with mode 0600, and the loader accepts an entry with a route
  and no credential, so Ollama and llama.cpp work.

**`ResponsesDialect` moved to the route.** `run_task.zig` read it from `auth == .codex_oauth`, which
tied a request dialect to a credential enum. Whether a host speaks the Codex flavor of the Responses
API follows the base URL, so `ProviderInstance` owns it. One `flow == "codex"` branch stays at the
bundle decode boundary, which is where an external string becomes a closed enum.

**A selector is now bounded.** `isSelectorPart` had no length limit, and `providers.json` bounded no
id, so a local entry could mint a selector far past the `CHECK (length(model) <= 128)` on three
durable columns. `wire.ids` now owns `max_selector_part_bytes` and `max_selector_bytes`, the columns
hold 288 bytes, and `isSelectorTail` accepts the slash that a model id may carry while still
rejecting whitespace and control bytes, which the catalog and the bundle previously allowed.

### Stage 8 — the `auth.*` endpoints

Done. `auth.list`, `auth.set_api_key`, and `auth.remove` work against `providers.json` through the
Stage 7 writer. A write goes to the file, reloads it, and installs the layer with
`State.installProviders`, so the reload proves the file parses before the snapshot changes. The
write then sends `auth.changed`, and `catalog.changed` follows only when the public projection moves.

- **`auth.set_api_key` writes a literal key.** An environment reference stays something the user
  hand-writes, because a key field in a client collects a key, not a variable name.
- **A new provider needs only an id and a key.** That is the case section 3 describes, and the
  catalog completes the route.
- **`auth.remove` replaces `auth.logout`.** `logout` read as the inverse of `login`, but it undoes
  `set_api_key`; `login` is OAuth only, and both its flows are OAuth. Removal is the one operation
  that suits every credential kind, so one method covers OAuth at Stage 10 with no second name.
- **`auth.remove` never destroys configuration.** It clears the credential and drops the entry only
  when nothing else remains, so a hand-written route, headers, and models survive.
- **The `auth.login` family stays on the wire**, and every unimplemented method now answers
  `not_implemented` (-31022) instead of `unknown_method`. The daemon knows the method and has not
  built it; those are different facts. `unknown_provider` (-31023) is new for `auth.remove`.

**The file gained a third credential state, and lost a type.** `providers.json` could say "no
credential at all" and "here is a key", but not "this route wants a key and I hold none". That state
was reachable only as a side effect, through an environment variable that happened to be unset. Now
an `api_key` block with no `source` states it directly, and `LocalProvider.auth` is optional:

| JSON | State |
|---|---|
| no `auth` block | the route presents no credential, so a local server works |
| `"auth":{"api_key":{"header":"x_api_key"}}` | the route wants a key and holds none, so it reports `needs_credential` |
| `"auth":{"api_key":{"source":{"env":"K"}}}` | resolve the key from the environment |

`FileSource` is gone, and `FileApiKey` is now an alias of `LocalAuth`, so the file and the local
layer share one shape. The registry keeps its own `CredentialSource`, which adds a `none` arm for a
keyless route and an `oauth` arm for the account bundle, and converts the two file arms explicitly.

No new authorization gate. Section 11 records why: the daemon authenticates nobody and already
offers `exec`, so a gate here would guard the weaker of two doors. `../bugs.md` tracks the real one.

### Stage 9 — the scheduler

Done. One task in the maintenance group owns two jobs and runs them in order, so two fetches never
overlap. `refreshCloudLocked` split into `refreshCatalogOnce` and `refreshBundleOnce`, and
`cloud_refresh_mutex` is gone; an assertion now states that only one caller may fetch at a time.

- The catalog revalidates each hour, and the bundle every 15 minutes.
- A live token pulls the bundle deadline earlier, with a five-minute margin. The margin never makes
  the job due at once, because a fetch that just ran cannot do better. A dead grant keeps the expiry
  of the token it lost, so only an active grant sets a deadline.
- A failure backs off from 30 seconds to 30 minutes and resets on success. The job never stops,
  because a control-plane outage always ends. This is why the scheduler does not call
  `retry.decide`: the per-run budget there would end a periodic job after five failures.
- `catalog.refresh` wakes the job and returns the current revision. It measured 1 ms against 1483 ms
  before, and `catalog.changed` reports the result.

The clock is `.boot`, which counts suspended time, because the control plane times its documents by
its own clock. Every cancel must leave the loop: Zig reports a cancel at the NEXT cancellation point
only, so a swallowed one leaves the following wait parked for its full interval.

### Stage 10 — local OAuth

Less wiring than this plan first assumed. `AuthMechanism` needs no new arm and the scheduler from
Stage 9 owns the refresh, but `Credential.oauth` holds only an access token and its identity
headers, and the file's `CredentialSource` has `env` and `literal` only. Stage 10 must add a refresh
token, an expiry, and a file arm that stores them.

## 9. Deferred on purpose

- **A catalog bundled into the binary.** It helps only a first run with no network and no
  `providers.json`. The model makes it one more knowledge source, so it is not debt.
- **`supports_tools`, `cache`, and `context_window` control nothing today.** Tools always reach the
  request, `provider.requestBody` always passes empty options, and `turn_context` uses a fixed
  budget. These belong to the knowledge layer and should act. That change alters request
  construction, so it needs its own decision.
- **Discovery.** `catalog.list` shows configured providers only. Showing an unconfigured catalog
  provider needs a bulk read, which no query provides, and it needs `needs_credential` first.

## 10. Superseded claims

`providers-plan.md` states these, and they are wrong:

- "Precedence is field by field: `providers.json`, then the bundle, then the catalog." The bundle
  never composes with anything.
- "Key internal maps on the bundle's `public_id`." Stage 1 deleted `public_id`.
- "`catalog_meta` holds `rev` and `etag`." Stage 1 deleted `rev`.

## 11. Open questions

### Decided

- **The account slug is the provider identity.** A user can rename it. A rename then makes a stored
  `session_configs.model` selector unresolvable, and the session reports the model as unavailable.
  The daemon tracks no rename, because the bundle publishes no stable id.
- **`catalog_rev` means that the client-visible catalog changed.** A route or credential change
  fires `auth.changed` instead, once Stage 8 exists. A route change therefore sends no
  `catalog.changed`, and that is deliberate.
- **`providers.json` keeps version 1.** A keyless entry only widens what the schema accepts, and the
  project is unreleased, so a version bump would buy no reader anything.

### Decided at Stage 8

**Nothing authorizes `auth.set_api_key`, and nothing needs to yet.** The question assumed a remote
client and a privilege boundary. Neither exists in this tree:

- The front door binds `127.0.0.1` only, and no relay client is ported, so there is no remote path.
  The TLS proxy is hypothetical.
- The middleware chain is `mark-private -> admit -> auth`, and only `admit` exists. It checks the
  `Origin` and the `Host` against DNS rebinding, which guards a browser and nothing else.
- Every connected client can already run `/bin/sh` through the `exec` tool. The session `permission`
  value is stored and never read, so it gates nothing.

A caller that could abuse `auth.set_api_key` can already read `providers.json` with `exec`. The
endpoint adds no privilege, so Stage 8 needs no new gate. The real defect is that the daemon
authenticates nobody while it offers arbitrary code execution. That belongs to the front door and
the relay port, not to the provider model, and `../bugs.md` tracks it.
