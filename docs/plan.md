# yuke daemon — build plan

Status: current.
Source of truth: `lib/wire/`, `src/`, and the test suite.
Last verified: 2026-09-01.

The daemon exposes the wire protocol to web clients over HTTP + WebSocket. A TLS-terminating
proxy sits in front, so the daemon serves plain HTTP. The stack is std-first on the zio reactor.

THE CODE IS THE SOURCE OF TRUTH FOR BEHAVIOR. This file holds only what the code cannot state: the
decisions behind it, the reversals a reader would otherwise undo, the failures we accept on purpose,
and the work not yet built. Delete a section when the code makes it redundant.

## Locked decisions

- **Reactor:** zio `v0.16.0`, single executor (`.exact(1)`). One owner for all daemon state.
  No locks. If parallelism is ever needed, shard into independent runtimes, never shared locks.
  Callers use `std.Io` (`rt.io()`). Native `zio.spawn` / `Channel` / `select` leave the daemon
  before the relay pool.
- **HTTP server:** `std.http.Server` (sans-IO, over `*std.Io.Reader`/`*std.Io.Writer`). No
  third-party server; they own their own IO loop and fight the reactor.
- **WebSocket:** owned `lib/websocket` (sans-IO RFC 6455). Vendored from wssup for the
  client role plus framing. The server role is added by yuke. std's WebSocket is too minimal.
- **TLS:** none for inbound (proxy terminates). `std.crypto.tls.Client` for outbound (providers,
  relay).
- **Offload:** `zio.Runtime.spawnBlocking` is the native `await blocking(fn)`. No offload library.

## Concurrency model

- The reactor owns all state and runs every stateful path. No locks.
  Daemon tasks, queues, and waits use `std.Io` (`Group.concurrent`, `Queue`, `Event`, `Select`).
  Only `main` constructs `zio.Runtime`.
- Daemon hooks and custom tools run as bounded external processes. They receive immutable JSON
  snapshots and never touch reactor state. See `docs/daemon-extensions.md`.
- `await blocking(fn)` = `zio.Runtime.spawnBlocking`: run a pure native leaf on a worker,
  resume on the reactor with the result. The leaf touches no reactor state.

## Build slices

Slices 1-6 are DONE: the HTTP front door, `lib/websocket`, wire JSON-RPC over `/ws`, daemon `State`,
the session and event stores, and notifications with backpressure and resync. Read the code.

7. **Auth / login** — `yuke login` and device enrollment are built. Bearer-gated web access and
   daemon `auth.*` RPCs remain open.
8. **Provider config and catalog** — local config, catalog storage, the three-layer merge, catalog
   RPCs, conditional fetch, and optional account-bundle refresh are built.
9. **Outbound providers** — DONE except provider and tier failover: the streaming transport, the
   SSE reader, and retry are built.
10. **OAuth device flow** — the device-code enrollment is built. Relay enrollment remains open.
11. **Daemon extensions** — trusted global/workspace hook configuration; a versioned JSON child
    protocol; direct argv execution; bounded pipes; deadlines; process-group cancellation;
    observers, interceptors, static custom tools, and run-scoped MCP stdio tools. See
    `docs/daemon-extensions.md`.
12. **Relay / remote path** — Noise IK, the model-B link pool. See `docs/networking-plan.md`.

Tool engine (before slice 11): `read`, `write`, `edit`, and `exec` are DONE. Permissions are
DEFERRED by decision; see "Tool engine" below.

## Order of work (set 2026-09-01)

1. **Write-time framing.** Move WebSocket framing out of the producers and into the connection
   writer. The outbox carries wire JSON. `src/daemon/rpc.zig` stops importing the websocket module,
   which is the acceptance test. This is step one of the mux, not relay preparation.
2. **`lib/mux`.** Port `../yuke-ts-sdk/src/mux/` against `docs/session-protocol.md`: the six-byte
   frame, credit windows, two-class scheduling, and stream 0 for the wire JSON-RPC. The local path
   moves to the mux first, because the relay must never see the superseded chunker.
