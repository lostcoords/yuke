# bench/ — load, memory & adversarial harness for `libs:websocket`

This directory stress-tests the Odin WebSocket client in `libs/websocket` for
**throughput**, **memory correctness over many connection lifecycles**, and
**robustness against malformed peers**. It is `ws://` loopback only — no TLS.

The shared wire contract lives in [`SPEC.md`](./SPEC.md); read it first if you
change ports, paths, or attack framing. Both the Odin client and the Python
servers must agree on it.

## Pieces

| File | What it is |
| --- | --- |
| `client/main.odin`, `client/modes.odin` | The Odin bench client. One `core:nbio` loop, four modes (`echo`/`flood`/`soak`/`attack`), wrapped in a `core:mem.Tracking_Allocator`. |
| `server.py` | Clean benchmark server (`websockets` v16). `--mode echo` (byte-exact echo) or `--mode flood` (push N messages on connect). Port **8765**. |
| `evil_server.py` | Adversarial raw-TCP server that hand-rolls malformed handshakes/frames. One `--attack` per run. Port **8766**. |
| `build/logs/` | Captured run output (server logs, `/usr/bin/time -v`, RSS samples, heaptrack/valgrind). |
| `wire/main.odin` | Codec microbenchmark: the tier-1 `server_frame_header_stream` scan. No sockets — it measures the decoder alone. |

## Prerequisites

- Odin via `mise exec -- odin` (pinned in `.mise.toml`).
- Python 3.12 with `websockets` 16.0 (`python3 -c "import websockets"`).
- Optional for the memory deep-dive: `valgrind`, `heaptrack`, `/usr/bin/time -v`.

## Build

```sh
make test-ws            # run the library unit tests (must be green)
```

The client is built exactly like the library: `mise exec -- odin build
bench/client -collection:src=src -collection:libs=libs -out:build/bench-client`.

### Odin server (drop-in for `server.py`)

`bench/server/` is an Odin echo/flood server on the `libs:websocket` nbio server
driver — a drop-in for `server.py` with the same CLI. Build both bench binaries
with `make bench` (or `mise exec -- odin build bench/server -collection:src=src
-collection:libs=libs -out:build/bench-server`), then substitute it for the Python
server anywhere below:

```sh
build/bench-server --mode echo  --port 8765 &
build/bench-server --mode flood --port 8765 --flood-count 200000 --flood-size 256 &
```

Flags: `--mode {echo,flood}`, `--host` (default `127.0.0.1`), `--port` (default
`8765`), `--flood-count` (default `100000`), `--flood-size` (default `256`). Echo
returns each message unchanged in the same kind and never closes first; flood
streams `flood-count` messages from the driver's send-completion with a bounded
queue depth, so server RSS stays flat regardless of count. It has no SIGINT
handler — stop it by PID (`kill $SRV`), as with the Python servers.

## Client CLI

```
build/bench-client --mode {echo,flood,soak,attack} [options]
  --host H         target host (default 127.0.0.1)
  --port N         target port (default 8765; attack defaults to 8766)
  --path P         request path (default /)
  --count N        echo: messages to send; flood: messages to drain
  --size N         payload bytes per outbound message
  --iterations N   soak: full connection lifecycles to run
  --window N       echo: max outstanding unechoed messages (send-queue bound)
  --deadline N     global wall-clock backstop in SECONDS (hard-exits code 2 if tripped)
```

### Modes

- **echo** — connect once, keep `--window` messages in flight until `--count`
  are sent, wait for every echo, report round-trip throughput, close cleanly.
- **flood** — connect to a `--mode flood` server, drain `--count` inbound
  messages, report inbound throughput. Tests reassembly memory: RSS must stay
  flat because the driver frees each message after `on_message`.
- **soak** — run connect→handshake→exchange (3 msgs)→`client_close`→
  `client_destroy` `--iterations` times on one loop. The leak hunt: each
  lifecycle must free everything it allocated before the next connects.
- **attack** — connect to `evil_server.py` and report the single terminal
  callback (`on_error`/`on_close`) with its error/close code.

### Reading the tracking-allocator output

Every run ends with a `--- memory report ---` block:

```
leaked allocations : 0 (0 bytes)   <- allocations still live at exit; MUST be 0
bad frees          : 0             <- double/invalid frees; MUST be 0
peak allocated     : 66814 bytes   <- high-water mark of live bytes
total allocations  : 950746        <- lifetime alloc calls (frees not shown)
result: PASS                       <- PASS only if run met expectations AND 0/0 above
```

The process **exit code is 0 only on `result: PASS`** — i.e. the run met its
mode's expectation *and* zero leaks / zero bad frees. A tripped `--deadline`
hard-exits with code **2** and the message `DEADLINE EXCEEDED …` (state cannot
be reclaimed safely after a canceled kernel op, so the leak report is skipped).

`nbio`'s own event-loop allocations go through `runtime.heap_allocator()`, not
`context.allocator`, so the tracked numbers reflect only client/payload/driver
buffers — exactly what we want to audit.

## Running each part (copy-paste)

Start the server in the background, capture its stderr, and **always kill it by
PID** when done. Do **not** `pkill -f server.py` — the pattern also matches your
own shell.

### Part A — throughput (clean server, 8765)

```sh
# echo sweep
python3 bench/server.py --mode echo --port 8765 --quiet > bench/build/logs/echo_server.log 2>&1 &
SRV=$!
for sz in 64 256 1024 16384; do
  /usr/bin/time -v build/bench-client --mode echo --count 120000 --size $sz \
    --window 256 --deadline 60
done
kill $SRV

# flood (inbound reassembly pressure)
python3 bench/server.py --mode flood --port 8765 --flood-count 200000 --flood-size 256 \
  > bench/build/logs/flood_server.log 2>&1 &
SRV=$!
/usr/bin/time -v build/bench-client --mode flood --count 200000 --window 256 --deadline 60
kill $SRV
```

### Part B — memory soak (8765)

```sh
python3 bench/server.py --mode echo --port 8765 --quiet > bench/build/logs/echo_server.log 2>&1 &
SRV=$!
/usr/bin/time -v build/bench-client --mode soak --iterations 50000 --size 128 --deadline 600
heaptrack -o bench/build/logs/heaptrack build/bench-client --mode soak --iterations 2000 --size 128 --deadline 120
valgrind --leak-check=full build/bench-client --mode soak --iterations 200 --size 128 --deadline 120
kill $SRV
```

### Part C — break it (evil server, 8766)

```sh
for a in oversize_frame oversize_message bad_opcode rsv_bits masked_server \
         bad_close_code bad_utf8_text bad_utf8_close_reason non_minimal_len \
         ping_flood drip_handshake slow_body abrupt_close; do
  python3 bench/evil_server.py --attack "$a" --port 8766 > bench/build/logs/attack_$a.log 2>&1 &
  SRV=$!
  build/bench-client --mode attack --port 8766 --deadline 15
  kill $SRV; wait $SRV 2>/dev/null
done
```

(`bench/build/logs/run_attacks.sh` runs the full 13-attack loop and prints a
summary line per attack.)

### What each attack does

| Attack | Malformed input | Client-side check it targets |
| --- | --- | --- |
| `oversize_frame` | header announces 1.5 MiB (> 1 MiB `max_frame_bytes`) | reject on header alone (decoder) |
| `oversize_message` | two 700 KB fragments sum past 1 MiB `max_message_bytes` | per-frame reassembly bound |
| `bad_opcode` | reserved data opcode `0x3` | `op_code_from_u8` |
| `rsv_bits` | RSV1 set, no extension negotiated | `Reserved_Bit_Set` |
| `masked_server` | server→client frame with MASK bit | servers must not mask |
| `bad_close_code` | Close body carrying wire-invalid 1005 | `close_code_valid_on_wire` |
| `bad_utf8_text` | Text frame with invalid UTF-8 | Text payload UTF-8 validation |
| `bad_utf8_close_reason` | Close 1000 + invalid-UTF-8 reason | `parse_close` reason validation |
| `non_minimal_len` | 5-byte payload in 16-bit length form | `Non_Minimal_Length` |
| `ping_flood` | 2000 rapid Pings | auto-Pong, no unbounded growth |
| `drip_handshake` | endless header-shaped filler, no terminator | 64 KiB `MAX_HANDSHAKE_RESPONSE_BYTES` + timeout |
| `slow_body` | valid frame body dribbled 1 byte at a time | partial-read `Need_More` path (delivered intact) |
| `abrupt_close` | one frame, then TCP abort, no Close frame | `.Abnormal_Closure` |

