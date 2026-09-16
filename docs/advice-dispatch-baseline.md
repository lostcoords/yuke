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