3. **Relay.** Noise IK responder, the parked control link, dial and data links, reconnect, and the
   peer roster for identity. See `docs/networking-plan.md`.
4. **Async child sessions.** See `docs/async-subagent-design.md`.
5. **System prompt and project/skills discovery.**

The container host is DEFERRED behind all five.

## Deferred (named, not smuggled)

- **Full RFC 6455 conformance beyond wssup** — validate against the Autobahn suite; add incremental
  UTF-8 validation across fragments.
- **Improve the wire request decode** — `rpc.Request.jsonParse` builds a `std.json.Value` (DOM)
  first, then the typed value. That double-allocates and makes `ParseOptions.max_value_len`
  ineffective. Switch to streaming `std.json.innerParse` per method arm. This bounds token size at
  decode and cuts allocation. It touches the contract-generating codec, so do it as its own change.
- **Per-field wire bounds at the point of use** — hex-id validation (once an id becomes a storage
  key/path), array caps, and JS-safe id issuance. Add each at the real caller, not at a generic
  ingress. The frame-size cap is the only ingress boundary.

## Engine E1 leftover (queued 2026-08-23, still open)

Only one item survives from the E1 design discussion — a "saved to the transcript but NOT sent to the
LLM" field:
- `build.zig` (transcript -> request IR) is the boundary of what the model sees. Anything stored on a
  message is auto-excluded from the model unless build.zig maps it.
- Add later as a DELIBERATE wire change: (1) a build.zig skip rule so a canceled or failed turn's
  partial CONTENT is not replayed to the model; (2) an optional display-only `detail` on the assistant
  message for UX information — cancel reason and who canceled, "interrupted after N tokens", retry
  count, and later operational notices. Size the field to the exact chosen set.
- The mid-conversation `system` role is the right carrier for these operator notices. See the machine
  result section of `docs/async-subagent-design.md` for why that role and not another.

## Retry / backoff (BUILT 2026-08-27; `src/provider/retry.zig` is the source of truth)

The classifier, the loop, the header parsing, the run budget, and the `retrying` activity all exist and
are tested. Read the code for behavior. Only the notes below still matter.

DECISIONS THAT MUST NOT BE RE-LITIGATED FROM MEMORY:
- **The jitter is `random(0.75, 1.0)`, the Anthropic and OpenAI SDK form. It is NOT AWS Full Jitter**
  (`random(0, cap)`). Do not "fix" it into the other without deciding that on purpose.
- **`max_attempts = 5` is a yuke choice, not a norm.** The SDKs, Vercel AI, and fx all ship 3.
- **A 5xx allowlist was REJECTED.** fx retries only 500, 502, 503, 504. Anthropic returns **529** for
  overloaded, which that allowlist would drop, so all of 500-503 and 505-599 stay repeatable.
- **An unclassified 429 is TERMINAL.** A rate limit must prove itself with a positive code. A spend cap
  and a rate limit share the status, and an unreadable body must never become a retry.
- **A `possibly_sent` transport failure is TERMINAL, with no fallback.** Neither Anthropic (Messages)
  nor OpenAI (Responses/Chat) documents `Idempotency-Key`, and fx sends no such header. There is no
  second branch. Do not invent a key and assume it works.
- **Never wait with a plain sleep.** `cancel_run` is a cooperative flag, so a sleeping task never sees
  it. The loop waits on `slot.wake_event` with a timeout. A plain sleep held the run for the whole
  delay; a test caught it.
- **A retry must resend the exact bytes.** `resolvedRequest` is deterministic, so the prompt cache
  prefix survives a repeat. Never put an attempt number anywhere in the request.

STILL OPEN:
- **No accumulated-delay cap.** The budget counts 8 permits per run and no wall-clock. Eight retries
  each honoring a 120s `Retry-After` can hold a run for about 16 minutes. Cancel works throughout.
- **`Retry-After` as an HTTP date is ignored**; integer seconds and `retry-after-ms` are parsed. Our
  providers send the numeric forms, so this is low value.
