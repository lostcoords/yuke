# yuke — allocation policy

Status: current policy.
Source of truth: allocator ownership in `src/`, `lib/domain/`, and `lib/wire/`.
Last verified: 2026-08-31.

The daemon commits to **scoped dynamic allocation with admission caps at boundaries** (the Ghostty model).
It does NOT target TigerBeetle-style static-capacity allocation. Grounded in the 2026-08-24 allocation survey.

## The decision

- **Model: scoped dynamic + caps.** Group allocations by lifetime with an arena per scope. Keep ownership
  explicit. Put a hard admission cap at each boundary that accepts external work. Accept runtime allocation;
  bound it by scope and by cap.
- **Reject static-capacity for the daemon.** A daemon serves dynamic sessions with variable LLM responses
  over user-controlled transcripts. Fixed connection counts, fixed message sizes, and AssumeCapacity
  everywhere do not fit that shape. Static allocation stays a tool for a specific hot leaf, not the policy.
- **Why this fits.** The store, the reducers, and the domain reducers already group allocations by lifetime.
  The gap is not messiness. The gap is that the caps are ad hoc. This policy names the model and makes the
  caps real.

## What is already coherent (keep it)

- The arena/gpa split tracks object lifetime. A request arena frees the whole request. A queue item and a
  Draft each own an arena for write-once data. `State.gpa` holds daemon-lifetime state.
- Ownership is explicit: the reducers copy peer bytes with `own()`/`release()`; the outbox states
  "bytes is gpa-owned; the writer frees it"; `Owned` rows free every dynamic field; `create`/`destroy`
  pair per SessionRuntime.
- Real byte caps exist: 64 KiB heads, 1 MiB WS messages, 16 MiB provider bodies, 1 MiB SSE lines,
  1024 blocks, 1 MiB tool arguments, 1 MiB message strings, a 256-item outbox.

## The gaps and where each fix lands (no separate refactor)

| Gap | Fix | Slice |
|---|---|---|
| The turn transcript has a 1000-row limit but no byte/token budget | A real context-window rule | **compaction slice** |
| `meta.zig` declares `max_frame_bytes`, `max_message_parts` with no enforcement | Add each bound at the real caller | the named "wire bounds at point of use" deferred item |

## Deferred by decision

- **No concurrent-session cap yet.** Build a working end-to-end version first, then add a `max_sessions`
  policy if measurements show a burst of active sessions is a real risk. Idle eviction (E1c.4b) is the first
  bound; a hard cap comes later, if at all.
- **No object pools yet.** Bounded pools for framed bytes, session runtimes, or queue items are premature.
  Add a pool only for a hot object that measurements prove, never speculatively.
- **No aggregate turn budget yet.** The compaction slice owns the real context rule.

## The rule for new code

- Pick the narrowest scope that outlives the data, then use that scope's arena.
- Name the owner and the free path for every heap allocation.
- Put a cap at every boundary that accepts external input. Bound by bytes, not only item count.
- Do not add a pool or a static-capacity structure without a measurement that asks for it.
