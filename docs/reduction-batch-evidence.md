# First reduction batch evidence

The baseline is commit `7b42c2150f819907d21fab345da47c642cd4061e`.
The comparison uses the uncommitted first reduction batch on 2026-09-16.
Both runs use Zig 0.16.0, ReleaseFast, the synthetic fixture, scale 1,
and five repeats of 100 iterations at 100 columns by 40 rows.

Commands:

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true
zig build bench -Doptimize=ReleaseFast
zig build test --seed 0 --summary all
zig build
tsc -p src/js/app/tsconfig.json
```

The full test command passed all 42 steps.
The final cleanup ran 781 source tests and reused the unchanged library test results.
The application build, JS type check, Zig format check, and diff check passed.

## Allocation evidence

Each cell shows the baseline and final median across five repeats.
Counts and byte totals cover 100 iterations.
Live and peak bytes describe the harness lifetime at each sample boundary.
All resize attempts and allocation failures are zero.
Every UI work counter and result checksum matches for every repeat.

| Phase | Allocations | Frees | Allocated bytes | Freed bytes | Remap attempts | Live bytes | Peak bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| build | 9,946 → 10,145 | 9,901 → 10,142 | 36,060,512 → 36,872,040 | 35,895,608 → 36,859,808 | 700 → 700 | 2,424,708 → 2,248,389 | 2,638,332 → 2,579,037 |
| reflow | 1,304 → 1,304 | 1,309 → 1,308 | 1,395,616 → 1,395,616 | 1,415,912 → 1,411,864 | 400 → 400 | 2,195,456 → 2,195,637 | 2,214,974 → 2,219,203 |
| scroll | 100 → 100 | 100 → 100 | 68,800 → 68,800 | 68,800 → 68,800 | 0 → 0 | 2,207,672 → 2,207,933 | 2,208,360 → 2,208,621 |
| stream | 1,920 → 1,923 | 1,918 → 1,920 | 5,336,930 → 5,349,170 | 5,336,242 → 5,344,402 | 520 → 520 | 3,259,372 → 3,267,425 | 3,308,336 → 3,317,717 |
| stream_native | 20,121 → 20,111 | 20,185 → 20,177 | 166,525,930 → 166,485,130 | 166,661,274 → 166,628,570 | 3,601 → 3,601 | 15,301,480 → 15,309,517 | 16,253,634 → 16,249,647 |
| paint | 200 → 200 | 200 → 200 | 137,600 → 137,600 | 137,600 → 137,600 | 0 → 0 | 2,229,010 → 2,229,031 | 2,229,698 → 2,229,719 |
| colors | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 1,517,902 → 1,517,894 | 1,517,902 → 1,517,894 |
| selection | 8,498 → 8,498 | 8,498 → 8,498 | 33,993,440 → 33,993,440 | 33,993,440 → 33,993,440 | 0 → 0 | 2,212,730 → 2,212,591 | 2,217,498 → 2,217,359 |
| preview | 1,204 → 1,205 | 1,209 → 1,210 | 319,488 → 323,568 | 339,936 → 344,016 | 100 → 100 | 2,146,020 → 2,141,937 | 2,175,664 → 2,175,685 |
| projection | 3,800 → 3,800 | 3,798 → 3,798 | 88,127,800 → 88,127,800 | 88,021,224 → 88,021,224 | 4,500 → 4,500 | 2,498,662 → 2,502,763 | 2,904,578 → 2,908,679 |
| gc | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 2,203,824 → 2,203,845 | 2,203,824 → 2,203,845 |
| boot | 93,700 → 95,400 | 93,700 → 95,400 | 173,047,800 → 184,343,900 | 173,047,800 → 184,343,900 | 1,800 → 1,800 | 2,167,128 → 2,171,229 | 3,445,078 → 3,440,838 |

The preview scenario first rose from 319,488 to 14,191,488 allocated bytes.
An isolated build with the original panels reduced this cost to 323,568 bytes.
The final shared panel lives in a separate internal module.
The final preview result is 323,568 bytes.

Boot allocated bytes rise from 173,047,800 to 184,343,900, or 6.5%.
The final boot counts also rise from 93,700 to 95,400 allocations.
This cost remains explicit; this batch does not claim a performance gain.
The benchmark does not isolate each contribution to this boot cost.

QuickJS releases an arena when its last block is freed.
A module change can therefore alter backing allocation churn outside its own calls.
The pinned QuickJS source confirms this behavior in `js_arena_free`.
The counters cover native allocations and QuickJS backing allocations.
They do not count each JS object, and they exclude the output buffer.
The harness does not isolate advice, durable commits, or child-page RPC latency.

Raw metrics are at `/tmp/yuke-review-metrics.jsonl` and
`/tmp/yuke-reduction-final-metrics.jsonl` on this machine.

## Separate latency evidence

The following values are medians across five repeats, in microseconds.
The runs have no allocation metrics.
They are single before/after runs, so they do not establish a speed gain.

| Phase | Median latency, before → after | p95 latency, before → after |
| --- | ---: | ---: |
| build | 778.2 → 749.0 | 1,004.6 → 1,021.8 |
| reflow | 460.2 → 448.6 | 547.2 → 495.6 |
| scroll | 9.6 → 9.6 | 11.7 → 11.7 |
| stream | 287.4 → 273.6 | 337.8 → 298.8 |
| stream_native | 3,773.0 → 3,489.9 | 4,808.1 → 3,618.5 |
| paint | 174.2 → 177.3 | 194.5 → 211.3 |
| colors | 128.7 → 128.4 | 142.6 → 148.3 |
| selection | 214.8 → 209.8 | 239.2 → 246.7 |
| preview | 396.2 → 391.0 | 465.3 → 458.2 |
| projection | 552.1 → 532.8 | 624.2 → 590.0 |
| gc | 53.9 → 54.9 | 78.8 → 68.9 |
| boot | 2,563.9 → 2,433.6 | 2,793.5 → 2,757.7 |

Raw latency files are `/tmp/yuke-review-latency.jsonl` and
`/tmp/yuke-reduction-final-latency.jsonl` on this machine.

## Boot allocation investigation

This investigation changes no application source.
Each isolated copy starts from the same baseline commit.
Each variant uses the same metrics command with `-- --phase boot`.
The result covers five repeats of 100 fresh boots.
Both the fresh baseline and the final-batch rerun reproduce the prior counts exactly.

| Variant | Allocations per 100 boots | Allocated bytes per 100 boots | Byte change |
| --- | ---: | ---: | ---: |
| Baseline | 93,700 | 173,047,800 | +0.000% |
| Context ownership only | 94,300 | 175,527,400 | +1.433% |
| Panel consolidation only | 93,600 | 172,846,200 | -0.116% |
| Complete child-page consolidation only | 104,000 | 219,396,300 | +26.784% |
| Native setter and host test cleanup only | 93,700 | 173,047,000 | -0.000% |
| Complete batch | 95,400 | 184,343,900 | +6.528% |
| Complete batch with old agent-tools import restored | 99,600 | 197,198,800 | +13.956% |

The variants do not have additive costs.
The complete child-page variant removes the cache traversal too; it retains both original panels.
The panel variant retains the original child-page paths.
The native variant changes no JS source.
A preliminary page variant left the original cache traversal in place; the table excludes that partial variant.

Boot does not invoke the child-page helper or register the optional Vim context flags.
The changes affect the modules and functions that boot loads, rather than page requests.
The old agent-tools import alone does not explain the regression.
Its restoration in the complete batch increases allocation cost further.

A temporary allocation-size histogram reproduces both original totals exactly.
Across 100 boots, blocks at QuickJS arena-compatible sizes add 2,900 allocation calls
and 11,756,000 allocated bytes.
Other sizes remove 1,200 calls and 459,900 bytes.
The net is 1,700 extra calls and 11,296,100 extra bytes.
All allocated bytes are freed by the end of each boot.

The arena-compatible sizes are 3,888, 3,920, 4,000, 4,048, 4,080, 4,088, 4,096,
and 4,104 bytes on this arm64 host.
QuickJS uses size classes for small objects and releases each empty arena immediately.
The changed module graph and function data alter the allocation sequence and arena occupancy.
The size evidence supports arena churn as the dominant cause.
This histogram has no call stacks, so it does not prove the origin of each individual block.
The isolated variants show that a lower source-line count does not guarantee less allocator work.

Raw files use `/tmp/yuke-boot-<variant>.jsonl`.
The histogram files use `/tmp/yuke-hist-{baseline,final}.{jsonl,log}`.
Temporary probe copies and histogram code remain outside the repository.

## Line count at the start of this investigation

The batch adds 28 net source lines, including both new source files.
Production JS removes 39 net lines.
JS tests add 74 net lines.
The Zig files, which contain both runtime code and tests, remove 7 net lines.
The two report documents had 150 new lines before this investigation.
The count excludes the pre-existing README edit and other user files.

The allocation regression remains unresolved in the application source.
The correctness fixes and the source cleanup must not imply a performance gain.

## Final cleanup before commit

The real job-budget test also checks callback completion and owner wake state.
Two separate host tests for those same behaviors are removed.
The context ownership test no longer repeats the dynamic-value test.
Host test options reuse `execution.testContext` instead of a second execution-context literal.
The pagination boundary, cycle, failure, and result-order checks remain.
The final source diff is net +8 lines, including the two new source files.
These final edits affect test code only; the measured production behavior is unchanged.
The known boot allocation increase remains explicit for the next performance review.

## Follow-up resolution

The transcript performance batch addresses the boot allocation regression with bounded backing-block reuse.
The [follow-up report](transcript-performance-evidence.md) records 133,350,800 bytes per 100 boots.
That result is below the original 173,047,800-byte baseline; all boot bytes are freed.
The historical measurements above remain unchanged.