- **No per-attempt logging.** See the `@todo(xyaman)` on `publishRetrying` for the exact fields.
- **Request phases: DEFERRED, probably forever.** The two-state `AttemptInfo.delivery` already covers
  the case that matters, because a DNS failure happens before the mark and stays retryable. Finer
  phases would buy little.
- Undecided: the clean empty-response case, a transient 409 path, and nested-retry accounting when a
  gateway retries beneath us.
- **Failover stays a SEPARATE outer layer with its own budget.** LiteLLM and OpenRouter couple retry
  and fallback; yuke does not. A failover is a new logical attempt, never hidden inside the retry count.

## Tool engine (BUILT 2026-08-27; `src/tools/` is the source of truth)

`read`, `write`, `edit`, and `exec` all exist, are registered, and are tested. Read the code for
behavior. Only the notes below still matter.

DECISIONS THAT MUST NOT BE RE-LITIGATED FROM MEMORY. Each reverses an earlier plan, so a reader who
knows only the old text will try to undo them:

- **Tool calls run SEQUENTIALLY, one at a time in provider order (REVERSED 2026-08-27).** The earlier
  "unlimited concurrency, no admission, no caps" rested on a claim that is now false: opencode added
  per-path locks in PR #40641 after issue #40620 lost an edit, and goose only serializes by accident.
  Claude Code, Codex, Cline, OpenHands, and Aider all serialize mutating tools. NO researched harness
  runs unguarded parallel same-path mutation.
  The deciding argument: a per-path lock CANNOT protect `exec`, because `exec {command, cwd?}` does not
  declare the paths it writes. The case that justified concurrency is the case a lock cannot fix.
  Local reads cost microseconds against a multi-second model round, so parallelism bought nothing.
  ACCEPTED FAILURE: two long `exec` calls in one response run one after the other, exactly as Claude
  Code accepts by design.
- **There is NO read-before-edit rule (REVERSED 2026-08-27).** No read-state table, no mtime or hash
  check. The model reads files with `exec` (`cat`, `sed -n`, `grep -n`) as well as with `read`, so a
  gate keyed on the `read` tool would reject a correctly grounded edit. Six of eight researched
  harnesses enforce nothing. THE GATE IS THE EXACT UNIQUE MATCH: `old_string` must appear exactly once
  unless `replace_all` is set. ACCEPTED FAILURE: a hallucinated `old_string` that happens to exist
  uniquely in a file the model never read.
- **`exec` runs fully on `std.Io` with NO blocking pool.** The planned `BlockingProcessDriver` was
  never built and is not needed. `SpawnOptions.pgid = 0` makes the child its own group leader, and a
  deadline or cancel escalates over the GROUP: SIGTERM, 2s grace, SIGKILL. `std.process.Child.kill` and
  zio's `childKill` signal one pid and zio's waits uncancelably, so neither can end a shell's
  descendants. KNOWN GAP: a descendant that calls `setsid` leaves the group and survives; only the
  container backend contains that.
- **Three `exec` rules that each prevent a specific failure.** Drain BEFORE reap, or the tail of the
  output is lost. Drain PAST the byte cap and discard, or a full pipe blocks the writer and the command
  reports a false timeout. Keep the HEAD and the TAIL of each stream, because a build prints its error
  last.
- **Local mode does NOT confine the filesystem.** All four tools anchor a relative path at the canonical
  workspace root and expand a leading `~`, but `..` and absolute paths reach anywhere. This is
  deliberate; see "Execution isolation" below. The root is an anchor, not a jail.
- **Permissions are DEFERRED. V1 is YOLO-only.** The runtime auto-admits every call and never enters
  `waiting_permission`. This is low-regret: the wire and domain already model `permission.decide`, the
  five option kinds, `waiting_permission`, and the error codes, so the gate is purely additive later.
  Keep the `PermissionMode` wire field and DB column intact, and document that strict and normal are
  not enforced yet.
  When it lands: per-session strict/normal/yolo; default risk classes read allow(normal)/prompt(strict),
  write/edit/exec prompt(normal)/allow(yolo)/prompt(strict); a prompt emits
  `tool.state_changed(waiting_permission)` with stable options and blocks the run on a per-call
  `std.Io.Event`; persistent allow_always and reject_always need new DB tables plus
  `permission.rules`/`permission.forget`. Restart during a wait recovers the run as canceled. Rule
  granularity and hook-allow precedence stay undecided. This bullet is the whole record; there is no
  separate tool-runtime design document.