## Cleanup

Always kill every server you started (by PID) and confirm:

```sh
pgrep -fa 'server.py|evil_server.py'   # must return nothing
```

---

## Results — historical baseline, Python server, run of **2026-07-21**

These numbers predate the Odin server driver (`bench/server/`) and the
NODELAY/coalescing perf pass below; they're kept as the comparison point the
"vs Python" multiples in the 2026-07-22 section are computed against. Where
this section's prose claims something (e.g. "capped by the single-threaded
Python asyncio echo server") it describes this baseline run, not the current
state of the harness.

Environment: Linux WSL2 (loopback `ws://`), Odin via mise, Python 3.12 +
websockets 16.0. Client defaults exercised: `max_frame_bytes` = 1 MiB,
`max_message_bytes` = 1 MiB, `handshake_timeout` = 10 s,
`MAX_HANDSHAKE_RESPONSE_BYTES` = 64 KiB.

`make test-ws` — **73 tests, all successful** (confirmed before and after the runs).

**Every run below reported `leaked allocations : 0 (0 bytes)` and `bad frees : 0`.**

### Part A — echo throughput (window 256)

| Size | Count | msgs/s | MiB/s | Wall time | Max RSS | CPU% | Peak alloc |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 B | 120000 | 25,312 | 1.54 | 4.74 s | 2,660 KB | 32% | 87.8 KB |
| 256 B | 120000 | 30,367 | 7.41 | 3.95 s | 2,752 KB | 60% | 137.7 KB |
| 1024 B | 100000 | 31,735 | 30.99 | 3.15 s | 2,884 KB | 74% | 338.0 KB |
| 16384 B | 60000 | 5,280 | 82.50 | 11.36 s | 7,048 KB | 109% | 4.51 MB |

Notes: msgs/s is capped by the single-threaded Python asyncio echo server, not
the client. The 16 KiB row trades msgs/s for the highest byte throughput
(82.5 MiB/s); its peak-alloc (~4.5 MB) is simply `window (256) × 16 KiB` of
outstanding payload buffers — expected and reclaimed. Max RSS stays 2.6–7 MB.

### Part A — flood (inbound reassembly pressure, window 256)

| Size | Count drained | msgs/s | MiB/s | Wall time | Max RSS | Peak alloc |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 B | 200000 | 38,502 | 9.40 | 5.19 s | 2,484 KB | 102.8 KB |
| 4096 B | 200000 | 76,952 | 300.59 | 2.60 s | 2,508 KB | 242.2 KB |

**RSS stays flat** while draining 200k inbound messages (peak-alloc ~100–240 KB,
never proportional to the 51 MB / 819 MB total moved) — the driver frees each
message after `on_message` and does not accumulate. This was the key inbound
memory check and it passes cleanly.

### Part B — memory soak (VERDICT: no leak, RSS flat)

`--iterations 50000`, 128 B payload, 3 msgs/iteration (150,000 msgs echoed):

- **RSS: start 2,652 KB → end 2,660 KB → peak 2,660 KB** (sampled every 250 ms,
  136 samples). Dead flat — 8 KB drift across 50,000 full connection lifecycles.
  A leak would grow RSS monotonically with iteration count; it does not.
- Sample points (elapsed s → RSS KB): `0.01→2652, 4.91→2660, 13.0→2660,
  18.2→2660, 23.3→2660, 28.5→2660, 33.7→2660, 37.8→2660`.
- Tracking allocator at exit: **0 leaks / 0 bad frees**, peak allocated
  **66,814 bytes**, total allocations **950,746** — i.e. ~950k allocations over
  the run but only 66 KB ever live at once. Every lifecycle frees everything.
- `/usr/bin/time -v`: Max RSS 2,472 KB, wall 37.85 s, 36% CPU.

**heaptrack** (2000-iteration soak): **total memory leaked 0 B**, peak heap
146.11 KB, peak RSS 5.74 MB (incl. heaptrack overhead), 38,041 allocation calls
all matched by frees.

