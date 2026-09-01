# Daemon hooks and tools — external process design

Status: proposal, accepted direction.
Source of truth: this design until `src/daemon/` implements the child protocol.
Last verified: 2026-08-31.

## Decision

The daemon does not embed QuickJS. It runs workspace hooks and custom tools as external
processes. QuickJS remains available to the TUI for client-side customization.

This split keeps the daemon state in Zig. It also gives each invocation a clear cleanup boundary.
The script selects its own runtime, so JavaScript hooks can use normal ESM imports and package
dependencies. Hooks can also use Python or native executables.

The daemon supports two configuration scopes:

- A user configuration applies to every workspace. `src/paths` resolves its XDG location.
- `<workspace>/.yuke/config.json` applies only to sessions for that workspace.

The workspace configuration contains executable commands. The daemon must not load it until the
user trusts the canonical workspace root.

## Invariants

- Zig owns the protocol, session, run, permission, and database state.
- A child receives an immutable data snapshot. It never receives a daemon pointer or native
  handle.
- The daemon selects workspace hooks and tools from the session's `workspace_id`.
- A durable idle session does not own a process or extension runtime.
- A local MCP process has run lifetime by default. It never has durable session lifetime.
- The daemon validates every child response before it applies a decision or returns a tool result.
- A command runs directly from an argument array. The daemon never adds an implicit shell.
- The daemon enforces time, input, output, and process limits.
- Workspace hooks run with the user's operating-system permissions. They are not a sandbox.
- The child-process protocol is separate from `lib/wire` and `schema/wire.json`.

## Configuration

V1 uses one fixed file. It does not need a package manifest.

```json
{
  "version": 1,
  "hooks": {
    "tool.before": [
      {
        "command": ["node", ".yuke/hooks/protect-files.mjs"],
        "timeout_ms": 2000,
        "failure": "deny"
      }
    ],
    "tool.after": [
      {
        "command": ["node", ".yuke/hooks/audit.mjs"],
        "timeout_ms": 5000
      }
    ]
  },
  "tools": [
    {
      "name": "workspace_search",
      "description": "Search the workspace index",
      "input_schema": {
        "type": "object",
        "properties": {
          "query": { "type": "string" }
        },
        "required": ["query"]
      },
      "command": ["node", ".yuke/tools/search.mjs"],
      "timeout_ms": 30000
    }
  ],
  "mcp": {
    "issues": {
      "transport": "stdio",
      "command": ["node", ".yuke/mcp/issues.mjs"],
      "protocol": "legacy",
      "lifetime": "run",
      "request_timeout_ms": 30000,
      "tools": ["search_issues", "get_issue"]
    }
  }
}
```

Relative executable and argument paths resolve from the canonical workspace root. Configuration
load rejects an empty command, an invalid schema, an unknown event, a duplicate tool name, an
unknown field, and a value outside its bound.

V1 does not support computed tool declarations. The daemon must know and validate the complete
model-visible tool surface before it sends a provider request.

## Invocation protocol

The daemon writes one versioned JSON value to the child's stdin and then closes stdin. The child
writes one JSON response to stdout. It writes diagnostic text to stderr.

Every invocation uses a common envelope:

```json
{
  "version": 1,
  "invocation_id": "hook_...",
  "event": "tool.before",
  "session": {
    "id": "ses_...",
    "config_rev": 12
  },
  "workspace": {
    "id": "ws_...",
    "root": "/absolute/canonical/path"
  },
  "run": {
    "id": "run_...",
    "timeout_ms": 2000
  },
  "payload": {
    "tool": "bash",
    "input": {
      "command": "zig build test"
    }
  }
}
```

Each event defines a closed `payload` schema and a closed response schema. The daemon does not
send the complete transcript, credentials, provider secrets, database paths, or unrelated daemon
state. A later API can add a narrow query channel if a concrete hook requires more data.

The daemon uses a minimal environment and the canonical workspace root as the child working
directory. The JSON envelope is authoritative. Environment variables must not duplicate mutable
invocation state.

The protocol version covers framing and common fields. Each event schema changes deliberately.
The implementation must provide generated TypeScript declarations and JSON examples from the
same Zig types that encode and validate child messages.

## Hook classes

Hooks form a closed set. V1 does not expose a generic daemon event or arbitrary state mutation.

An observer runs after an authoritative operation. It cannot change the operation result. An
observer returns `{}`. A process failure, invalid response, or timeout records a notice and lets
the daemon continue.

An interceptor runs before a specific operation. It returns one closed decision:

```json
{ "decision": "allow" }
```

