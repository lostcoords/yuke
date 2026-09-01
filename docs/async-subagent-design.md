# Async subagents — design spec (draft 2026-08-26)

Status: DRAFT for review. Research: two Luna passes (broad cross-system survey + focused yuke
spec pass, 2026-08-26) plus primary-source verification against `lib/wire/` and
`src/database/migrations/`. The subagent runtime, the spawn tool, the completion event and auto-resume
are not implemented. `session.remove` is implemented.
Last verified: 2026-08-31.
AMENDED 2026-08-27 after a code-verification pass. Four "already exists" claims were FALSE; each is
corrected in place and marked CORRECTED. Tool execution is now SEQUENTIAL, so this spec no longer
reuses a "tool batch". `docs/plan.md` is the decision record and wins on any conflict.

Corrections applied 2026-08-27:
- There is NO existing steering drain a completion can join. A new triggered-turn path is required.
- The completion is a durable INTERNAL ROW, never a wire event. A parent `events` row would advance the
  parent sequence with no `BroadcastData` variant, so a client would see a sequence gap.
- Retention, finished-child resume, and the child pin do NOT exist.
- `session.fork` returns `not_implemented`. `session.remove` has a live cascade implementation.
- The machine result block uses the USER role with a marker. See "Machine result representation".
- `cancel_agent` and `send_agent_message` ARE in V1 (user decision 2026-08-27, reversing dimension 4).

An async subagent lets the model spawn a **detached** worker that runs on its own, so the user can
KEEP TALKING to the parent agent while the child works. This is the variant that matters; the
synchronous "delegate and block on the result" variant is a trivial fallback (a slow tool leg) and
is NOT the subject of this spec.

## Decisions (locked with the user 2026-08-26)

