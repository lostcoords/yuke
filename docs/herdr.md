# herdr and `vercel-labs/fx`'s integration with it

Status: reference.
Source of truth: `https://github.com/herdrdev/herdr` and `https://github.com/vercel-labs/fx`.
Last verified: 2026-09-09.

This document records how herdr exposes itself to agent harnesses, and how `vercel-labs/fx`
(hereafter "fx") plugs into that surface. It is descriptive. It does not prescribe how yuke
should integrate; the protocol yuke defines lives in `lib/proto/`, and herdr's protocol is
herdr's.

## 1. What herdr is

`herdrdev/herdr`, Apache-2.0, written in Rust as a single binary. Tagline:

> the runtime your coding agents live on.

Herdr keeps terminals running in a background server so panes survive SSH drops and machine
restarts. The server persists a layout and can resume supported agent sessions; the original
processes do not survive a restart.

Herdr is shaped around AI coding agents rather than around the human operator. It tracks each
pane's agent state (`working`, `idle`, `blocked`) and ships an integration surface aimed at
agents, not at shell sessions.

## 2. Herdr's integration model

Herdr exposes three layers for external code that wants to inspect or control a session.

1. **Agent skill file** at `skills/herdr/SKILL.md`. It teaches an agent running inside a herdr
   pane how to drive herdr from the CLI. The file is installable through `npx skills add
   herdrdev/herdr --skill herdr -g`.
2. **CLI wrappers** (`herdr workspace …`, `herdr pane …`, `herdr tab …`, `herdr agent …`,
   `herdr api …`). They cover shell scripts, human debugging, and the quick bootstrap snapshot.
3. **Raw socket API** — JSON request/response over a Unix socket on Linux and macOS and a
   named pipe on Windows. It covers protocol clients and event subscribers.

The three layers share the same control surface. The socket path comes from the environment
variable `HERDR_SOCKET_PATH`.

Herdr also ships a separate **plugin** surface (`herdr-plugin.toml`). Plugins add UI, actions,
panes, and link handlers to herdr. The plugin surface extends herdr itself; it is not the
right tool for an agent harness.

## 3. Environment contract

Herdr injects these variables into every managed pane process:

- `HERDR_SOCKET_PATH` — path to the control socket for the current herdr server.
- `HERDR_PANE_ID` — public pane id, such as `w1:p1`.
- `HERDR_BIN_PATH` — absolute path to the running herdr binary.
- `HERDR_ENV=1` — set when herdr owns the pane. The skill safety rule is: "if `HERDR_ENV=1`
  is not set, the agent should stop and say it is not running inside a Herdr-managed pane."
- `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID` — present, alongside `HERDR_PANE_ID`.

The installed CLI can print the schema for the socket protocol with `herdr api schema`,
`herdr api schema --json`, or `herdr api schema --output herdr-api.schema.json`.

## 4. Lifecycle model

Herdr's per-pane agent state is a closed enum: **`working`**, **`idle`**, **`blocked`**.

- `working` — the agent produces output and does not need input.
- `idle` — the agent is ready for a prompt.
- `blocked` — the agent needs a user decision.

Custom agent integrations report state through the socket method `pane.report_agent`, whose
params are:

- `pane_id` — `HERDR_PANE_ID`.
- `source` — a stable string that identifies the integrator. Herdr reserves the `custom:`
  prefix for third-party reporters; fx uses `custom:fx`.
- `agent` — the human-readable name herdr shows in its UI.
- `state` — `working`, `idle`, or `blocked`.
- `custom_status` — optional, ≤ 32 bytes, a short label herdr renders next to the state.
- `seq` — optional, strictly increasing per `source`; herdr ignores stale sequence numbers,
  which gives the integrator a simple defense against out-of-order reports.

The integration releases its authority with `pane.clear_agent_authority` when the pane's
agent exits.

## 5. Session identity

A pane can carry an agent session reference through `pane.report_agent_session`. Params:

- `pane_id`, `source`, `agent` — same conventions as `pane.report_agent`.
- `agent_session_id` or `agent_session_path` — the integrator's reference. Herdr records it.
  When the agent launch command supports a `--resume=<id>` flag, herdr can use the id to
  resume the pane after a server restart.

Fx sends `agent_session_id` exactly once per process, at startup.

## 6. Wire format

A request is one line of JSON, terminated by `\n`. The envelope is:

```json
{"id":"<id>","method":"<method>","params":{...}}
```

