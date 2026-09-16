# Commit serialization baseline

Production baseline: `c75c77f`. This batch changes only the benchmark and reports.

## Scope

The assistant commit path in `src/engine/turn.zig` obtains a wire view of the draft,
clones the message into scratch memory, and calls `store.message.appendCommittedMessage`.
The store serializes the message into JSON and writes the event and projection in one transaction.
The resident session then calls `Transcript.append`, which serializes again to count bytes,
clones the message into a resident arena, and applies the transcript bounds.

The benchmark calls these production components directly. It does not execute the full turn function.
It excludes draft assembly and release, terminal reports, queued input, event sinks, JS, and rendering.
It uses SQLite in memory. Latency includes SQL work, but excludes disk writes and sync latency.
SQLite allocations use its own allocator and are outside the allocation counters.
The SQL binding uses SQLITE_TRANSIENT, so SQLite copies the payload too.
The bundled SQLite header confirms this lifetime rule; that copy is not counted here.

## Method

- macOS arm64, Zig 0.16.0, ReleaseFast.
- Three phases: `commit`, `commit_serialize`, and `commit_size`.
- Each phase has five repeats of 100 samples, at scales 1, 16, and 256.
- One sample performs one operation. Latency uses a separate run without metrics.
- Setup creates the database, session, and source draft outside the samples.
- One complete operation warms each repeat before the counter snapshot and peak reset.
- Each sample creates and frees a fresh scratch arena; no scratch capacity survives a sample.
- The source draft is reused. Message ids change but retain six digits, so JSON size stays fixed.
- Text includes Unicode, quotes, a backslash, and a newline in each repeated unit.
- The commit case retains one transcript message and evicts its predecessor on each sample.
- The database retains all commits in the repeat. Each repeat starts with a new database.
- The serialization and size phases include the draft wire-view allocation in their scratch arena.
- Verification follows the counter and latency snapshots. It checks byte sizes and commit sequences.
- The commit check reads the latest stored message and compares its id and text with the resident copy.

The commit phase includes the scratch clone, transaction, JSON payload, SQL writes,
second serialization for size, resident clone, eviction, and scratch release.
The serialize phase calls the same JSON allocator routine as the store.
The size phase calls `transcript.messageBytes` with its discard writer.
These component measurements are separate runs, so their times are not an exact additive breakdown.
The workload has one text part. It does not represent large tool-result trees or many small parts.

The counters cover allocations through the harness allocator, including scratch and resident arenas.
They exclude SQLite, runtime setup outside that allocator, and the benchmark output buffer.
Live and peak bytes include the idle JS host and renderer from the shared harness; they are not RSS.
Arena suballocations are not separate backing allocation calls.

## Reproduction

Run each phase at scales 1, 16, and 256:

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase commit --scale 1
zig build bench -Doptimize=ReleaseFast -- --phase commit --scale 1
```

Raw records: `/tmp/yuke-<commit|commit_serialize|commit_size>-<1|16|256>-<metrics|latency>.jsonl`.

## Source checks

`std.json.Stringify.valueAlloc` uses a dynamic `std.Io.Writer.Allocating` buffer.
The writer attempts a remap on growth; on failure it allocates and copies the existing bytes.
The arena can expand its last allocation only if the current node has enough space.
An old buffer can remain in the arena until teardown after a replacement allocation.
These source rules explain a possible source of temporary bytes; this benchmark does not count each copy.

## Results

Latency values are the median of five repeat medians and the median of five repeat p95 values.
All times are microseconds per operation. All byte values are exact bytes.

| Phase | Scale | Source bytes | JSON bytes | Median µs | p95 µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| commit | 1 | 3,584 | 4,258 | 37.000 | 43.875 |
| commit_serialize | 1 | 3,584 | 4,258 | 6.125 | 6.167 |
| commit_size | 1 | 3,584 | 4,258 | 6.000 | 6.084 |
| commit | 16 | 57,344 | 65,698 | 264.833 | 284.583 |
| commit_serialize | 16 | 57,344 | 65,698 | 102.542 | 115.292 |
| commit_size | 16 | 57,344 | 65,698 | 89.917 | 102.875 |
| commit | 256 | 917,504 | 1,048,738 | 3,790.833 | 3,997.084 |
| commit_serialize | 256 | 917,504 | 1,048,738 | 1,564.625 | 1,674.500 |
| commit_size | 256 | 917,504 | 1,048,738 | 1,456.583 | 1,535.708 |

Each allocation row covers 100 measured operations. All five repeats have identical counters and live/peak bytes.

| Phase | Scale | Allocations / frees | Allocated / freed bytes | Resize attempts | Live bytes | Peak bytes |
| --- | ---: | --- | --- | ---: | ---: | ---: |
| commit | 1 | 600 / 600 | 2,656,800 / 2,656,800 | 500 | 2,045,160 | 2,071,728 |
| commit_serialize | 1 | 400 / 400 | 2,011,400 / 2,011,400 | 400 | 2,038,250 | 2,058,364 |
| commit_size | 1 | 100 / 100 | 28,800 / 28,800 | 0 | 2,038,250 | 2,038,538 |
| commit | 16 | 600 / 600 | 35,986,000 / 35,986,000 | 500 | 2,206,440 | 2,566,300 |
| commit_serialize | 16 | 600 / 600 | 21,680,200 / 21,680,200 | 600 | 2,118,890 | 2,335,692 |
| commit_size | 16 | 100 / 100 | 28,800 / 28,800 | 0 | 2,118,890 | 2,119,178 |
| commit | 256 | 600 / 600 | 577,620,400 / 577,620,400 | 500 | 4,786,920 | 10,563,124 |
| commit_serialize | 256 | 800 / 800 | 244,820,600 / 244,820,600 | 800 | 3,409,130 | 5,857,336 |
| commit_size | 256 | 100 / 100 | 28,800 / 28,800 | 0 | 3,409,130 | 3,409,418 |

Remap attempts and allocation failures are zero in every case. All UI counters and output bytes are zero.
The size case allocates 288 scratch bytes per operation for the draft wire view.
The discard serialization itself adds no tracked allocation calls.
All 90 result records pass verification. Metrics and latency checksums agree in every case.
The checksum is the verified JSON byte count, not a content hash.

## Discussion

The second serialization has a measurable CPU cost that grows with text size.
The store already knows the JSON byte count, and `Transcript.appendSized` already accepts it.
The first candidate is to carry that known count through the internal commit path.
This requires deliberate internal event plumbing; it must not alter the public wire payload by accident.
The separate size timing is an estimate of avoidable work, not a measured speedup for a proposed change.

The next candidate is the temporary JSON buffer and its arena growth.
Large messages allocate several times their payload size through the tracked allocator.
A focused buffer ownership experiment needs its own before/after comparison.
The scratch clone also protects the event payload after draft release; it cannot simply be deleted.
Resident ownership remains necessary after scratch teardown.
No production optimization is part of this batch.

## Validation

`zig build test --seed 0 --summary new` passes all 42 steps and 783 source tests.
The existing benchmark test exercises all three new phases at scale 9.
`zig fmt --check src/js/bench.zig src/js/bench_commit.zig`, `mise run check-ts`, and `zig build` pass.