```json
{
  "decision": "deny",
  "reason": "The command accesses a protected path"
}
```

```json
{
  "decision": "prompt",
  "reason": "The command requires user confirmation"
}
```

An interceptor configuration must select `failure: "deny"` or `failure: "continue"`. The daemon
uses that policy for process failure, timeout, and an invalid response. It never infers a decision
from a language exception or stderr text.

Initial event candidates are:

- `session.start` and `session.end` observers.
- `run.before` interceptor and `run.after` observer.
- `tool.before` interceptor and `tool.after` observer.
- `message.committed` observer.

The implementation must add an event only at a stable daemon state boundary. It must specify
ordering, timeout, failure, and payload semantics before it adds the event.

V1 runs matching hooks in configuration order. It does not run background observers. This keeps
ordering, shutdown, and error reporting deterministic. A later async observer mode must track
every child until exit and apply a separate concurrency bound.

## Custom tools

A custom tool declaration contains static model-visible metadata and one command. The daemon
validates provider tool input against `input_schema` before it starts the child.

The child receives the common envelope with the validated tool input. It returns the yuke tool
result shape for the child protocol version. A nonzero exit, invalid JSON, schema mismatch,
timeout, or output overflow becomes a tool error. It never crashes the daemon.

Global and workspace tool names share one session-visible namespace. Duplicate names fail during
configuration load. V1 does not permit an implicit workspace override.

## MCP tools

MCP is a persistent transport within one run. It is not a daemon hook system. Yuke hooks keep the
one-shot child protocol in this document. MCP servers expose external tools.

V1 supports local stdio servers and the legacy MCP lifecycle through protocol revision
`2025-11-25`. This path sends `initialize`, receives the server capabilities, sends
`notifications/initialized`, lists tools, and then accepts tool calls. The implementation pins the
revision and keeps the legacy state machine separate from the modern protocol.

The current `2026-07-28` protocol removes the initialize handshake and protocol sessions. It puts
version and capability metadata on every request. Support for this protocol is a named later
stage because many deployed stdio servers still use the legacy lifecycle.

The default MCP ownership key is `(run_id, server_id)`:

```text
run starts
  -> start the configured MCP servers
  -> initialize and list tools
  -> run the provider and tool loop
  -> cancel pending MCP requests
  -> close, terminate if necessary, and reap each server
run ends
```

One process serves every call to that server during the run. It does not survive after the run
finishes or fails. A durable session and an idle workspace own no MCP process.

This lifetime preserves connection state between tool calls in one run. It does not promise that
a legacy server handle remains valid in a later run. A server that returns a durable handle must
persist the handle state outside its client connection. Yuke does not preserve hidden server
state by keeping an unbounded process cache.

Each MCP call carries yuke context in namespaced request metadata when the selected MCP revision
supports request metadata:

```json
{
  "dev.yuke/sessionId": "ses_...",
  "dev.yuke/runId": "run_...",
  "dev.yuke/workspaceId": "ws_..."
}
```

This metadata is an immutable routing and diagnostic snapshot. It does not grant authority. A
normal MCP server may ignore it.

The daemon exposes an MCP tool with a deterministic name such as
`mcp__<server_id>__<tool_name>`. It keeps a reverse map to the original names. It normalizes once,
adds a stable hash suffix when necessary, rejects unresolved collisions, and sorts the final tool
list. V1 requires an explicit per-server tool allowlist and a hard catalog bound.

The MCP client implements:

- Strict newline-delimited JSON-RPC over stdin and stdout.
- A separate stderr diagnostic stream.
- Request identifiers and a pending-request map.
- `tools/list` pagination with repeated-cursor detection.
- `tools/call`, including `content`, `structuredContent`, and `isError`.
- Input and output schema validation.
- Per-request deadlines, `notifications/cancelled`, and late-response rejection.
- Process exit, protocol failure, and invalid stdout as errors for the affected server only.

Tool annotations and server descriptions are untrusted metadata. They never bypass the yuke
permission policy. MCP roots, sampling, logging notifications, elicitation, resources, prompts,
tasks, and legacy SSE are outside the first implementation.

## Process ownership and cancellation

The daemon owns every one-shot child and MCP server from spawn through reap. A child record
contains the invocation, session, run, workspace, deadline, output counters, and process-group
handle. An MCP record also contains the protocol state, tool catalog, request ID allocator, and
pending-request map.

Cancellation stops admission of new output, terminates the complete process group, drains the
pipes, and reaps the child. On Windows, the equivalent implementation uses a Job Object. A child
must not survive its invocation unless a future persistent-worker contract explicitly permits it.