The `id` is a **string**, not a number. The response is one line of JSON that echoes the id.
Herdr applies each request as it reads it; clients serialize rapid reports by waiting
briefly for the response before sending the next one.

Herdr's transport is plain stream I/O over a Unix socket (or Windows named pipe). No TLS, no
auth token — the socket is local to the user's account.

## 7. How fx integrates

fx is a Unix-style coding agent written in Zig. fx ships a single integration file:
`src/builtins/hooks/herdr.zig` (394 lines). The wiring lives in
`src/builtins/hooks.zig`. fx has **no installer script**, **no `herdr integration install fx`
command**, and **no `herdr-plugin.toml`**.

### 7.1 Where the Client sits

The integration's main type is `Client`. Its fields are:

- `enabled: bool` — set once during `initFromEnv`, cleared in `deinit`.
- `mutex: std.Io.Mutex` — guards the id counter and the per-call send.
- `socket_path: []u8`, `pane_id: []u8` — allocator-owned copies of the env values.
- `next_id: u64` — monotonic request id, also used to thread `seq` if the integrator sends
  one on the wire (fx does not send `seq` itself).

Module-level constants:

- `source = "custom:fx"`, `agent_name = "fx"`.
- `custom_status_max = 32` — the protocol limit.
- `response_timeout = { sec = 0, usec = 250_000 }` — applied as `SO_RCVTIMEO` per call.

### 7.2 Enable rules

The Client enables itself in `initFromEnv` when **all three** are true:

- `FX_HERDR` is unset, `1`, or any value other than `0` or `false` (case-insensitive).
  `FX_HERDR=0` is the explicit opt-out.
- `HERDR_SOCKET_PATH` is non-empty.
- `HERDR_PANE_ID` is non-empty.

When the Client is disabled, the wiring code returns early and registers no lifecycle
handlers. The lifecycle runtime stays small.

### 7.3 What fx sends

fx talks to herdr through four socket methods plus one cleanup method.

1. `pane.report_agent`
   Params:

   ```json
   {
     "pane_id": "<HERDR_PANE_ID>",
     "source": "custom:fx",
     "agent": "fx",
     "state": "working" | "idle" | "blocked",
     "custom_status": "<= 32 bytes, optional>"
   }
   ```

2. `pane.report_agent_session`
   Params:

   ```json
   {
     "pane_id": "<HERDR_PANE_ID>",
     "source": "custom:fx",
     "agent": "fx",
     "agent_session_id": "<stable fx session id>"
   }
   ```

3. `pane.rename`
   Params:

   ```json
   { "pane_id": "<HERDR_PANE_ID>", "label": "fx" | null }
   ```

   Sent twice: once at startup to label the pane, once at exit to clear it. `null` clears
   the label.

4. `agent.rename`
   Params:

   ```json
   { "target": "<HERDR_PANE_ID>", "name": "fx" | null }
   ```

   Note the key is `target`, not `pane_id`; this differs from the other methods. Same send
   pattern as `pane.rename`: once at startup, once at exit.

5. `pane.clear_agent_authority` (cleanup)
   Params:

   ```json
   { "pane_id": "<HERDR_PANE_ID>", "source": "custom:fx" }
   ```

### 7.4 Startup and exit sequences

Startup (in this exact order):

1. Read env and decide on `enabled`.
2. If a session id is available, send `pane.report_agent_session`.
3. Send `pane.report_agent` with state `idle` and no `custom_status`.
4. Send `pane.rename("fx")` and `agent.rename("fx")` so herdr lists the pane even while idle.
5. Register the lifecycle handlers.

Exit (in this exact order, run inside `deinit` so it fires on non-zero exit too):

1. `agent.rename` with `null`.
2. `pane.clear_agent_authority`.
3. `pane.rename` with `label=null`.

### 7.5 How it sends

fx uses a new socket connection per report. The send path is:

```
connect → set SO_RCVTIMEO → write one NDJSON line → drain one response line → close
```

Per-call connect-write-drain-close removes the need for reconnect logic and survives herdr
server restarts.

`SO_RCVTIMEO` is 250 ms. A hung herdr cannot block the agent beyond that.

A single `std.Io.Mutex` guards `next_id` and the write. Rapid lifecycle events serialize
cleanly against that mutex.

The wire writer is **hand-rolled**, not `std.json.stringify`. The `id` field is a JSON
string; generic stringify would emit a number and break the protocol. Each write function
takes the strings it needs and escapes them through a shared `writeJsonStr` helper. There is
a dedicated test that asserts a `pane_id` containing a quote escapes to `\"`.