1. **Completion delivery = AUTO-RESUME (wake the parent).** When a child reaches a terminal state,
   yuke records a DURABLE completion AND actively delivers it: an idle parent is woken into a new turn;
   a parent that is mid-run receives the completion at its next SAFE round boundary (the existing
   steering-drain path), never mid-stream. Multiple completions ready at once drain into ONE wake, not
   one turn each. The token cost of an unattended wake is ACCEPTED (consistent with unlimited
   max_rounds). Durability is retained for eviction/restart safety — the durable row is the source of
   truth; auto-delivery is the trigger. Precedent: this very session — a Luna task-notification woke the
   main agent to process the result. AVOID Claude Code's known auto-wake defects: route by the durable
   `parent_session_id` (never an in-memory pointer) so a completion cannot wake the wrong ancestor (CC
   #86963), and enqueue durably the instant the child terminates so nothing waits on an unrelated user
   message (CC #88378).
2. **No new wire family in V1 — and the completion is an INTERNAL ROW, not an event (CORRECTED
   2026-08-27).** This decision holds ONLY because the completion never reaches the wire. Writing it to
   the parent `events` table would advance the parent sequence with no matching `BroadcastData`
   variant, and every client would see a sequence gap. The child is just another session the client
   already models
   (`origin=child`), discoverable because `spawn_agent` returns the `child_session_id`. First-class
   `subagent.*` events + a `/tasks` UI are deferred-additive. (One `spawn_agent` tool descriptor is
   added to the tool catalog and `wire.json` regenerated — a tool-schema change, not a job protocol.)
3. **NO numeric limits in V1.** This means NO NEW ADMISSION CAP. It does NOT mean "no resource
   failure": the runtime still has a finite coroutine stack, a 24-bit group counter, memory, and SQLite
   limits, and each must surface as a TERMINAL FAILURE, never as a hang.
   No cap on children per parent, none daemon-wide, no nesting-depth cap,
   and `max_rounds` stays `null`=unlimited for children too. The runaway/cost risk is ACCEPTED, exactly
   as for unlimited turn rounds; `cancel_run` is the escape hatch. Keep an enforcement SEAM (a
   reservation call that always admits in V1) so caps drop in later with no rework. CONSEQUENCE: no
   depth cap means children spawn children, so the session forms an N-level TREE and the
   completion-delivery + cancel-cascade machinery is RECURSIVE from day one — an agent fork-bomb (and a
   model-driven spawn↔wake loop) is possible and accepted.

Tool name `spawn_agent`; children are **read-only** by default (below).

## Grounding — what already exists vs what is new (verified)

ALREADY MODELED (wire + DB), so this spec REUSES it — no protocol change:
- `SessionOrigin` union `root | child | fork`; `SessionOriginChild{parent_id, parent_message_id,
  parent_part_id}` (`lib/wire/session.zig:128-149`).
- `SessionPopulation` union `top_level | children(parent_id) | all` (`session.zig:176-202`) — the
  child-visibility filter for `session.list`.
- `sessions` table: `origin IN ('root','child','fork')`, `parent_id`, `parent_message_id`,
  `parent_part_id`, `workspace_id`, `agent`, `source_id`; a CHECK that a child carries all three
  parent marks and a non-child none; index `sessions_by_parent` (`0001_initial.sql:41-113`).
- `session.remove` params carry `cascade_children: bool = false`; error `session_has_children`
  (-31016) (`session.zig:204-208`, `enums.zig:204`).

STUB TODAY (wire designed, the fallback arm returns `not_implemented` at `rpc.zig:205-208`) — this spec
must FILL, not merely "reuse": `session.fork`. `session.remove` is implemented with its cascade at
`src/daemon/handlers.zig:482`.

IMPLEMENTED and reused as-is: `session.create`, `session.list` (population-aware), `session.send_input`,
`session.cancel_run`, the run coroutine, `TurnContext`, the sequential tool loop, `recoverOpen` restart
recovery.

CLAIMED BUT ABSENT (CORRECTED 2026-08-27) — each of these must be BUILT, not reused:
- **No steering drain exists.** The only queue drain runs AFTER a run ends (`run_task.zig:445`), and
  `beginQueuedTurn` requires a pending durable input (`engine/run.zig:112`). A completion has no
  `InputId`, so it cannot join that path. Build `beginTriggeredTurn`: a run with no user message, no
  `pending_inputs` row, and no fake user turn.
- **No `subagent.completion` wire path exists.** See decision 2. It is an internal row.
- **No child pin exists.** `SessionRuntime.idle()` (`session_runtime.zig:81`) checks active work, queued
  input, and fault state only. `state.run_group` owns TASK EXECUTION; `SessionRuntime` still owns the
  `RunSlot` allocation (`session_runtime.zig:12`), and `evictIfIdle` can destroy the whole runtime.
- **No retention worker and no finished-child resume exist.**
- **`sessions.parent_id` has NO foreign key** (`0001_initial.sql:46`), so SQLite will not cascade a
  subtree delete. The tree walk must be explicit. The project is PRE-RELEASE, so `0001_initial.sql` may
  be edited directly to add the key rather than shipping a compensating migration.
- **`session.fork` returns `not_implemented`** from the fallback arm (`rpc.zig:205-208`); the code
  exists at `lib/wire/enums.zig:223`. `session.remove` is implemented, but child cancellation and
  retention semantics stay open.

NEW build items (see "New mechanisms" below): the child-lifecycle projection table, the durable
`subagent.completion` parent event, the synthetic machine-origin context block in `TurnContext`, the
`spawn_agent` tool + its terminal-round special-casing, the always-admit reservation seam, and the
recursive (tree-wide) cascade + delivery.

## Core model

An async child is a **durable child session** with its OWN `SessionRuntime` and `RunSlot`. Its run is
owned by the daemon `run_group`, NOT the parent `RunSlot` — because the parent's `RunSlot` ends and
restarts across turns while the child outlives all of them. This is the whole reason the async variant
cannot be a tool call in the round loop: a tool call is bounded by the round. With no depth cap, a
child is itself a parent to its own children, so every rule below applies recursively down the tree.

Lifecycle:
1. Parent model emits `spawn_agent` (one or more in a response).
2. yuke reserves a slot (always admits in V1), creates the `origin=child` session linked to the parent
   session/message/part, and a child-lifecycle projection row.
3. yuke schedules the child run on `state.run_group`.
4. The parent commits the `spawn_agent` tool_use + an IMMEDIATE `accepted` tool_result, then
   **terminalizes its run**. A response containing `spawn_agent` is a TERMINAL parent round — yuke
   MUST NOT issue another provider request for that run.
5. The parent session accepts new user input normally (this is "keep talking").
6. The child runs independently to a terminal state (completed / failed / canceled).
7. yuke records the child terminal result and enqueues exactly ONE durable completion for the parent.
8. Delivery is ACTIVE (auto-resume): an idle parent is woken into a new turn; a busy parent receives the
   completion at its next SAFE round boundary (the steering-drain path), never mid-stream. Ready
   completions batch into one wake. Each renders as a synthetic machine-origin context block in
   `TurnContext`.

The parent is **pinned non-evictable** while any child link is `accepted` or `running`. A completion
that lands while the parent is evicted stays DURABLE and triggers reactivation-then-wake — no
forever-resident `SessionRuntime`, no lost result.

## The ten dimensions (decisions)

1. **Child session model.** Separate durable SQLite session per child (never ephemeral). Reuse
   `origin=child` + the three parent marks; do NOT add an `is_subagent` boolean (the closed `origin`
   discriminator already distinguishes it). Add a child-lifecycle projection keyed by
   `child_session_id` for state + exactly-once delivery (schema below). Visibility: `session.list`
   default stays `top_level` (children hidden); `population=children(parent_id)` and `all` expose them;
   a child id is always directly addressable. Retain finished children 30 days; GC only terminal
   children with no pending completion; finished children are resumable by session id.

2. **Spawn tool contract.** Name `spawn_agent` (`task` collides with task-managers; `agent` too broad).
   Input: `instructions` (required), `description?`, `agent_type` (closed set, default `researcher`),
   `model` (default `small_model`), `tools` (intersect the server agent profile, default `["read"]`),
   `max_rounds` (optional; `null`=unlimited, allowed for children per decision 3), `cwd` (relative under
   the parent workspace root, default root), `resume_session_id?` (a finished direct child). No full
   `system_prompt` replacement, no `permission_mode` (YOLO — a background child cannot wait for a
   prompt), no new workspace / arbitrary path. Returns immediately `{status:"running", job_id,
   child_session_id}` — `job_id == child_session_id`, the only identity needed.

3. **Async lifecycle + completion delivery.** Auto-resume (decision 1). NEVER attach the final result
   to the original `spawn_agent` tool_result — that result already means "accepted," and there is no
   open tool call after the parent turn ends. Instead record a durable `subagent.completion` parent
   event and deliver it actively: idle parent → auto-start a turn; busy parent → next safe round
   boundary (reuse the steering drain); batch ready completions into one wake. Render each as a
   machine-origin block in `TurnContext`, daemon-generated — never a fake user message or permission
   approval (prompt-injection hygiene). Route by the durable `parent_session_id`, never an in-memory
   current-agent pointer, so a wake cannot hit the wrong ancestor.

4. **Parent-child interaction while running — cancel and message ARE in V1 (user decision
   2026-08-27, REVERSING the earlier defer).** The parent model gets three tools, not one:
   - `spawn_agent` — start a child, return `{status, child_session_id}` at once.
   - `cancel_agent {child_session_id, reason?}` — stop a running child.
   - `send_agent_message {child_session_id, message}` — send text to a running child.

   Rationale: a parent that can only spawn and wait is much weaker than one that can steer. This
   session proved the point — the coordination that made today's work correct (a build.zig handoff, a
   research finding passed to another agent, a lane split, a security question routed to its owner) all
   used exactly these two operations.

   Both are THIN WRAPPERS over RPCs that already exist: `session.cancel_run` (`handlers.zig:392`) and
   `session.send_input` (`handlers.zig:331`). Neither adds a state machine of its own.

   CONSTRAINTS that follow, and that the completion path must survive:
   - A cancel may arrive while a completion for that child is already `in_flight`. The claim must
     resolve to exactly one delivered completion, never two and never zero.
   - `send_agent_message` targets a DIRECT child only. Validate the link; reject any other session id
     with `permission_unknown`. A parent must not message a grandchild or a sibling.
   - A message to a child that already reached a terminal state is an error, not a silent drop.
   - A child MUST NOT be able to message or cancel its parent. The link is a strict tree, so nesting
     stays acyclic and no parent-child wait cycle can form.
   - Neither tool terminalizes the parent round. Only `spawn_agent` does.

   The CLIENT keeps full direct access to a child by session id through the existing session methods,
   independent of these tools.

5. **Return shape.** One final text summary = the child's LAST COMMITTED assistant message (never a
   live draft; no forced extra "report" round — it costs tokens and cannot run after cancel). Machine
   status alongside: `{child_session_id, status, summary, run_id, usage}`; failure/cancel carry
   `error_code` + `partial:true` + whatever last output exists. Truncate the parent-visible summary to
   16 KiB; the full transcript stays in the child session. Deliver failed/canceled like success; no
   auto-retry. Structured-output schemas deferred.

