# yuke — allocation policy

Status: current policy.
Source of truth: allocator ownership in `src/` and `lib/`.
Last verified: 2026-09-07.

The process uses scoped dynamic allocation. Each owner releases its data at the end of its lifetime.
Input boundaries apply byte or item caps. A fixed pool requires evidence from a measured hot path.

## Owners

- The process owns providers, the store, and the QuickJS host.
- A request arena owns decoded input and temporary results.
- A session owns its resident transcript and projection. Each committed message owns a separate arena.
- A draft owns its mutable response. A prepared run owns its copied configuration and reserved storage until admission binds it to a session.
- A tool call owns its request bytes until the call ends. An output queue owns each copied payload until delivery or disposal.
- The JavaScript owner task alone accesses QuickJS values. Other tasks publish native data and wake that owner.

## Current bounds

| Scope | Bound | Source |
|---|---|---|
| Resident transcript | 1,000 messages and 8 MiB of serialized content | `src/session/transcript.zig` |
| Model context | Model-window estimate, output reserve, and a retained history floor | `src/engine/context.zig` |
| QuickJS | 64 MiB heap and 4 MiB stack | `src/js/host.zig` |
| QuickJS jobs | 1,024 jobs per owner drain plus an execution interrupt budget | `src/js/host.zig` |
| Protocol fields | Field-specific string, collection, and integer bounds | `lib/proto/meta.zig` and their decode/use sites |
| JSONL input | A fixed line buffer derived from the protocol string limit | `src/app/rpc.zig` |

The transcript byte bound is soft. It retains the newest message even if that message exceeds the bound.
Serialized bytes measure retained content; they do not equal allocator capacity or process footprint.
The model context uses a token estimate. It holds the history floor until a trim is necessary and rejects an oversized live turn.

## Rules for new code

- Choose the narrowest lifetime that contains every reader.
- Name the owner and release path for each heap allocation.
- Validate external input before it becomes internal state. Use errors at that boundary and assertions for internal invariants.
- Apply each cap at the actual decode or use site. A constant alone does not enforce a bound.
- Add a pool, aggregate memory cap, or concurrent-session cap only when the workload and policy require it.

The old WebSocket and daemon allocation notes do not describe this process.
The transcript byte bound and model-context budget are implemented; neither is a deferred compaction task.