- **A same-path race between two mutating calls is STILL possible** across sessions or against a human
  editor, and the exact-match gate cannot catch a lost update where both sides read before either
  writes. Sequential execution removes it within one session only.

CONTEXT EFFICIENCY (a rule the turn engine must keep):
- Load the transcript ONCE per turn and append each round in memory. Never re-read and re-parse the
  whole transcript per round; OpenCode issue #29730 documents multi-gigabyte memory from that pattern.
- The resync window is NOT the model context. The window is client-recovery state; the context is
  token-budgeted and gets compacted.
- Eviction on idle is deliberate. A short TTL or LRU for recently-idle sessions is an optional future
  refinement, not a correctness issue.

## Daemon config: yuked.json (v1 SHIPPED; `src/daemon/config.zig` is the source of truth)

Deferred by user decision (2026-08-26): `default_model` (the client remembers the last model),
`default_permission`, `max_output_tokens`, `system_prompt_path`, `tools` booleans, and providers.json
validation. No `temperature`; the request IR has no field. No `default_provider`.
`small_model` is stored but not yet consumed; the first user is the auxiliary call below.
A basic `system_prompt` exists. Project and skills discovery, and system-prompt customization, remain
future work; `system_prompt_path` is one possible implementation detail, not the whole feature.

## Auxiliary model calls + session title (confirmed 2026-08-26)

A `Call` beside the `Turn` for non-turn LLM calls (design in `docs/model-call.md`, approved with 3
amendments). A Call reuses the provider transport/serializers/reducers/limits/cancellation but NOT the
turn transaction, transcript commit, assistant fold, or message.committed.

- Amendments to model-call.md: (1) keep Call beside Turn; (2) expose ONE low-level provider call plus
  thin task wrappers (like SDK generateText/generateObject) — drop the "no universal generate()" wording;
  (3) replace `output: text|json` with a future `OutputSpec` carrying a JSON Schema (a bare flag is too
  weak for a strict judge; validate locally even when the provider claims strict).
- `ModelCall` primitive -> new `src/provider/call.zig` (NOT src/engine — the engine owns turn txns).
  `generate(arena, io, ctx, ModelCallRequest{model, system, messages, max_output_tokens, output}) !
  ModelCallResult{text, usage, finish}`. Build a DIRECT RequestIr from messages (never a transcript),
  serialize via the existing Adapter, resolve model via `resolveModel`, open the body, run the reducer
  through `transport.stream` with a generalized `StreamCollector`. The transport callback and a
  test-only collector exist (transport.zig:262); build the generalized production collector.
  Own+deinit the body. Model tier: task override < `small_model` <
  session model < `default_model`.
- **Session title task (first aux use):** today the title is the workspace folder basename
  (`src/daemon/handlers.zig:640-641`) — no LLM. Trigger AFTER the first user message.committed (pass a
  first_session_message flag from the pre-commit snapshot; handles a queued batch). Schedule via
  `state.run_group.concurrent(io, runTitleTask, .{state, session_id})` capturing ONLY the session_id (an
  idle session can be evicted mid-call; do not retain a SessionRuntime ptr). 8s deadline (io.concurrent +
  Event.waitTimeout), max_output_tokens=32, no retries, no tools, untrusted-input system prompt. Sanitize
  (strip quotes/markdown, first non-empty line, reject control chars, UTF-8 truncate to the 256-char DB
  limit). Persist with a CONDITIONAL update (`WHERE title = :expected_fallback_title`) so a late task
  never clobbers a manual rename; on timeout/error/empty keep the folder title, never fail the turn.