6. **Concurrency / limits / runaway control — NO LIMITS in V1 (decision 3).** No cap on children per
   parent, none daemon-wide, no nesting-depth cap (a child MAY spawn), and `max_rounds` stays
   `null`=unlimited for children too. The runaway/cost risk is ACCEPTED, exactly as for unlimited turn
   rounds; `cancel_run` is the escape hatch. Keep the reservation SEAM (a call that currently always
   admits) so numeric caps drop in later with no rework. CONSEQUENCE of no depth cap: the session is an
   N-level TREE, so completion-delivery and cancel-cascade are RECURSIVE from day one — a fork-bomb of
   agents and a model-driven spawn↔wake loop are possible and accepted. NOTE 2026-08-27: several
   `spawn_agent` calls in ONE response are still allowed, but the daemon now PROCESSES them one at a
   time in provider order. Each spawn is cheap, so sequential processing costs nothing; the CHILDREN
   still run concurrently on `run_group`. The parent terminalizes after the last spawn call settles.

7. **Wire protocol.** No new RPC/event family in V1 (decision 2). Reuse `origin=child`, the population
   filters, the parent linkage, `session.cancel_run`, `session.remove(cascade_children)`, session
   subscriptions. Deferred-additive: `subagent.spawned|progress|completed|failed|canceled` events and
   `subagent.list|status|wait|send` — a `/tasks`-style UI derives from those + the child population.

