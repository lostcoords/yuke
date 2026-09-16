# Advice dispatch baseline

Production baseline: `379f53e`. The advice implementation is unchanged.
Only benchmark code and this report were added for this measurement.

## Method

- macOS arm64, Zig 0.16.0, ReleaseFast.
- Each case has five repeats of 100 samples. Each sample has 1,000 calls or lifecycle cycles.
- Each repeat has 100,000 calls or cycles; setup, one warmup batch, and GC precede the counter snapshot.
- The method reads `this.bias`, takes three numeric arguments, and returns their sum plus the bias.
- The same method and module graph serve the direct and advised cases.
- Handlers perform minimal work: they count a hit and forward arguments or results unchanged.
- Mixed groups have one handler of each type: filterArgs, before, around, filterReturn, and after.
- A lifecycle cycle registers the stated number of around handlers, then removes them in reverse order.
- Lifecycle timing includes benchmark list bookkeeping. It excludes plugin Scope ownership and callback creation.
- No terminal, network, promise settlement, or real plugin workload is measured.

Latency uses a separate run without metrics. Each table value is the median of five repeat medians.
The unit is microseconds per call, or per lifecycle cycle, averaged over a batch.
These are not individual-call tail latency measurements.

## Call latency

| Scenario | Handler count | µs/call |
| --- | ---: | ---: |
| direct (control, scale 1) | 0 | 0.059 |
| direct (control, scale 4) | 0 | 0.059 |
| direct (control, scale 16) | 0 | 0.058 |
| before | 1 | 1.165 |
| before | 4 | 1.865 |
| before | 16 | 4.273 |
| around | 1 | 1.593 |
| around | 4 | 3.424 |
| around | 16 | 10.914 |
| mixed | 5 | 2.677 |
| mixed | 20 | 7.587 |
| mixed | 80 | 27.454 |

## Registration and removal

| Entries per cycle | µs/cycle | Allocations / frees per 100,000 cycles | Allocated / freed bytes |
| ---: | ---: | --- | --- |
| 1 | 2.455 | 100,000 / 100,000 | 52,800,000 / 52,800,000 |
| 4 | 6.859 | 400,000 / 400,000 | 211,200,000 / 211,200,000 |
| 16 | 31.863 | 1,600,000 / 1,600,000 | 844,800,000 / 844,800,000 |

All warmed call scenarios have zero backing allocation/free calls and zero allocated/freed bytes in every repeat.
All cases have zero resize attempts, remap attempts, and allocation failures.
Lifecycle cycles allocate and free 528 backing bytes per handler entry in this scenario.
The measurement does not identify the source of that block.

QuickJS can reuse arenas and the bounded host cache. Zero backing allocations do not mean zero JS objects.
The source still constructs wrapper functions and argument arrays inside `applyAdvice`.

## Resident and peak bytes

These values use repeat 2 and include harness state. They are not process RSS.

| Scenario | Scale | Live bytes | Peak bytes |
| --- | ---: | ---: | ---: |
| direct | 1 | 1,428,901 | 1,428,901 |
| direct | 4 | 1,428,901 | 1,428,901 |
| direct | 16 | 1,428,901 | 1,428,901 |
| before | 1 | 1,432,989 | 1,432,989 |
| before | 4 | 1,432,989 | 1,432,989 |
| before | 16 | 1,445,197 | 1,445,197 |
| around | 1 | 1,432,989 | 1,432,989 |
| around | 4 | 1,432,989 | 1,432,989 |
| around | 16 | 1,453,357 | 1,453,357 |
| mixed | 1 | 1,432,989 | 1,432,989 |
| mixed | 4 | 1,445,197 | 1,445,197 |
| mixed | 16 | 1,505,429 | 1,505,429 |
| churn | 1 | 1,432,989 | 1,433,517 |
| churn | 4 | 1,432,989 | 1,433,517 |
| churn | 16 | 1,441,149 | 1,441,677 |

## Interpretation

One before handler adds about 1.11 microseconds over the direct control.
One around handler adds about 1.53 microseconds. Longer chains add measurable CPU cost.
The ratios against the trivial direct method are large; the absolute cost remains small for infrequent calls.
The built-in registration found in `command-ui.js` wraps `Chat.send` to intercept slash commands.
This source inventory does not measure user plugin traffic or establish a frame-time bottleneck.

The first candidate is the unconditional call wrapper, which exists even when the chain has no around handler.
The five list scans and per-call around chain construction are further candidates.
Any change needs checks for handler order, receiver identity, reentrancy, disposal, and retained next callbacks.
The results support a bounded CPU-focused review. They do not justify a broad cache design by themselves.

