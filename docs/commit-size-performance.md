# Reuse the stored message size

Baseline: `6926073`. The comparison uses the saved records from the commit baseline on this machine.

## Change

The store now returns one internal `Commit` with the public event data and the stored JSON byte count.
Assistant replies, user input, compaction, and interruption notices carry this result to the session.
The session appends the message with `Transcript.appendSized` and avoids a second JSON pass.
The emitter publishes only `Commit.data`. The protocol types, schema, and stored payload remain unchanged.
Generic event folds without store metadata retain their existing size measurement.
The durable emitter asserts that message commits use the dedicated path.

Both message copies remain. The scratch copy survives draft release during the session fold.
The resident copy survives scratch teardown. The store result borrows the same message as before.
The change adds no allocator call sites and no cache. Each internal commit record gains one `usize`.
Queued commit arrays therefore request additional space for one size per record.
The assistant benchmark does not measure the backing allocation effect of those larger arrays.
No allocation reduction is claimed for this change.

The diff adds 8 net production lines and 16 net test lines. Benchmark source line count is unchanged.
The existing store test now checks stored byte counts, Unicode escaping, and transcript eviction at a byte limit.

## Method

The [baseline report](commit-serialization-baseline.md) defines the fixture and allocation coverage.
Each case has five repeats of 100 samples at scales 1, 16, and 256.
The source text has 3,584, 57,344, and 917,504 bytes respectively.
Setup and one warmup operation precede each counter snapshot.
Scratch arenas and resident clones remain fresh per operation; the source draft is reused.
The benchmark now passes the returned store size to the same resident transcript operation.
No fixture, sample count, store write, or verification step changes.

SQLite runs in memory. Timings include SQL work, but exclude disk durability.
The counters exclude SQLite allocations and the benchmark output buffer.
The benchmark calls commit components, not the full turn function or event publication path.
It does not establish a whole-application or plugin latency improvement.

For each phase `commit`, `commit_serialize`, and `commit_size`, and each scale 1, 16, and 256:

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase commit --scale 1
zig build bench -Doptimize=ReleaseFast -- --phase commit --scale 1
```

Before records: `/tmp/yuke-<phase>-<scale>-<metrics|latency>.jsonl`.
After records: `/tmp/yuke-size-<phase>-<scale>-<metrics|latency>.jsonl`.

## Results

Times below are microseconds per operation, as the median of five repeat medians.

| Phase | Scale | Before | After, first run | Change |
| --- | ---: | ---: | ---: | ---: |
| commit | 1 | 37.000 | 41.125 | +11.1% |
| commit_serialize | 1 | 6.125 | 6.125 | +0.0% |
| commit_size | 1 | 6.000 | 6.000 | +0.0% |
| commit | 16 | 264.833 | 166.750 | -37.0% |
| commit_serialize | 16 | 102.542 | 100.000 | -2.5% |
| commit_size | 16 | 89.917 | 89.875 | -0.0% |
| commit | 256 | 3,790.833 | 2,261.667 | -40.3% |
| commit_serialize | 256 | 1,564.625 | 1,536.083 | -1.8% |
| commit_size | 256 | 1,456.583 | 1,434.792 | -1.5% |

The initial small commit result was slower and had a strong repeat-to-repeat decline.
Its repeat medians were 59.208, 45.917, 41.125, 37.292, and 37.042 microseconds.
Three isolated after reruns gave 28.084, 28.000, and 28.042 microseconds.
The initial small-case regression does not reproduce in these runs.
No precise small-case speedup is claimed against the earlier baseline.
The extra records are `/tmp/yuke-size-small-repeat-<1|2|3>.jsonl`.

The 56 KiB and 896 KiB commit cases improve by 37.0% and 40.3% respectively.
The serialize and size controls remain close to their earlier values.
These results support a CPU benefit from removal of the duplicate size pass.

All allocation fields, live/peak bytes, checksums, source/output bytes, and UI counters match
before and after for every repeat of all nine cases. All 90 after result records pass verification.
All 15 small-case rerun records also pass verification.
The following commit totals cover 100 measured operations; both runs have these values.

| Text size | Allocations / frees | Allocated / freed bytes | Resize attempts | Live bytes | Peak bytes |
| --- | --- | --- | ---: | ---: | ---: |
| 3,584 | 600 / 600 | 2,656,800 / 2,656,800 | 500 | 2,045,160 | 2,071,728 |
| 57,344 | 600 / 600 | 35,986,000 / 35,986,000 | 500 | 2,206,440 | 2,566,300 |
| 917,504 | 600 / 600 | 577,620,400 / 577,620,400 | 500 | 4,786,920 | 10,563,124 |

Remap attempts and allocation failures remain zero. All UI counters and terminal output bytes remain zero.
The serialization and size control counters also match every field in the baseline report.
The large commit still allocates and frees about 5.78 MB per operation through the tracked allocator.
Buffer allocation cost is a separate next step; this change removes no message copy.

## Validation

`zig build test --seed 0 --summary new` passes all 42 steps and 783 source tests.
The schema checks pass with no protocol or generated-file changes.
`mise run check-ts`, `zig build`, and `zig fmt --check` on all changed Zig files pass.