- **Wire: no new event.** `session.summary_changed` ALREADY EXISTS (enums.zig:11, session.zig:280
  SessionSummaryChangedData, carries the full session summary incl. title) but is inert (event log omits
  it, domain ignores it). After the DB update, publish it directly (NOT emitDurable — it is intentionally
  outside the durable event log), bump an in-memory summary revision, and feed initialize.session_revision
  from that counter instead of always returning 0. Client session-list projections must fold it, merging
  the new session while preserving current activity. It is must-deliver (connection.zig classes it so).

## Execution isolation (doctrine + backend seam, confirmed 2026-08-26; 2-Luna security pass)

### Doctrine (the security posture)

- **In-process path/command checks are defense-in-depth, NOT a security boundary for a hostile or
  prompt-injected model.** "Application rules decide whether to ATTEMPT an operation; kernel/VM controls
  decide whether it CAN happen." Shell is Turing-complete, so a command denylist is not a boundary
  (AutoGPT CVE-2024-6091: `/bin/./whoami` bypassed the denylist). Symlink/TOCTOU/hardlink escapes are
  real and cross-agent (Wiz "GhostApproval" — repo-controlled symlink turned a local edit into a write
  to `~/.ssh/authorized_keys` across 6 assistants; Claude Code CVE-2025-54795, CVE-2026-55607).
- **Local mode does NOT confine the filesystem (user decision 2026-08-26).** In-process path checks are
  not a security boundary (they only catch mistakes), so yuke does not restrict `read`/`write`/`edit`/
  `exec` to the workspace in local mode — the trusted local user's tools may reach anything. The canonical
  workspace root is still the dedup key, the `exec` cwd, the base for resolving a RELATIVE tool path, and
  the container bind-mount source — an anchor, not a jail. Recovery from a bad edit/command = git +
  snapshots/rewind (under research), NOT a path rule. Real confinement comes from the container backend,
  where the bind-mount defines what is reachable. (If a future opt-in hardened LOCAL mode is wanted,
  `openat2 RESOLVE_BENEATH` / no-follow is the kernel-atomic way — but it is not the V1 default.)
- **Filesystem confinement does NOT stop EXFILTRATION.** The "lethal trifecta" (private data + untrusted
  content + network egress) leaks secrets through an ALLOWED channel (GitHub-MCP attack; EchoLeak
  CVE-2025-32711). So network-egress-deny-by-default + secret-scoping matter as much as paths. The remote
  LLM API, logs, commits, and tool output are all exfil channels.
- **The isolation ladder (none is 100%; pick by threat model):** in-process rules < kernel sandbox
  (Landlock — note it DOES restrict network by port since ABI v4 / seccomp / macOS Seatbelt / OpenBSD
  pledge+unveil) < container (shared kernel; runc escapes CVE-2019-5736, CVE-2024-21626) < microVM
  (gVisor / Kata / Firecracker) < full VM + air gap. "Use Docker" is a middle rung, not the definition of
  secure; ordinary Docker is not a hostile-code boundary.
- **yuke posture:** local mode = trusted-single-local-user, FULL host access (no fs confinement); the
  startup/session posture message must say so plainly. Real isolation = run exec in a container/microVM
  with network denied (the bind-mount is the boundary). Exec LIFECYCLE HYGIENE (process-group kill,
  output caps, deadline, drain/reap) stays required in BOTH modes — it is hygiene, not confinement.

### ExecutionBackend seam (extends the ProcessDriver)

Generalize the `ProcessDriver` into an `ExecutionBackend` seam (outside `std.Io`; std.Io stays the
transport the impls use) with backends `local` (now) -> `container` (Docker/Podman) -> `microvm`
(Firecracker/Kata/Apple container) later. No backend-specific type reaches the tool engine.