## Reproduction and validation

For each phase `advice_direct`, `advice_before`, `advice_around`, `advice_mixed`, and `advice_churn`,
run each scale 1, 4, and 16:

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase advice_around --scale 1
zig build bench -Doptimize=ReleaseFast -- --phase advice_around --scale 1
```

All 150 result records pass their checks. Metrics and latency checksums match for every case.
The benchmark verifies method results, receiver use, call counts, handler counts, and complete teardown.
`zig build test-js --seed 0 --summary new` passes 783 tests, including the new benchmark cases.
`zig build test --seed 0 --summary new`, `mise run check-ts`, and `zig fmt --check src/js/bench.zig` pass.

Raw files: `/tmp/yuke-advice_<direct|before|around|mixed|churn>-<1|4|16>-<metrics|latency>.jsonl`.
Counters cover native and QuickJS backing allocations through the harness allocator.
They exclude the benchmark output buffer and do not count every JS object.

## No-around fast path

The dispatch now creates the original-call wrapper only if an around handler exists.
The five passes and live list mutation rules remain intact. No cache state is added.
The direct path retains an argument copy to preserve a custom filterArgs iterator.
The production diff adds one net line. Three focused contract checks add 35 test lines.

The fresh comparison uses `ac12982` as the baseline, on the same machine and configuration.
Each value below is microseconds per call, except churn, which is per lifecycle cycle.
Scale 4 and 16 use the saved baseline above and new after runs.

| Scenario | Scale | Before | After |
| --- | ---: | ---: | ---: |
| direct | 1 | 0.0588 | 0.0570 |
| before | 1 | 1.1790 | 0.9575 |
| before | 4 | 1.8652 | 1.6373 |
| before | 16 | 4.2729 | 3.9490 |
| around | 1 | 1.5975 | 1.5514 |
| around | 4 | 3.4236 | 3.3647 |
| around | 16 | 10.9144 | 10.8069 |
| mixed | 1 | 2.6485 | 2.6256 |
| mixed | 4 | 7.5874 | 7.4250 |
| mixed | 16 | 27.4541 | 27.2070 |
| churn | 1 | 2.3504 | 2.4241 |
| churn | 4 | 6.8589 | 6.7458 |
| churn | 16 | 31.8635 | 31.5376 |

The one-before case improves about 19%; the larger before lists improve about 12% and 8%.
The direct control also improves about 3%, so some latency shift is unrelated to this path.
No speed gain is claimed for around, mixed, churn, boot, or UI phases.

All advice allocation/free counts and byte totals match the baseline in every repeat.
Resize attempts, remap attempts, and allocation failures remain zero for advice.
Warm calls still have zero measured backing allocations; this does not count every JS object.
Live and peak advice bytes rise by 34, except mixed scale 16, where both fall by 3,982.
These totals include harness and arena state; the cause of the mixed-scale difference is not isolated.

The full benchmark covers all 17 phases, with five repeats in each metrics and latency run.
All full-run result checksums, source/output byte counts, and UI counters match before and after.
At repeat 2, live and peak bytes rise by 34 in every phase except colors and boot.
Colors is unchanged. Boot live bytes rise by 34 and peak bytes rise by 68.
Boot allocates and frees 3,400 more bytes per 100 boots in every repeat.
Its 82,900 allocations, 82,900 frees, and 1,800 remap attempts remain unchanged.
Boot resize attempts and allocation failures remain zero.
Build repeats 0, 3, and 4 have small counter differences:

| Repeat | Allocation delta | Free delta | Allocated byte delta | Freed byte delta |
| --- | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | -32 | -32 |
| 3 | -4 | -1 | -15,976 | -3,712 |
| 4 | 4 | 16 | 16,448 | 56,148 |

All other full-run allocation fields match for every repeat.
These build differences do not establish a gain or regression from advice dispatch.
The earlier boot allocation fix remains effective; this change adds 34 bytes per boot.

Commands for the full comparison:

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true
zig build bench -Doptimize=ReleaseFast
```

The scale 4 and 16 runs use the phase-specific commands above.
Raw full-run files are `/tmp/yuke-advice-fast-{before,after}-{metrics,latency}.jsonl`.
Raw scaled after files are `/tmp/yuke-advice-fast-advice_<before|around|mixed|churn>-<4|16>-<metrics|latency>.jsonl`.

The full test suite passes all 42 steps and 783 source tests.
The new checks cover argument iteration, current-call around registration/removal, and retained next receivers.
`mise run check-ts` and `zig build` pass. No Zig source changes are present.
Further scan consolidation requires a separate decision about live mutation semantics.