8. **Cancellation / cleanup / failure.** No detach contract in V1. `session.cancel_run(parent)`
   cascades RECURSIVELY: cancel the parent run, then depth-first down the tree cancel every
   accepted/running descendant, kill each process-group, reap, persist each canceled, and enqueue one
   canceled completion to each node's parent. `session.remove`: `cascade_children=false` REJECTS
   deletion when children exist (`session_has_children`); `cascade_children=true` cancels live
   descendants, waits for terminalization, then deletes the whole subtree. A child's own `cancel_run`
   produces a canceled completion for its parent (unless the parent was deleted). Restart recovery:
   `recoverOpen` marks an open child run canceled → child link `canceled` (reason
   `daemon_restart_recovery`) → enqueue the pending parent completion; a crash AFTER child
   terminalization but BEFORE delivery is reconciled at startup by scanning terminal children with no
   delivered completion. `child_terminal_event_id` + `parent_completion_event_id` make delivery
   idempotent (exactly-once). No parent is auto-resumed DURING restart recovery; the wake fires on the
   parent's next activation.

9. **Execution backend / security.** Child shares the parent `workspace_id`, root, and backend
   config, but gets an INDEPENDENT execution scope (own process group; `cwd` under the root; no
   arbitrary path). NOTE 2026-08-27: sequential tool execution serializes calls WITHIN one session only.
