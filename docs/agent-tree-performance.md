# Targeted agent activity refresh

Production baseline: `bc42d5d`. Both runs use the same new benchmark harness.

## Change

The open picker now reads a changed listed session through `client.sessionGet` for an activity-only fact.
It retains row depth and position, updates the row item, and recomputes the summary.
A set coalesces pending session ids. One async worker serializes refresh work.
A full reload takes priority over pending row reads. A close clears pending ids and rejects late results.
Initial opens, summary changes, run completion, removal, and broad invalidation retain full traversal.
The public `agentRows` function and child-page policy remain intact.
Public client advice still intercepts every read.

The native index event now always exposes `overflow: boolean`.
A true value means the dirty-set bound dropped session facts, so the picker must read the full tree.
This is an explicit addition to the internal JS event type; RPC protocol types and generated schema are unchanged.
The overflow bit remains visible when unrelated index facts share the drain.
No second tree cache, native activity shortcut, or new SQL endpoint is added.

The production diff adds 26 net source lines, including the native overflow field.
The type declaration has no net line change. Tests and benchmark code are separate costs.
The row lookup and title calculation still cost O(N); the improvement removes full-tree reads.
Full reloads remain O(N), and an in-flight full traversal can finish after the picker closes.
Its result cannot update the closed picker.

## Benchmark method

- macOS arm64, Zig 0.16.0, ReleaseFast.
- Stored SQLite trees have 10, 100, or 1,000 descendants plus one root.
- Wide trees place every child under the root; balanced trees use at most four children per parent.
- Even-numbered sessions are resident; odd-numbered sessions are not resident.
- The target at these three scales is resident. A separate 999-child wide case targets a nonresident child.
- The real QuickJS picker calls the real client, native request task, engine commands, and SQLite reads.
- Client advice counts `sessionGet` and `sessionList` calls without replacing the reads.
- Each case has five repeats of ten measured operations, after fixture setup and one warmup operation.
- Metrics and latency use separate binaries. Baseline binaries are preserved before the production edit.
- Latency includes async request scheduling, JSON conversion, tree construction, and picker source updates.
- The picker is not painted. Terminal output and UI draw counters are zero.
- SQLite allocations and the benchmark output buffer are outside the allocation counters.
- QuickJS counters measure backing allocations, not each JS object.

The phases are:

- `agents_open`: close the picker, read the full tree, and open a new picker.
- `agents_activity`: inject one activity digest for the listed target.
- `agents_burst`: inject 20 same-target JS events before the first refresh settles.
- `agents_structure`: inject a summary index event that requires a full reload.

The burst is a JS scheduler stress case. The native digest already merges same-session facts per frame.
The structure case measures a full reload of a stable tree; it does not time a database insert or removal.
The activity fixture stays unchanged during measurement; separate tests check visible state transitions.
The benchmark checks row count, root identity, and completion of source updates.
Existing tree tests check ancestry and depth. New tests check concurrent refresh behavior.

## Reproduction

For each phase, shape, and scale:

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase agents_activity --tree-shape wide --scale 1000 --iterations 10
zig build bench -Doptimize=ReleaseFast -- --phase agents_activity --tree-shape wide --scale 1000 --iterations 10
```

The baseline run uses copies of the two executables produced by these commands before the production edit.
Baseline files: `/tmp/yuke-tree-before-<phase>-<shape>-<scale>-<metrics|latency>.jsonl`.
After files: `/tmp/yuke-tree-after-<phase>-<shape>-<scale>-<metrics|latency>.jsonl`.
Boot uses the same two builds with `--phase boot` and 100 iterations.

## Results

Latency values are medians of five repeat medians from the non-metrics run.
Allocated bytes per update use the median of five allocation totals divided by ten operations.

| Descendants | Shape / target | Activity before ms | Activity after ms | Allocated bytes before / update | Allocated bytes after / update |
| ---: | --- | ---: | ---: | ---: | ---: |
| 10 | wide / resident | 0.721000 | 0.020459 | 65,051.0 | 3,714.0 |
| 100 | wide / resident | 6.460167 | 0.038959 | 956,829.4 | 13,740.8 |
| 1,000 | wide / resident | 64.885083 | 0.215333 | 9,984,433.2 | 88,539.6 |
| 10 | balanced / resident | 0.728291 | 0.021000 | 92,851.2 | 3,714.0 |
| 100 | balanced / resident | 6.622208 | 0.050333 | 977,181.8 | 13,740.8 |
| 1,000 | balanced / resident | 64.912208 | 0.246291 | 9,841,893.4 | 88,539.6 |
| 999 | wide / nonresident | 65.094167 | 0.215083 | 10,005,839.4 | 88,538.6 |

One activity event now requires one get and zero list calls at every measured size.
At 1,000 wide children, the baseline requires one get and 1,010 list calls.
The 20-event burst changes from two full traversals to two gets and zero list calls.
This does not mean 20 distinct dirty sessions need only two reads; the burst repeats one target.

| Shape, 1,000 descendants | Burst before ms | Burst after ms | Open before ms | Open after ms | Full reload before ms | Full reload after ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| wide | 130.750500 | 0.459667 | 65.814917 | 65.437083 | 64.639042 | 64.924666 |
| balanced | 130.645833 | 0.670209 | 65.422250 | 65.481750 | 64.919250 | 65.090291 |

No speed gain is claimed for initial opens or full reloads. Their large-case times remain close to baseline.
The [counter table](agent-tree-benchmark.csv) records all 52 case/side summaries.
It includes allocation/free counts, allocated/freed bytes, resize/remap attempts, failures,
live/peak bytes, request counts, median latency, and p95 latency.
Counter columns use repeat 2, not an artificial combination of per-field medians.
Counters can vary across repeats because the host reuses QuickJS arenas and cached backing blocks.
Live/peak bytes include fixture state and the existing picker; they are not process RSS.

All 520 metrics and latency records pass verification. Before/after checksums match in every case.
Request counts match the expected full or targeted path in every repeat.
Terminal output and UI draw counters remain zero in all measured cases.

## Boot cost

The boot control uses 100 boots per repeat.
Allocation and free counts remain 82,900 each, with zero resize attempts, 1,800 remap attempts,
and zero allocation failures. Allocated and freed bytes change from 133,346,000 to 133,019,600.
This is 3,264 fewer tracked bytes per boot; no new allocation reduction mechanism is claimed.
At repeat 2, live bytes remain 2,176,750 and peak bytes change from 3,451,912 to 3,448,624.
Separate latency changes from 2.390916 to 2.445917 ms per boot, about 0.055 ms or 2.3% higher.
The earlier boot allocation fix remains effective. The latency cost is reported, not hidden by the activity gain.

## Validation

The full suite passes all 42 steps and 785 source tests with `zig build test --seed 0 --summary new`.
The new JS test covers advice calls, fresh row values, selection, depth, burst coalescence,
removal during a read, activity during a full reload, mixed overflow, and close during a pending read.
The native integration test fills the dirty map with 256 unrelated sessions, drops the displayed child's
activity event, adds an unrelated index notice, and verifies that the picker still updates its active count.
Existing tests retain ancestor traversal, cycle rejection, pagination, and agent actions.
`mise run check-ts`, `zig build`, format checks, and schema checks pass.
