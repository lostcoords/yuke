# Transcript and runtime allocation results

Baseline: `84adeaa`, before this batch.
The host uses macOS arm64, Zig 0.16.0, and ReleaseFast.
Each scenario has five repeats of 100 updates at 100 columns and 40 rows.
The native stream starts with 75,776 UTF-8 bytes at scale 1 and 303,104 bytes at scale 4.
The fixtures and benchmark scenarios are unchanged.

## Ownership and behavior

- A text part owns its document, block-end row offsets, and retained transcript rows.
- An append retains rows before the last two markdown blocks; a width change rebuilds all rows.
- A replacement resets that prefix, and transcript eviction releases the entire part cache.
- Public `Document.setText()` still returns a boolean; `Document.rows()` still returns a fresh array.
- Each draft has a process-unique generation. Text and reasoning bytes only append within that lifetime.
- A native text cursor carries that generation and a UTF-8 byte offset instead of the full held text.
- Invalid offsets, a different generation, and committed parts cause a full read.
- A private weak map ties a cursor to a returned part and its unchanged text, type, and part ID.
- A copied, fabricated, or modified plugin value remains valid input and causes a full read.
- The public client API and advice targets remain intact. Cursor fields stay inside the native seam.
- The wire protocol and generated schema are unchanged.

The transcript still assembles message row arrays, and JS still concatenates complete text strings.
This change does not make all update work proportional to the delta size.

## Bounded runtime reuse

The pinned QuickJS source allocates arenas in `arena_new` and frees each empty arena in `js_arena_free`.
The Zig bridge now retains up to eight freed blocks with payload sizes from 3,072 to 4,096 bytes.
A later allocation can reuse a block only when its exact size matches.
A full cache releases the oldest block before it accepts a new block.
The allocator does not round sizes or change the existing realloc path.
The host owns the cache at a stable address and drains it after runtime destruction.

The idle cache can retain at most 32,832 bytes on this arm64 host, plus 136 bytes of host metadata.
These idle blocks are outside QuickJS's logical heap count but inside the benchmark backing counters.
All boot allocation bytes are freed before each measured boot ends.
The cache does not eliminate JS object allocation or QuickJS arena initialization work.

Without reuse, the transcript changes raised boot bytes to 218,042,000 per 100 boots.
They also raised preview bytes to 15,007,488 per 100 updates.
The final cache removes both regressions.
Boot bytes are now below both this batch's 184,343,900 baseline and the original 173,047,800 baseline.
This is an allocator reuse result, rather than a change to import order.

## Allocation evidence

The tables use the third repeat (`repeat: 2`) so every row refers to one actual sample.
Values show before → after. Counts cover repeated work; live and peak bytes include harness state.
All resize attempts and allocation failures are zero in both runs.

| Scenario | Allocation calls | Free calls | Remap attempts |
| --- | ---: | ---: | ---: |
| build | 10,145 → 2,826 | 10,142 → 2,751 | 700 → 600 |
| reflow | 1,304 → 1,000 | 1,308 → 1,002 | 400 → 200 |
| scroll | 100 → 100 | 100 → 100 | 0 → 0 |
| stream | 1,923 → 765 | 1,920 → 762 | 520 → 332 |
| stream_native | 20,022 → 1,205 | 20,088 → 1,205 | 3,601 → 1,201 |
| paint | 200 → 200 | 200 → 200 | 0 → 0 |
| colors | 0 → 0 | 0 → 0 | 0 → 0 |
| selection | 8,498 → 201 | 8,498 → 201 | 0 → 0 |
| preview | 1,205 → 1,200 | 1,210 → 1,206 | 100 → 100 |
| projection | 3,800 → 3,801 | 3,798 → 3,799 | 4,500 → 4,500 |
| gc | 0 → 0 | 0 → 0 | 0 → 0 |
| boot | 95,400 → 82,900 | 95,400 → 82,900 | 1,800 → 1,800 |
| stream_native ×4 | 87,731 → 1,504 | 88,217 → 1,503 | 4,501 → 1,501 |

| Scenario | Allocated bytes | Freed bytes |
| --- | ---: | ---: |
| build | 36,872,040 → 7,308,600 | 36,859,808 → 7,040,008 |
| reflow | 1,395,616 → 766,400 | 1,411,864 → 774,496 |
| scroll | 68,800 → 68,800 | 68,800 → 68,800 |
| stream | 5,349,170 → 1,417,954 | 5,344,402 → 1,416,730 |
| stream_native | 166,119,874 → 34,104,644 | 166,263,482 → 33,985,044 |
| paint | 137,600 → 137,600 | 137,600 → 137,600 |
| colors | 0 → 0 | 0 → 0 |
| selection | 33,993,440 → 141,680 | 33,993,440 → 141,648 |
| preview | 323,568 → 303,200 | 344,016 → 327,576 |
| projection | 88,127,800 → 88,131,896 | 88,021,224 → 88,025,272 |
| gc | 0 → 0 | 0 → 0 |
| boot | 184,343,900 → 133,350,800 | 184,343,900 → 133,350,800 |
| stream_native ×4 | 704,786,338 → 127,651,668 | 706,261,578 → 127,159,412 |