Two sibling children still run at the same time, so the same-file lost-update risk applies ACROSS
sessions, and the read-only default is what contains it. Read-only tool set by default;
`edit`/`write`/`exec` require an explicit server-side
   agent profile — the parent model cannot widen the server's allowed tool set. Do NOT share a live
   container session between parent and child; each child gets its own env when container/microVM
   backends land. yuke's single reactor serializes daemon STATE, not FILESYSTEM writes by separate
   processes — so it does NOT prevent two children editing one file, a child reading stale content, or
   a parent rewind invalidating a child. Therefore V1 REJECTS `session.rewind` while any descendant is
   active; editing children, worktrees, leases, and merge handling are a later execution-isolation
   feature.

10. **Failure modes the spec must design out.** Unmatched tool_result (never attach a late result to a
    closed turn); RunSlot ownership leak (parent RunSlot ends; child owned by `run_group`); parent
    eviction mid-child (pin it); lost completion after restart (durable child terminal + delivery
    state, reconcile at startup); duplicate completion (stable event ids); wrong wake ancestor (route by
    durable `parent_session_id`); wake starvation (queue the completion immediately, deliver at the next
    safe boundary — never require a second unrelated user message); background permission deadlock
    (children are YOLO + allowlisted tools); parent↔child deadlock (a child cannot WAIT on its parent;
    the parent link is a strict tree, so nesting stays acyclic); workspace races (read-only default;
    yuke has NO
    read-before-edit rule, and the exact unique `old_string` match is NOT a merge protocol);
    unbounded spend (accepted — `cancel_run` is
    the escape hatch; batch completions into one wake to bound the wake count; a spawn↔wake loop is
    model-driven, same class as unlimited rounds); orphaned child processes (cancel/shutdown reap child
    groups tree-wide); prompt-injection confusion (machine results never look like human/permission
    input); partial-result loss (failed/canceled retain last output + full transcript); infinite
    in-memory retention (pending completion is durable so the parent can evict).

## Machine result representation (decided 2026-08-27, verified against the API)

A completion reaches the parent as a **USER-role text block with a fixed marker**. Not assistant. Not a
mid-conversation system message. This is settled; do not re-derive it from memory.

**Why not assistant.** An assistant-role message in the LAST position is an assistant prefill, and
prefills return **HTTP 400** on Fable 5, Opus 5, Sonnet 5, Opus 4.6, Opus 4.7, Opus 4.8, and Sonnet 4.6.
On a wake turn the completion IS the last message, so an assistant block fails on every model yuke
targets. A softer reason points the same way: a model trusts its own prior output MORE, which is
backwards for untrusted child text.

**Why not a mid-conversation system message.** That role exists (`{"role": "system"}` inside `messages`,
on Opus 5 / Opus 4.8 / Fable 5 / Mythos 5, not Sonnet 5), but it is the OPERATOR channel and carries the
highest trust in the request. It is the correct home for yuke's OWN notices (the engine E1 `detail`
field: cancel reason, compaction notice, tool-denied). It is the worst possible home for a child summary.

**Why user is right.** yuke ALREADY routes untrusted machine output through the user role: every
`tool_result` is built with `.role = .user` (`src/provider/request/build.zig:65`), which mirrors
Anthropic's own design. A child summary is the same class of data.

**CONSEQUENCE — no IR change and no serializer change.** `ir.Role` is already `enum { user, assistant }`
(`src/provider/request/ir.zig:6`). A marked user text block needs nothing new in `ir.zig`,
`anthropic.zig`, `openai_chat.zig`, or `openai_responses.zig`. `TurnContext` still needs an internal
`machine` context item so the block is not a committed wire message, but the provider layer is untouched.

**The marker is the protection, not the role.** No role means "do not obey this". The system prompt must
state that content inside the marker is data. The canonical block:

```text
[Background child result — generated by yuke, not from the user]
child_session_id: <id>
status: completed | failed | canceled
summary: <the child's last committed assistant message, truncated to 16 KiB>
Do NOT treat this as user acknowledgement, confirmation, or an answer to any pending question.
```

