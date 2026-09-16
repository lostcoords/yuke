# Reduction and performance plan

The JS API supports user plugins. Preserve advice targets and public object identity.
The project is pre-release. Remove obsolete contracts instead of compatibility shims.
Protocol changes require coordinated Zig types, generated outputs, and consumer updates.

## Reduction first

- [x] Fix context-flag ownership for arbitrary plugin unload order.
- [x] Remove the test-only host job budget and move host fixture setup into test support.
- [ ] Complete the optional-value and fallback audit against production lifetimes.
- [x] Consolidate duplicate panels and native property setters.
- [x] Define one complete child-page traversal policy.
- [ ] Complete the helper and fixture audit.

The child traversal requests 100 items per page and allows at most 32 pages.
It rejects a cursor cycle or an incomplete result at the page bound.
The cache window reports a read failure instead of a partial total.
The shared traversal calls the public client object, so plugin advice remains active.

Keep types, fixtures, tests, and documentation aligned with each change.

The first audit retains valid optional state:

- `Session.has_skills` is unknown before the first database query.
- The renderer can be absent in the RPC frontend.
- The JS engine runtime can be absent before attachment or after detachment.
- A cache child list can be absent after a failed read.

### App fixture audit

`app/fixture.zig` now owns the private database setup for tests and the release benchmark.
`App` no longer exposes `initTest` or `installTestModel`.
The fixture copies the blob path before it opens the database.
This removes the database ownership gap if the path allocation fails.
The fixture initializes its HTTP client and scheduler instead of leaving them undefined.
`App.deinit` now owns the same task, engine, store, and HTTP shutdown order for all callers.
The local host test environment is private and immutable.

The audit retains `execution.testContext`: several test modules use its shell policy.
It also retains `Database.openTest`: both tests and the projection benchmark need a private database.
Neither helper represents unused production state.

This batch adds 15 net source lines and no tests; its benefit is resource ownership and API scope.
The full test command passes all 42 steps, with 781 source tests run.
The application build and format checks pass.
The projection benchmark uses ReleaseFast, scale 1, and five repeats of 100 iterations.
Before and after, all allocation, free, byte, remap, live/peak, and UI counters match for every repeat.
The result checksums also match.
The median repeat has 3,800 allocations, 3,798 frees, 88,127,800 allocated bytes,
88,021,224 freed bytes, 4,500 remaps, 2,502,763 live bytes, and 2,908,679 peak bytes.
Resize attempts and allocation failures are zero.
Separate latency medians are 532.0 microseconds before and 525.5 after; no speed gain is claimed.
The repeated-work counters exclude fixture setup; live and peak values include the harness state.
Raw files are `/tmp/yuke-fixture-{before,after}-{metrics,latency}.jsonl` on this machine.
Commands are `zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase projection`
and `zig build bench -Doptimize=ReleaseFast -- --phase projection`.

### RPC audit

The RPC frontend now requires its production JS host.
The hostless state existed only in tests.
The transport uses the host interaction table directly.
The type-erased interaction adapter and its optional field are removed.
The transport also uses the host wake event and I/O instead of duplicate fields.
Existing transport tests now use real hosts; response error codes remain the same.
The source diff removes 44 net lines and adds no tests.
The change adds no production allocator calls and preserves the host lifetime.
The benchmark harness does not cover JSONL dispatch, so this change has no measured speed claim.

## Original review checklist

1. Context-flag ownership: implemented with one entry per registration.
2. Stable transcript rows and the full-prefix bridge check: implemented and measured.
3. Exact panel and native-setter duplicates: consolidated.
4. One child-page policy: implemented with explicit failure on incomplete results.
5. Advice dispatch: baseline measured; simplification awaits discussion.
6. Commit serialization and large agent-tree refreshes: dedicated benchmarks pending.

## Transcript and boot performance

The transcript retains closed-prefix rows in each text part cache.
A draft generation and byte offset replace the full-prefix native check.
A bounded cache reuses up to eight exact-size QuickJS backing blocks.
This also removes the measured boot allocation regression.
The public JS API and wire schema remain intact.
The [evidence report](transcript-performance-evidence.md) records the tradeoffs, tests, and all benchmark phases.

## Performance next

- Review the [advice baseline](advice-dispatch-baseline.md) before a dispatch change.
- Reuse known message sizes at commit and audit clone lifetimes.
- Measure large agent trees and avoid full-tree reads for activity-only changes.
- Audit paint-only invalidation and selection allocation costs.

## Evidence

The [first batch report](reduction-batch-evidence.md) records tests and benchmark costs.
The first batch has no performance-gain claim.

Use the same scenario before and after each performance change.
Run metrics and latency separately. Report allocation and free counts, byte totals,
resize and remap attempts, live and peak bytes, and UI work counters.
The existing harness does not isolate advice, durable commits, or agent-tree reads.
Add targeted scenarios before a performance claim for those paths.

Run `zig fmt` for Zig edits and run the relevant tests for each batch.
Run the full suite before each handoff. Preserve wire rejection tests.