```zig
pub const ExecutionBackend = struct {
    openSession(io, SessionSpec) !SessionHandle;
    spawn(io, SessionHandle, SpawnSpec) !ProcessHandle;      // SpawnSpec{argv, cwd_relative, workspace, env, network, limits, deadline}
    read(io, ProcessHandle, Stream, []u8) !usize;            // stdout/stderr independently drainable, bounded
    wait(io, ProcessHandle) !ExitStatus;                     // guarantees drain + reap
    killGroup(io, ProcessHandle, KillReason) !void;          // idempotent; process-TREE, not one child
    closeSession(io, SessionHandle) !void;                   // normal completion, cancel, shutdown
};
```
`WorkspaceMount{host_root, guest_root="/workspace"}` (local ignores guest_root). **The seam covers ALL
four tools (fs + exec), not just exec** — in container mode `read`/`write`/`edit` also run through the
backend (in-container), because native host fs would bypass the container and let the agent escape (user
decision 2026-08-26). Local backend = native fs + native child; container backend = docker for every op.
Write the native tools against this host interface so the container backend drops in with no rework.

### Container backend policy

- CLI adapter first (`docker run/exec/stop/rm`, structured argv, never a shell string); Docker API/socket
  later for warm sessions. Launch: `--mount type=bind,src=<canonical-root>,dst=/workspace` (NOT `-v`, it
  fails-closed on a missing src), `--workdir /workspace/<validated-rel>`, `--user <non-root uid:gid>`
  (match host UID so files aren't root-owned), `--network none`, `--read-only`, `--tmpfs /tmp`,
  `--cap-drop ALL`, `--security-opt no-new-privileges:true`, `--pids-limit`/`--cpus`/`--memory`, pin
  image by digest, label `com.yuke.session`. NEVER mount `$HOME`, SSH agent, provider creds, the DB, or
  the Docker socket. Enforce yuke's own output cap independent of docker logs. The mounted workspace IS
  fully exposed to the command — a container does not protect files inside the mount.
- Network: `none` only in the first slice. An allowlist must be firewall/namespace-enforced (NOT
  `HTTP_PROXY` env, which arbitrary programs bypass) and FAIL CLOSED. The daemon's own provider traffic
  is outside the exec container, so `network=none` does not block the LLM call.
- Placement: (A) per-call container = safest first + the conformance reference; (B) per-session warm
  container = production (needs an in-container supervisor for precise per-command cancel; container-stop
  is only an emergency cancel); (C) whole daemon in a container = deployment packaging, NOT the backend
  abstraction. Sequence A -> B.
- Real products: Codex (local Landlock/seccomp+Seatbelt, cloud container), Claude Code (Seatbelt/
  bubblewrap + allowlist proxy), Devin/Jules (per-task VM), OpenHands (Docker `/workspace` bind),
  Cursor (local sandbox + cloud Firecracker), e2b/Modal/Daytona (Firecracker/gVisor sandboxes).

### yuked.json `execution` field + fail-closed rule

Add `"execution": {"backend": "local"|"container", "image": "...@sha256:...", "network": {"mode":
"none"}}`. Default `local` (= "exec runs with host-user privileges; trusted workspaces only"). `container`
requires an image; reject container-only fields under `local`; strict decode. **If the user selects
`container` and Docker/Podman is absent, REFUSE execution with a clear error — do NOT fall back to local**
(silent fallback downgrades a requested security boundary; especially unsafe under yolo-only V1). Report
the effective posture at startup + session create.

### Slice order (execution)

Workspace canonicalization and the local execution floor are DONE; `exec` ships with process-group
cancel, bounded drains, and a deadline. The container work is DEFERRED behind the framing, mux, relay,
child-session, and prompt-discovery slices. When it starts, the order is: the ExecutionBackend seam (local = reference backend) -> container per-call backend (detect, structured
launch, bind mount, non-root, network-none, cgroup limits, stop/rm cleanup, typed errors) -> container
hardening tests (missing engine/image, symlinked paths, writes outside mount, fork bomb/pids, output
flood, SIGTERM-ignoring, timeout/shutdown, root-owned files, network/DNS fail, stale containers after
restart) -> warm per-session container (supervisor + per-command cancel + idle cleanup) -> microVM
backend (same contract over a guest agent; Firecracker/Kata/Apple container). Riskiest parts: canonical
mount correctness, fail-closed network, process-tree cancel, stale-container cleanup, image trust, UID
mapping, cold-start vs session-state.

## Snapshots + rewind (session.rewind, confirmed 2026-08-26; Luna research pass)

The recovery story for a bad local edit/command (local mode has no fs confinement). `session.rewind`
already exists as a wire method (`lib/wire/session.zig` `SessionRewindParams{session_id,
before_message_id}`) but the daemon returns `unknown_method` (rpc.zig ~133). Fill it.

- **Mechanism: private Git-shadow store** (NOT the user's `.git`). One shadow repo per canonical
  workspace under `<data>/snapshots/<workspace-id>/`, driven by explicit `GIT_DIR` + `GIT_INDEX_FILE` +
  `GIT_WORK_TREE` env, so it works even when the workspace is not a git repo. Store tree objects (a
  commit is optional; the tree hash restores the file set). Git gives content dedup + binary + tree
  manifests for free. Rejected alternatives: copy/backup snapshots (manifests/dedup by hand), and
  filesystem-native snapshots (btrfs/ZFS/APFS — not portable, don't coordinate the transcript). Keep FS
  snapshots as a future optional accelerator only.
- **Scope:** capture all regular files + symlinks below the canonical root; ALWAYS exclude `.git` and the
  snapshot dir. Do NOT apply the user's `.gitignore` — `exec` can write ignored files and rewind must
  restore them. Record explicit later exclusions (node_modules/build) as excluded; never claim rewind
  restored an excluded path.
- **Timing (V1): before each user turn + before each model round** (the round's whole tool batch is the
  atomic unit — yuke already commits the assistant round before the next request). NOT per-tool in V1.
  If a snapshot fails, do NOT start a write-capable round (fail the run instead). Snapshot work runs on
  the blocking child/worker seam and hands completion back to the executor — NEVER scan/hash/restore on
  the reactor.
- **`session.rewind(session_id, before_message_id)` = restore workspace + transcript to the checkpoint
  before that message.** Reject an active run/draft/queued inputs or a non-boundary id. Steps: resolve the
  checkpoint tree, restore the workspace files, then in ONE SQLite txn append `transcript.truncated`
  (`first_removed_id = before_message_id`), delete active `messages` rows >= the boundary, recompute
  `message_count`, bump `projection_seq`; then fold+publish `transcript.truncated` (the domain already
  trims from `first_removed_id`, session.zig ~315). Keep old event-log rows (replay + truncation ==
  same projection). NEVER move `seq_high`/`*_id_high` backward; `usage_total` stays lifetime.
- **Crash safety:** a durable `rewind_intent(session_id, target, tree_id, state)` journal — insert
  pending, restore files, then commit truncation + mark complete in one txn; retry a pending intent at
  startup (a crash between file-restore and truncation must not leave disk and model memory disagreeing).
- **Limits (state them):** rewind restores FILES under the root only — it cannot undo network, DB/service
  mutations, spawned processes, package side effects outside the root, or another process's later edits.
  Explicit rewind may overwrite later manual edits (a future workspace-fingerprint check + `force` option
  handles that). Container mode works via the bind-mount (host snapshots see container-written files).
- **Wire:** V1 needs NO change (message ids are the durable checkpoint boundary). Deferred deliberate
  additions for a polished UI: `session.checkpoints`/`checkpoint.list`, a `checkpoint_id`, restore
  preview, a `checkpoint.created` notification. Do NOT add speculatively.
- Slice order: contract/invariants -> shadow store (git dir/index/worktree, tree capture+restore, non-git
  + binary/delete/rename/symlink/large-file tests) -> checkpoint table + rewind-intent journal + retention
  -> turn/round integration -> transcript rewind handler (idle-only, restore, truncated txn, counters/
  high-water, restart recovery) -> projection/conformance tests (fold, resync-after-rewind, replay).
  Defer per-tool checkpoints, redo, checkpoint listing, FS-native acceleration, xattr/ACL.