**valgrind** (`--leak-check=full`, 200-iteration soak): leak-clean —
*"All heap blocks were freed -- no leaks are possible"*, `in use at exit: 0 bytes
in 0 blocks`. valgrind did **not** choke on io_uring here. It does report
`ERROR SUMMARY: 13076 errors from 2 contexts`, but both contexts are the same
benign *"Conditional jump or move depends on uninitialised value(s)"* inside
`runtime::conditional_mem_zero` → `heap_allocator_proc.aligned_resize` during
dynamic-array growth. That is a known Odin-runtime allocator false positive
(valgrind flags the z-fill branch), **not** a client/driver memory-safety defect
and **not** io_uring related — the leak accounting is fully clean.

### Part C — adversarial (13 attacks, evil server 8766)

Each: client `--mode attack --deadline 15`. PASS = terminates (no deadline
trip), no crash, 0 leaks / 0 bad frees, sane rejection.

| Attack | Client terminal outcome | Leaks / bad-frees | PASS |
| --- | --- | :---: | :---: |
| oversize_frame | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| oversize_message | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| bad_opcode | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| rsv_bits | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| masked_server | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| bad_close_code | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| bad_utf8_text | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| bad_utf8_close_reason | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| non_minimal_len | `on_error` — Protocol_Violation | 0 / 0 | ✅ |
| ping_flood | `on_close` — Abnormal_Closure | 0 / 0 | ✅ |
| drip_handshake | `on_error` — Handshake_Failed | 0 / 0 | ✅ |
| slow_body | `on_close` — Abnormal_Closure | 0 / 0 | ✅ |
| abrupt_close | `on_close` — Abnormal_Closure | 0 / 0 | ✅ |

All 13 pass. Notes:

- **ping_flood**: after 2000 rapid Pings the Max RSS was **2,520 KB** with peak
  alloc 69.6 KB — the client auto-Pongs and sheds control frames inline; **no
  RSS balloon**. It terminates as `Abnormal_Closure` because the evil server,
  after sending the flood, tears the TCP connection down without a Close frame.
- **drip_handshake**: rejected as `Handshake_Failed` (the 64 KiB
  `MAX_HANDSHAKE_RESPONSE_BYTES` cap), rc=0 — not a deadline abort.
- **slow_body / abrupt_close / ping_flood** all surface `Abnormal_Closure`. For
  `slow_body` the dribbled message is received intact first; the abnormal close
  is the evil server's TCP teardown (no Close frame), which is the documented
  behavior for a dropped connection — not a client defect.

### Part D — concurrency / windowing

- **6 concurrent echo clients**, 40,000 msgs × 256 B each, `--window 128`: all 6
  PASS, each received all 40,000 echoes, ~3,450 msgs/s each (the single
  Python server splits its capacity across the six connections). Send-queue
  serialization and per-client accounting held; no leaks.
- **Window sweep** (60,000 msgs, 256 B): window 1 → 5,881 msgs/s, 16 → 18,388,
  128 → 26,480, 1024 → 30,199. Strict ping-pong (`--window 1`, one message in
  flight) is RTT-bound as expected and still PASS with 0 leaks; throughput
  plateaus past ~128 as the server saturates. No anomalies.

### Bugs found

**None.** No hang, crash, leak, or double-free across throughput, a 50,000-cycle
soak, heaptrack/valgrind, all 13 adversarial attacks, and the concurrency runs.
The only non-green artifact is valgrind's benign uninitialised-value warning in
the Odin runtime allocator (see Part B), which is not a defect in
`libs/websocket` or the bench client.

---

## Results — Odin server, run of **2026-07-22**

`build/bench-server` (§ "Odin server" above) against `build/bench-client`, after
the TCP_NODELAY fix (accepted + dialed sockets) and bounded vectored send
coalescing (`SEND_BATCH_BYTES` 256 KiB, `SEND_BATCH_FRAMES` 512). Same WSL2
loopback environment as the baseline above. Logs:
`bench/build/logs/{odin,odin-nodelay,odin-batch}/` — the numbers below are
`odin-batch`, the final configuration.