| Scenario | Live bytes | Peak bytes |
| --- | ---: | ---: |
| build | 2,248,389 → 2,514,530 | 2,574,957 → 2,580,274 |
| reflow | 2,195,637 → 2,233,794 | 2,219,203 → 2,245,104 |
| scroll | 2,211,981 → 2,229,706 | 2,212,669 → 2,230,394 |
| stream | 3,267,425 → 3,293,662 | 3,317,717 → 3,325,190 |
| stream_native | 15,329,877 → 10,122,754 | 16,265,839 → 10,373,950 |
| paint | 2,229,031 → 2,234,556 | 2,229,719 → 2,235,244 |
| colors | 1,517,894 → 1,522,126 | 1,517,894 → 1,522,126 |
| selection | 2,208,703 → 2,230,540 | 2,213,471 → 2,234,588 |
| preview | 2,141,937 → 2,176,158 | 2,167,589 → 2,201,690 |
| projection | 2,482,427 → 2,508,384 | 2,888,343 → 2,914,300 |
| gc | 2,207,933 → 2,229,706 | 2,207,933 → 2,229,706 |
| boot | 2,150,893 → 2,176,794 | 3,420,502 → 3,452,000 |
| stream_native ×4 | 53,974,807 → 33,939,460 | 58,613,265 → 34,851,792 |

Live bytes can differ with retained rows, cached free blocks, and the point at which QuickJS collects garbage.
For example, build live bytes rise by 266,141, while build peak bytes rise by 5,317.
The projection case adds one backing allocation and 4,096 allocated bytes in this repeat.
The report does not claim that every scenario uses fewer bytes.

## Separate latency evidence

Each value is the median of the five repeat medians or the five repeat p95 values, in microseconds.
The latency runs disable metrics.
The large native-stream improvement is clear; small differences in other phases do not prove a speed gain.

| Scenario | Median µs | p95 µs |
| --- | ---: | ---: |
| build | 725.5 → 740.2 | 902.6 → 926.4 |
| reflow | 441.8 → 446.2 | 450.5 → 464.0 |
| scroll | 9.5 → 9.6 | 11.7 → 11.6 |
| stream | 269.8 → 245.5 | 295.9 → 267.3 |
| stream_native | 3,641.8 → 681.5 | 4,419.7 → 739.3 |
| paint | 172.2 → 176.8 | 203.0 → 181.8 |
| colors | 128.5 → 131.7 | 143.2 → 134.5 |
| selection | 209.8 → 211.7 | 244.1 → 214.9 |
| preview | 392.3 → 398.7 | 433.3 → 405.8 |
| projection | 537.5 → 531.0 | 598.2 → 545.1 |
| gc | 54.0 → 55.1 | 63.6 → 60.5 |
| boot | 2,436.0 → 2,360.0 | 2,677.5 → 2,450.6 |
| stream_native ×4 | 12,933.4 → 2,094.8 | 13,663.1 → 2,297.1 |

## Verification and commands

All 65 scenario repeats match the baseline checksum, source size, output byte count, and every UI counter.
The harness also compares each final transcript with a fresh render and checks Unicode source spans.
Tests cover stable row identity, append/resize/replacement output, public row snapshots, and cache eviction.
Cursor tests cover byte boundaries, invalid numeric hints without coercion, paging, modified values, and a new draft with the same message ID.
Allocator tests cover the cache bound, calloc zeroes, size reports, failed realloc preservation, and runtime initialization failures.

Commands:

```sh
zig build test --seed 0 --summary new
zig build
mise run check-ts
zig build bench -Doptimize=ReleaseFast -Dmetrics=true
zig build bench -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- --phase stream_native --scale 4
zig build bench -Doptimize=ReleaseFast -- --phase stream_native --scale 4
```

The test command passes all 42 steps and runs 783 source tests.
The application build, three TypeScript checks, and Zig format checks pass.
The source diff adds 193 net lines, including tests.
The cache adds one allocator test; row retention adds one transcript test.
The prior fabricated-prefix loop now has one case because its seven values follow the same fallback path.

Raw files on this machine:

- `/tmp/yuke-transcript-{before,final}-{metrics,latency}.jsonl`
- `/tmp/yuke-transcript-{before,final}-stream4-{metrics,latency}.jsonl`
- `/tmp/yuke-transcript-after-{metrics,latency}.jsonl` isolates the transcript changes without reuse.

The counters cover native and QuickJS backing allocations through the harness allocator.
They do not count every JS object, and they exclude the benchmark output buffer.
Setup precedes the repeated-work snapshot; the boot phase explicitly creates and destroys hosts inside that snapshot.
Advice dispatch, durable commit serialization, and large agent-tree refreshes remain separate review items.

## Fresh and reused color values

The cached baseline and final benchmark executables also ran `--phase colors --colors rgb_raw`
and `--phase colors --colors rgb_fresh`, with metrics and latency separate.
These ten additional repeats match checksums, output bytes, and all UI counters.
Values below use repeat 2 for memory and the median of five medians for latency.

| Values | Calls / frees | Allocated / freed bytes | Live / peak bytes | Median µs |
| --- | --- | --- | --- | ---: |
| rgb_raw | 0 / 0 → 0 / 0 | 0 / 0 → 0 / 0 | 1,517,894 / 1,517,894 → 1,522,126 / 1,522,126 | 130.5 → 133.0 |
| rgb_fresh | 0 / 0 → 0 / 0 | 0 / 0 → 0 / 0 | 1,517,894 / 1,517,894 → 1,522,126 / 1,522,126 | 148.2 → 143.7 |

Resize/remap attempts and allocation failures are zero for both color cases.
Raw files use `/tmp/yuke-transcript-{before,final}-rgb_{raw,fresh}-{metrics,latency}.jsonl`.
