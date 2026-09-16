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

The next fixture audit includes `App.initTest` and `execution.testContext`.
The release benchmark also calls `App.initTest`; its name alone does not prove dead code.

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
2. Stable transcript rows and the full-prefix bridge check: pending.
3. Exact panel and native-setter duplicates: consolidated.
4. One child-page policy: implemented with explicit failure on incomplete results.
5. Advice dispatch: measurement and simplification pending.
6. Commit serialization and large agent-tree refreshes: dedicated benchmarks pending.

## Performance next

- Retain stable transcript rows across text updates.
- Replace the full-prefix JS/native check with a revision and byte cursor.
- Measure and simplify advice dispatch without a plugin behavior change.
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
