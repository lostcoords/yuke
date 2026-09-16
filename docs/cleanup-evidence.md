# Cleanup evidence

## Scope

The transcript removes six empty-array fallbacks after `_partState`.
That method returns a loaded array. The cache still uses null to mark stale parts.
A return type cast states this guarantee without a new object or array.
The process wrapper uses a two-element tuple for stdout and stderr listeners.
The native callback emits stream 1 or 2 from its fixed two-stream array.
The wrapper removes three checks for absent listener arrays.
A private engine helper shares the session projection, child outcome query, and live activity read.
The query order and allocator remain the same. Session get still loads instructions and skills.
The JS plugin API and wire schema remain unchanged.
The source diff has 21 added lines and 20 removed lines: net +1.
No test or fixture was added or removed.

## Method

The baseline is commit `ea4f9a1`. The after run uses this cleanup.
Each phase uses scale 1 and 20 measured operations per repeat.
Three invocations each emit five repeats: 15 repeats per phase and mode.
The phases are `stream_native`, `agents_activity`, and `agents_structure`.
The agent phases use one child and the default wide tree.
The harness excludes setup from operation counters and warms the agent picker before each repeat.
Live and peak bytes include the host state.

```sh
zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase PHASE --scale 1 --iterations 20
zig build bench -Doptimize=ReleaseFast -- --phase PHASE --scale 1 --iterations 20
```

The host counters include native and QuickJS backing allocations through its allocator.
They exclude SQLite internal allocations and the report output buffer.
They do not count every JS object. The agent phases do not paint the picker.
These scenarios do not measure process output dispatch; existing process tests check both streams.

## Counters

All 45 before/after repeat pairs match for allocations, frees, allocated/freed bytes,
resize/remap attempts, allocation failures, UI work, requests, output bytes, and checksums.
Live and peak backing bytes are 14 bytes lower after the change.
The table shows repeat 2 of the first invocation; values cover 20 operations.

| Phase | Allocations / frees | Allocated / freed bytes | Resize / remap | Failures | Live bytes before → after | Peak bytes before → after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| stream_native | 242 / 243 | 6,841,764 / 6,726,916 | 0 / 241 | 0 | 10,110,014 → 10,110,000 | 10,360,602 → 10,360,588 |
| agents_activity | 80 / 80 | 74,200 / 74,200 | 40 / 0 | 0 | 2,243,861 → 2,243,847 | 2,247,571 → 2,247,557 |
| agents_structure | 201 / 202 | 191,680 / 195,680 | 180 / 0 | 0 | 2,313,245 → 2,313,231 | 2,321,883 → 2,321,869 |

The transcript has 20 frames, 3,452 text calls, and 3,549 measure calls per repeat.
Its checksum is 98,876,483. The agent checksum is 2.
Activity has 20 gets and no lists. Structure has 20 gets and 40 lists.
Both agent phases have 20 picker updates and zero paint counters.

## Validation

`zig build test --seed 0 --summary new` passes all 42 steps: 797 tests pass and 1 skips.
The host lacks `/usr/bin/setsid`, which the detached-session process test requires.
The application build, all three TypeScript checks, Zig format, and diff checks pass.
The schema checks pass without a generated change.

Raw files are `/tmp/yuke-cleanup-{before,after}-{phase}-{metrics,latency}.jsonl` on this machine.

## Latency

Values are the median of 15 repeat medians, in microseconds per operation.

| Phase | Before | After |
| --- | ---: | ---: |
| stream_native | 681.834 | 688.792 |
| agents_activity | 18.375 | 18.417 |
| agents_structure | 148.000 | 145.833 |

The changes are small and mixed. This cleanup has no speed claim.