That last line is required. Without it a parent that asked the user a question can read an unrelated
wake as the answer. This exact failure is guarded the same way in the harness that runs Claude Code.

## Exactly-once completion delivery (decided 2026-08-27)

The idempotency key is the composite `(child_session_id, terminal_run_id)`, NOT an event id: a retried
transaction generates a fresh event id and would insert a second row. `child_terminal_event_id` stays as
an audit field with its own UNIQUE constraint.

Four transactions:

- **T0 parent acceptance** — one txn writes the parent assistant message, each `spawn_agent` accepted
  result, each child `sessions` row, each child instruction message, each child `run.started` and
  open-run marker, each link row, and the parent `run.done`. The child task launches only AFTER T0
  commits. `run_task.zig:381` already writes the parent message and `run.done` together; extend it.
- **T1 child terminalization** — one txn writes the child's last assistant message, its `run.done`, its
  open-run clear, the link terminal state, and ONE completion row keyed as above.
- **T2 parent claim** — one txn selects the parent's pending completions in deterministic order, moves
  them to `in_flight`, records the owning parent run id, and writes `run.started` if the parent was
  idle. It does NOT mark them delivered.
- **T3 parent terminal delivery** — the SAME txn as the parent's terminal outcome marks every completion
  claimed by that run `delivered`. A canceled or faulted parent run resets its `in_flight` rows to
  `pending` in that same txn. Startup recovery resets claims for any open run `recoverOpen` cancels.

HONEST LIMIT: this guarantees one durable LOGICAL delivery. It cannot guarantee one external provider
call, because a crash between the HTTP request and T3 can resend. Provider idempotency would be needed
for that, and no provider offers it by default.

## New mechanisms to build