The drain reads one response line into a 512-byte buffer with
`takeDelimiterInclusive('\n')`. Drain errors are swallowed; the response is used only for
serialization, never for branching.

fx skips the whole send path on wasm builds (`if (comptime host_target.is_wasm) return;`).

### 7.6 How fx wires it to its lifecycle

The wiring is a generic `Runtime(comptime App: type) type` in `src/builtins/hooks.zig`. The
generic takes the application type and returns a struct with one public `configure` method,
one public `reportWorking` helper, and two internal handlers.

`configure(app, active_session_id)`:

- Runs `app.herdr.initFromEnv(app.alloc)`.
- Returns early when the Client is not enabled. In that case no handlers register.
- Sends the initial session id when the caller provides one.
- Sends `pane.report_agent` with `.idle` and no custom status.
- Sends the `pane.rename` + `agent.rename` pair.
- Registers `postTurnEnd` and `attentionRequired` against the lifecycle runtime.

`postTurnEndHandler` calls `reportState(.idle, null)`.
`attentionRequiredHandler` calls `reportState(.blocked, attentionStatus(kind))`. The status
strings are `"permission"`, `"question"`, and `"recovery"`.

Both handlers **filter on `invocation.scope.kind == .interactive`**. Non-interactive
invocations (`.ask`, `.acp`) never send a report. This keeps headless and programmatic runs
quiet on herdr.

`reportWorking` is exposed publicly. The runtime calls it once at the start of every turn.

### 7.7 Mapping table

| fx event                                  | herdr `state` | `custom_status` |
|-------------------------------------------|---------------|-----------------|
| `postTurnEnd` (interactive only)          | `idle`        | —               |
| Turn start (`reportWorking`)              | `working`     | —               |
| `attentionRequired` (`.permission`)       | `blocked`     | `"permission"`  |
| `attentionRequired` (`.question`)         | `blocked`     | `"question"`    |
| `attentionRequired` (`.route_recovery`)   | `blocked`     | `"recovery"`    |

### 7.8 How fx tests it

fx uses two test layers.

**Wire-shape tests.** One test per emitted method. Each test allocates an
`std.Io.Writer.Allocating`, writes the request, and compares the buffer against the exact
expected string with `expectEqualStrings`. A dedicated test asserts that `clampStatus` caps
at 32 bytes and that `null` and empty strings map to no status. A dedicated test asserts JSON
escape of `pane_id`. These tests never open a socket.

**Recording-client test.** A test wires `Runtime` against a fake app whose `herdr` field is a
`RecordingClient`. The test then drives `configure`, `reportWorking`, the lifecycle frozen
view's `runPostTurnEnd`, and `runAttentionRequired` with a mix of `.ask`, `.interactive`,
and `.acp` invocations. It asserts the report sequence in order:

```
idle, working, idle, blocked-permission, blocked-question, blocked-recovery
```

Non-interactive invocations produce no record. The test also has a sibling that asserts a
disabled Client registers no lifecycle handlers at all.

The split keeps network-free JSON-shape tests separate from behavior tests. The wire-shape
layer catches a protocol regression without touching a socket.

## 8. Things fx deliberately does not do

fx is a self-configuring reporter, not a coordinator. The cuts are deliberate.

- fx does **not** use `events.subscribe`. fx cannot observe other panes or other agents.
- fx does **not** drive herdr on the user's behalf — no splits, no neighbor waits, no agent
  launches.
- fx does **not** ship an installer that herdr recognizes. There is no
  `herdr integration install fx`, no entry in herdr's marketplace.
- fx does **not** send `seq` on the wire. fx relies on the response drain to serialize
  reports. Herdr accepts the rare duplicate or missing report when the server hangs.

## 9. Reference facts

- Herdr repository: `herdrdev/herdr`. Apache-2.0. Rust. ~37k stars at this writing.
- Herdr site: `https://herdr.dev`. Docs root: `https://herdr.dev/docs/`.
- Socket API doc: `https://herdr.dev/docs/socket-api/`.
- Integrations doc: `https://herdr.dev/docs/integrations/`.
- Agent skill doc: `https://herdr.dev/docs/agent-skill/`.
- Plugins doc: `https://herdr.dev/docs/plugins/`.
- fx repository: `vercel-labs/fx`. Apache-2.0. Zig. Two integration files:
  `src/builtins/hooks/herdr.zig`, `src/builtins/hooks.zig`.