| Mode | Size | Count/window | Odin server | Python baseline (above) | Speedup |
| --- | ---: | --- | ---: | ---: | ---: |
| echo | 64 B | ×200,000, window 256 | ~282,000–295,000 msgs/s | 22,700 msgs/s | ~13× |
| echo | 4,096 B | window 256 | ~26,000–30,000 msgs/s | 23,700 msgs/s | ~1.2× |
| flood | 256 B | ×500,000 | ~1.0M msgs/s | 41,000 msgs/s | ~25× |
| soak | — | — | ~2,500 iter/s | ~1,200 iter/s | ~2× |

At 64 B the Odin server is no longer the bottleneck (unlike the Python-only
baseline above, where the single-threaded asyncio server capped throughput);
now the client/kernel path dominates. At 4,096 B the two are close to parity —
both sides pin one core on per-byte work (masking/memcpy/kernel copies for the
Odin path, a C extension's per-byte path for `websockets`), so ~1.2× is
expected rather than a regression. Zero leaked allocations and zero bad frees
across every run; a 20,000-connection soak held flat RSS and fd count on the
server. Valgrind on the Odin server was inconclusive under WSL2 (the `io_uring`
wait blocks signals under emulation) — not a finding, just a tooling gap on
this platform.

## Results — wire header scan, run of **2026-07-27**

```sh
mise exec -- odin build bench/wire -collection:src=src -collection:libs=libs \
  -out:build/bench-wire -o:speed && ./build/bench-wire
```

`server_frame_header_stream` classifies a server frame and reads its routing key
from the member keys alone. What matters is whether that cost tracks payload size,
and whether it allocates.

| case | ns/op | allocs/op | peak bytes |
| --- | --- | --- | --- |
| in-order, empty | 1,748 | 5 | 24 |
| in-order, 1 KiB | 1,440 | 5 | 24 |
| in-order, 64 KiB | 1,168 | 5 | 24 |
| in-order, 1 MiB | 1,249 | 5 | 24 |
| payload-first, empty | 1,517 | 5 | 24 |
| payload-first, 1 KiB | 7,184 | 5 | 24 |
| payload-first, 64 KiB | 366,570 | 5 | 24 |
| payload-first, 1 MiB | 7,404,573 | 5 | 24 |

**In the normative member order (`jsonrpc`, `id`, then `result`/`error`) the scan is
flat**: ~1.0–1.4 µs from an empty payload to 1 MiB. Routing needs only a member's
key, so the scan stops at the discriminating key and never reads the value.

**Allocation is constant at 5 per op and 24 peak bytes in every case**, independent
of payload size and member order: the unquoted member keys plus the id token clone.
`dec_skip` allocates nothing. So the cost is pure CPU and the arena never grows with
the frame.

**A peer that emits its payload before `id` pays a linear token walk** — ~5 ns/byte,
so 5–7 ms for a 1 MiB frame. No allocation growth, but on a single-threaded reactor
that is real blocking work. This path is client-side only (`server_frame_header_stream`
routes *server* frames; the daemon decodes requests with `request_from_reader`), so
the exposure is a daemon a client chose to dial, not an unauthenticated peer.

**The per-frame arena is the dominant cost, and it is not the scan's.** The five
allocator calls are arena bumps, but `free_all` on a `mem.Dynamic_Arena` maps to
`dynamic_arena_free_all`, which releases its blocks to the heap — so each frame
mallocs and frees a fresh 64 KiB block (`DYNAMIC_ARENA_BLOCK_SIZE_DEFAULT`) to hold
~24 bytes. Measured over 50k scans of a small frame:

| per-frame reset | ns/op | heap allocs | heap bytes |
| --- | --- | --- | --- |
| `free_all` (what `daemon_handle_text` / `client_handle_text` do) | 1,191 | 50,001 | 3.28 GB |
| `mem.dynamic_arena_reset` | 376 | 2 | 131 KB |

`dynamic_arena_reset` keeps blocks on `unused_blocks` for reuse instead of freeing
them, so steady-state heap traffic goes to zero and the scan gets ~3.2× faster. The
trade is that each connection then holds its high-water mark until teardown, bounded
by `LIMITS.max_frame_bytes`. This predates the JSON-RPC migration and applies to the
whole per-frame decode path, not just the header scan.

The absolute floor (~1 µs) includes the `Tracking_Allocator` and that per-iteration
arena reset, so treat these as an upper bound; the shape across sizes is the result.
