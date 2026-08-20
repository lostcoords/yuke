# bench/ — load & memory harness contract

Shared contract for the Odin client and the benchmark servers (Python
`server.py` and the Odin `bench/server` drop-in). The client and any server it
connects to MUST agree on this. Do not change ports/paths without updating the
client and every server.

## Transport
- `ws://` plaintext, loopback only. No TLS.
- Default host `127.0.0.1`.
- Clean echo/flood benchmark server: **port 8765**, path `/`.
- Adversarial ("evil") server: **port 8766**, path `/`.

## Message protocol (benchmark)
- Text frames. Payload is opaque bytes; the echo server returns the payload verbatim.
- The client owns correctness accounting (sent vs. echoed counts, byte totals).

## Python servers
`server.py` (uses the `websockets` library):
- `--host`, `--port` (default 8765), `--mode {echo,flood}`.
- `echo`: echo every inbound text/binary message back unchanged.
- `flood`: on connect, send `--flood-count` messages of `--flood-size` bytes as fast
  as the socket accepts, then idle. Tests inbound throughput + reassembly memory.
- Must handle many sequential short-lived connections (soak) without leaking.

`evil_server.py` (raw asyncio TCP, hand-rolled frames — the `websockets` lib will
not emit malformed output, so this is separate). `--host`, `--port` (default 8766),
`--attack {...}`. Each attack completes a normal RFC6455 upgrade first (unless the
attack IS the handshake), then abuses the connection. Attacks:
- `oversize_frame`: announce/send a frame far above the client's max_frame_bytes.
- `oversize_message`: many fragments summing past max_message_bytes.
- `bad_opcode`: reserved/unknown opcode.
- `rsv_bits`: set an RSV bit with no extension negotiated.
- `masked_server`: send a masked server→client frame (client must reject).
- `bad_close_code`: Close frame with a wire-invalid code (e.g. 1005, 1015, 0).
- `bad_utf8_text`: Text frame with invalid UTF-8.
- `bad_utf8_close_reason`: Close with valid code but invalid-UTF-8 reason.
- `non_minimal_len`: 16-bit length form encoding a value < 126.
- `ping_flood`: rapid Ping frames (client must auto-Pong, no unbounded growth).
- `drip_handshake`: dribble an upgrade response byte-by-byte, never sending the
  full header terminator — tests MAX_HANDSHAKE_RESPONSE_BYTES + handshake timeout.
- `slow_body`: valid 101, then dribble a frame's bytes slowly (partial-read paths).
- `abrupt_close`: valid handshake, one message, then TCP RST/close with no Close frame.

The client must survive every attack: exactly one terminal callback, no crash, no
leak — either a clean protocol-violation error or the documented close, then a clean
`client_destroy`.

## Odin server (`bench/server/`)
An Odin echo/flood server on the `libs:websocket` nbio server driver — a drop-in
for `server.py` with the same CLI and the same transport/message contract above:
same modes (`echo`/`flood`), same default port (8765), same 1 MiB single-frame /
reassembled-message cap (`MAX_BYTES`, matching the `websockets` v16 defaults the
Python server runs with).
- `--mode echo`: echo every inbound text/binary message back unchanged, same kind.
  The server never closes first.
- `--mode flood`: on connect, stream `--flood-count` text messages of `--flood-size`
  bytes, then idle until the client closes. Messages are streamed from the driver's
  send-completion (`on_drain`) in bounded batches (`FLOOD_BATCH` = 64), never
  enqueued up front, so RSS stays flat regardless of `--flood-count`.

There is no soak or attack mode (those are client-side; adversarial traffic stays
with `evil_server.py`).

## Odin client (`bench/client/`)
Uses `import ws "libs:websocket"`. Single `core:nbio` loop. Wrap the whole run in a
`core:mem.Tracking_Allocator` and print leak + bad-free counts at exit (non-zero exit
code if any leak/bad-free) — this is the primary in-process memory check.

CLI (flags or env, your call — document it):
- `--host`, `--port`, `--path`.
- `--mode {echo,flood,soak,attack}`.
- `echo`: connect once, send `--count` messages of `--size` bytes, wait for all echoes,
  report throughput (msgs/s, MiB/s) and wall time, close cleanly.
- `flood`: connect to the flood server, drain `--count` inbound messages, report
  inbound throughput and peak reassembly behavior, close cleanly.
- `soak`: open→handshake→exchange a few messages→`client_close`→`client_destroy`,
  repeated `--iterations` times (default large, e.g. 5000). This is the leak hunt —
  the whole point is to prove the connection lifecycle frees everything every time.
- `attack`: connect to the evil server (`--port 8766`) and just observe the terminal
  outcome; print which callback fired and the error/close code. Used by the break-it run.

Exit code: 0 only if the run met expectations AND the tracking allocator reports zero
leaks and zero bad frees.

## Build / run
`make bench` builds both bench binaries (`bench-client` and `bench-server`) via the
same `mise exec -- odin` + `-collection:libs=libs` invocation the main Makefile uses.
The full run sequence is documented in `bench/README.md`.