An MCP server gets a graceful shutdown before process termination:

1. Stop new MCP calls.
2. Send cancellation for each active request.
3. Reject and remove every pending request.
4. Close the server stdin.
5. Wait for normal exit for a bounded grace period.
6. Terminate the process group.
7. Kill it after a second bounded grace period.
8. Drain stdout and stderr, then reap the process.

Every response lookup includes the MCP process generation. A response from a retired generation
cannot complete a request in a replacement process.

The daemon bounds:

- The JSON input size.
- Captured stdout and stderr.
- Execution time.
- Concurrent children globally and per session.
- Tool and hook counts per configuration.
- Tool schema depth and size.

The daemon sends no secret environment variable by default. A future secret capability must name
each value explicitly and must not expose the daemon's complete environment.

## Configuration lifetime and reload

The daemon caches parsed configuration, not executable code. A configuration generation is the
hash of the canonical configuration path and its complete contents.

A valid change applies to the next invocation. An active child keeps its original immutable input
and failure policy. An invalid replacement disables that workspace generation and reports the
error. The daemon must not silently retain an old executable policy after the user changes the
file.

Script imports and module caching belong to the selected child runtime. A normal command exits
after one invocation, so its runtime releases the complete module graph. The daemon has no module
cache and no workspace VM to evict.

An MCP stdio runtime exits at the run boundary. A source or configuration change therefore applies
when the next run starts. V1 does not cache an MCP process or its hidden state across runs.

## Trust and security

Workspace configuration is executable repository content. Discovery may report it before trust,
but the daemon must not start its commands before an explicit trust decision.

Trust applies to the canonical workspace root. V1 exposes the full user permission boundary after
trust because a command can start another command or access paths outside the workspace. Path
validation alone cannot make an external command a sandbox.

The daemon must still reduce accidental exposure:

- Use direct argv execution.
- Use a minimal environment.
- Set the workspace root as cwd.
- Do not pass credentials or provider secrets.
- Bound all input, output, time, and concurrency.
- Show the exact command and configuration source in diagnostics and permission UI.

Untrusted automation requires a later operating-system sandbox or remote worker. QuickJS would
not provide that security boundary.

## Deferred extensions

- HTTP hook handlers with the same JSON schemas.
- Modern MCP `2026-07-28` negotiation and request metadata.
- Streamable HTTP MCP with OAuth 2.1.
- MCP tool-list change subscriptions.
- A persistent daemon-scope MCP mode when measurements and a concrete stateful server require it.
- An MCP discovery cache keyed by the full server configuration fingerprint.
- MCP resources, prompts, and multi-round-trip elicitation.
- MCP tool search for large catalogs.
- A persistent JSON-RPC worker mode when measurements show process startup is material.
- Background observers with explicit concurrency and shutdown ownership.
- Capability-scoped secrets and environment values.
- A package manifest, alternate entrypoints, and dependency metadata.
- A sandbox profile for untrusted workspace automation.

A persistent worker remains workspace-scoped and receives explicit session and run identifiers.
It must support restart, cancellation, memory bounds, stale-generation rejection, and clean
shutdown. Do not add it as an implicit optimization.

## Build order

1. Define the closed configuration and child-protocol Zig types outside `lib/wire`.
2. Add strict JSON decode tests for accepted and rejected configuration and child responses.
3. Add workspace discovery, canonical-root lookup, and explicit trust gating.
4. Implement direct process spawn, bounded pipes, deadlines, process-group cancellation, and reap.
5. Add observers with deterministic order and continue-on-failure behavior.
6. Add interceptors with explicit failure policy and closed decisions.
7. Add static custom tools and session-local tool routing.
8. Add the legacy MCP stdio state machine, tool discovery, calls, cancellation, and run teardown.
9. Generate TypeScript declarations and executable protocol fixtures.
10. Add memory, process-leak, cancellation, and concurrent-session tests.

## Rejected daemon design

The daemon does not use one QuickJS context per session or workspace. A long-lived daemon would
need a module-cache eviction policy, promise and job ownership, context teardown, allocator
telemetry, and an embedded capability boundary. External processes provide a simpler and stronger
lifetime boundary. They also support standard imports without a daemon module loader.

## References

- MCP `2026-07-28` specification: <https://modelcontextprotocol.io/specification/2026-07-28>
- MCP `2025-11-25` schema: <https://github.com/modelcontextprotocol/modelcontextprotocol/tree/main/schema/2025-11-25>
- MCP stdio transport: <https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio>
- MCP tools: <https://modelcontextprotocol.io/specification/2026-07-28/server/tools>