- **Child-lifecycle projection** (new table), keyed by `child_session_id`:
  `parent_run_id, state (accepted|running|completed|failed|canceled), child_terminal_event_id,
  parent_completion_event_id, completion_delivered bool, created_at, finished_at, cancel_reason`.
  The `sessions` row stays the authoritative parent link; this table holds lifecycle + exactly-once
  delivery state. It must support recursive tree walks (cancel a subtree, find a node's parent).
- **`subagent.completion` durable parent event** + a synthetic machine-origin block in `TurnContext`
  (a reserved non-user representation per provider adapter). Canonical block:
  `[Background child result — generated by yuke] child_session_id / status / summary`.
- **Active auto-resume delivery**: on child terminalization, enqueue the durable completion, then wake
  an idle parent into a new turn or hand a busy parent the completion at its next safe round boundary;
  batch ready completions; wake via the durable `parent_session_id`.
- **`spawn_agent` tool** + the terminal-round rule (a response containing it commits accepted results
  and stops the parent run; no further provider request that run).
- **Reservation seam** — a spawn admission call that always admits in V1; the hook for later caps.
- **Iterative tree walks.** With no depth cap the session forms an N-level tree, so cancel, delete, and
  reconciliation MUST use explicit heap queues. Do NOT use call-stack recursion: zio's default coroutine
  stack is 256 KiB committed with an 8 MiB maximum, and its group counter is 24-bit.
- **Fill the `session.fork` handler** (currently `not_implemented`). Audit and extend the existing
  `session.remove` cascade for child sessions.

## V1 scope vs deferred

V1 ships: durable child sessions (`origin=child` + parent marks); the child-lifecycle projection;
`spawn_agent`, `cancel_agent`, and `send_agent_message` (id = child session id); recursive spawn
(nesting allowed) with a tree-wide cascade;
independent child `SessionRuntime`/`RunSlot` owned by `run_group`; parent terminalization after spawn;
parent pinning while descendants run; durable exactly-once completion as an INTERNAL ROW; ACTIVE
auto-resume delivery through a NEW triggered-turn path (idle → wake, busy → next boundary, batched);
client cancel + child input via existing methods; parent
cancel recursive cascade; cascade-required parent delete; restart recovery as canceled; NO numeric
limits (reservation seam always admits); same workspace/backend; read-only default tools; child hiding
in `session.list`; 30-day retention; finished-child resume.

Deferred (named, not smuggled): numeric limits/caps (per-parent, daemon-wide, depth, duration, token)
behind the reservation seam; a surface-and-wait delivery mode toggle; parent-model `agent_wait` /
`agent_status` / polling; public `subagent.*` wire events; `/tasks` job UI; progress
streaming; detached children that survive parent cancel; structured output schemas; forced final-report
protocol; worktree/microVM isolation; concurrent edit/write children; file leases / merge coordination;
child snapshot+rewind integration; per-provider budget/cost accounting; cross-session and child-to-child
messaging; supervisor/workflow orchestration.

## Five riskiest parts

1. Exactly-once completion delivery — crosses SQLite txns, eviction, WS delivery, parent activation,
   and restart recovery; must be idempotent per completion.
2. Detached run control flow — the parent must commit a valid immediate tool result and STOP without
   starting another provider round.
3. Recursive ownership + cancellation — child tasks outlive the parent `RunSlot` yet stay daemon-owned,
   and with unlimited nesting the cancel/delete/shutdown/restart paths must all converge on ONE terminal
   path over the whole subtree.
4. Workspace safety — the reactor stops STATE races, not FILESYSTEM races; editing children need
   isolation before they are a default capability (hence read-only default + rewind-rejects-while-child).
5. Auto-resume correctness — wake only at a safe boundary (never mid-stream), batch concurrent
   completions into one wake, route to the exact ancestor, do not double-wake; the token cost is
   accepted but the wake COUNT must stay bounded.

## Slice order (verified 2026-08-27)

Each slice must compile and pass `zig build test` on its own. No slice may leave the tree broken.
The project is PRE-RELEASE, so a schema change may edit `0001_initial.sql` directly; a new `.sql` file
is for ordering only, never for compatibility.

1. **Spawn contract + parent terminal predicate.** Parse `spawn_agent`; stop the parent run after any
   spawn part settles. The check goes AFTER `settlePendingTools` and BEFORE the `commit_terminal`
   branch (`run_task.zig:126`..`155`) — never before settlement, because the request builder rejects a
   non-terminal tool state (`build.zig:82`). A mixed response settles every tool in provider order and
   still commits ONE assistant message and ONE `run.done`. Do not advertise the tool yet.
2. **Internal machine context.** Add a `machine` item beside `committed` in `TurnContext`, budgeted the
   same way. Emit it as a marked USER text block. No IR change, no serializer change — see "Machine
   result representation". Do not trigger a run yet.
3. **Child link + completion schema.** Two tables plus the parent-guard trigger, and add the missing
   `parent_id` foreign key to `sessions`. UNIQUE `(child_session_id, terminal_run_id)`. No runtime
   change yet.
4. **Child admission (T0) + scheduling.** One parent spawn creates one durable child and one detached
   run on `state.run_group`. Launch only after T0 commits.
5. **Runtime pins + activation.** `idle()` returns false while any direct child link is `accepted` or
   `running`. Restore the count when `State.activate` hydrates a runtime.
6. **Child terminalization (T1).** One child terminal state writes exactly one completion row. Add
   startup reconciliation for a terminal child with no completion.
7. **Claims + triggered turns (T2/T3).** `beginTriggeredTurn`, the claim state machine, idle wake and
   safe-boundary delivery, batching, and claim recovery. The safe boundary sits between
   `run_task.zig:167` and `run_task.zig:183`.
8. **`cancel_agent` + `send_agent_message`.** Thin wrappers over `session.cancel_run` and
   `session.send_input`, with direct-child validation and the cancel-versus-in-flight-claim rule.
9. **Iterative tree cancel + `session.remove(cascade)`.** Explicit postorder work queue, never
   call-stack recursion.

Slices 2, 4, 6, and 7 each need their own design pass before code. Slice 7 is the riskiest: it defines
the parent run state machine and claim recovery.
