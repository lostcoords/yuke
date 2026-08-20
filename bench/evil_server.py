#!/usr/bin/env python3
"""bench/evil_server.py — adversarial raw-TCP WebSocket server for the Odin
`libs:websocket` client's break-it test. See bench/SPEC.md for the contract.

This is deliberately NOT built on the `websockets` library: that library will
never emit a malformed handshake or frame, and the whole point here is to hand
the client bytes a correct implementation would refuse to produce. Instead this
does the RFC 6455 server handshake by hand (asyncio.start_server + raw sockets)
and hand-encodes each malformed frame so we control every header bit.

Each `--attack` completes a normal upgrade handshake first (except
`drip_handshake`, which *is* the handshake attack), then sends bytes crafted to
trip one specific check in libs/websocket/frame.odin, decoder.odin, or
client.odin. See the per-attack docstrings below for the exact byte layout and
which client-side check it targets.
"""

import argparse
import asyncio
import base64
import hashlib
import logging
import os
import struct
import sys

log = logging.getLogger("bench.evil_server")

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# RFC 6455 opcodes (frame.odin `Op_Code`). 0x3-0x7 and 0xB-0xF are reserved /
# unassigned and are exactly what `bad_opcode` needs.
OP_CONTINUATION = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_RESERVED_DATA = 0x3
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

# How long to keep a connection open after sending a malformed frame so the
# client has time to read it, react, and (for the human running the test)
# report its terminal outcome before we tear the socket down.
HOLD_SECONDS = 1.0

MAX_HANDSHAKE_REQUEST_BYTES = 64 * 1024


# ---------------------------------------------------------------------------
# Handshake (shared by every attack except drip_handshake)
# ---------------------------------------------------------------------------


def compute_accept(key_b64: str) -> str:
    """Sec-WebSocket-Accept = base64(sha1(key + WS_GUID)) — RFC 6455 §4.2.2."""
    digest = hashlib.sha1((key_b64 + WS_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def parse_request_key(request: bytes) -> str | None:
    """Pull Sec-WebSocket-Key out of a raw HTTP upgrade request. Header names
    are matched case-insensitively per RFC 7230; the Odin client itself emits
    them lowercase, but a hand-rolled parser here should not depend on that."""
    text = request.decode("iso-8859-1", errors="replace")
    for line in text.split("\r\n")[1:]:
        if not line:
            continue
        name, _, value = line.partition(":")
        if name.strip().lower() == "sec-websocket-key":
            return value.strip()
    return None


async def read_handshake_request(reader: asyncio.StreamReader) -> bytes:
    """Read the client's GET upgrade request up to and including the blank
    line terminating the header block."""
    return await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10.0)


async def send_handshake_ok(writer: asyncio.StreamWriter, key_b64: str) -> None:
    accept = compute_accept(key_b64)
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(response)
    await writer.drain()


# ---------------------------------------------------------------------------
# Frame encoding — a small hand-written server-frame encoder. Unlike the
# client's own `encode_frame` (libs/websocket/frame.odin), this one never
# masks by default (servers must not — RFC 6455 §5.1) and exposes every knob
# (RSV bits, forced non-minimal length form, forced masking) an attack needs.
# ---------------------------------------------------------------------------


def frame_header(
    fin: bool,
    opcode: int,
    length: int,
    mask: bool = False,
    rsv1: int = 0,
    rsv2: int = 0,
    rsv3: int = 0,
    force_form: str | None = None,
) -> bytes:
    """Encode a frame header. `force_form` overrides the RFC-minimal length
    encoding: '16' always uses the 16-bit extended-length form (byte 2 == 126)
    even for a length that would fit in 7 bits, and '64' always uses the
    64-bit form (byte 2 == 127) — both are how `non_minimal_len` builds a
    header `parse_header` must reject (frame.odin: `Non_Minimal_Length`).

    Byte layout (RFC 6455 §5.2):
      byte 0: FIN(1) RSV1(1) RSV2(1) RSV3(1) OPCODE(4)
      byte 1: MASK(1) PAYLOAD_LEN(7)
      then 0/2/8 bytes of extended length, then 0/4 bytes of mask key
      (mask key is NOT included here — caller appends it when mask=True).
    """
    b0 = (int(fin) << 7) | (rsv1 << 6) | (rsv2 << 5) | (rsv3 << 4) | (opcode & 0x0F)
    mbit = 0x80 if mask else 0x00

    out = bytearray([b0])

    if force_form == "64" or (force_form is None and length > 0xFFFF):
        out.append(mbit | 127)
        out += struct.pack(">Q", length)
    elif force_form == "16" or (force_form is None and length >= 126):
        out.append(mbit | 126)
        out += struct.pack(">H", length)
    else:
        out.append(mbit | length)

    return bytes(out)


def mask_bytes(payload: bytes, key: bytes) -> bytes:
    return bytes(b ^ key[i % 4] for i, b in enumerate(payload))


async def hold(writer: asyncio.StreamWriter, seconds: float = HOLD_SECONDS) -> None:
    """Keep the TCP connection open a moment after a malformed send so the
    client has time to read, react, and report its terminal outcome."""
    try:
        await asyncio.sleep(seconds)
    except asyncio.CancelledError:
        raise


# ---------------------------------------------------------------------------
# Attacks. Every handler receives the connected (reader, writer) *after* a
# valid 101 handshake (drip_handshake is the one exception, wired separately).
# ---------------------------------------------------------------------------


async def attack_oversize_frame(reader, writer, peer) -> None:
    """Announce a single frame far above the client's default
    `max_frame_bytes` (1 MiB). decoder.odin checks `header.len >
    max_frame_bytes` immediately after the header is parsed, before the
    payload is buffered, so the client rejects this on the header alone —
    we don't need to actually put 1.5 MiB on the wire."""
    length = (1 << 20) + (1 << 19)  # 1.5 MiB, well past the 1 MiB default
    header = frame_header(fin=True, opcode=OP_BINARY, length=length)
    writer.write(header)
    writer.write(b"A" * 4096)  # a token slice of the "payload", never the rest
    await writer.drain()
    log.info("%s: sent oversize frame header, announced len=%d (only 4096 payload bytes actually sent)", peer, length)
    await hold(writer)


async def attack_oversize_message(reader, writer, peer) -> None:
    """Two data fragments, each individually under `max_frame_bytes`, whose
    sum exceeds `max_message_bytes` (1 MiB default). decoder.odin's
    reassembly loop checks `header.len > max_message_bytes - len(message)`
    per-frame, once each frame's own payload is fully buffered — so both
    fragments must actually be sent in full."""
    chunk = 700_000  # under 1 MiB alone; two of them sum past it
    h1 = frame_header(fin=False, opcode=OP_TEXT, length=chunk)
    writer.write(h1 + b"a" * chunk)
    await writer.drain()

    h2 = frame_header(fin=False, opcode=OP_CONTINUATION, length=chunk)
    writer.write(h2 + b"b" * chunk)
    await writer.drain()

    log.info("%s: sent 2 fragments of %d bytes (total %d > 1 MiB default max_message_bytes)", peer, chunk, 2 * chunk)
    await hold(writer)


async def attack_bad_opcode(reader, writer, peer) -> None:
    """Opcode 0x3 falls in the reserved/unassigned data-opcode range
    (0x3-0x7); `op_code_from_u8` in frame.odin only maps 0x0-0x2 and
    0x8-0xA, so this must fail with `Unrecognized_Opcode`."""
    payload = b"hello"
    header = frame_header(fin=True, opcode=OP_RESERVED_DATA, length=len(payload))
    writer.write(header + payload)
    await writer.drain()
    log.info("%s: sent frame with reserved opcode 0x%X", peer, OP_RESERVED_DATA)
    await hold(writer)


async def attack_rsv_bits(reader, writer, peer) -> None:
    """Set RSV1 on a Text frame with no extension negotiated. `parse_header`
    rejects any RSV bit set outright (`Reserved_Bit_Set`) since this client
    never negotiates extensions."""
    payload = b"hello"
    header = frame_header(fin=True, opcode=OP_TEXT, length=len(payload), rsv1=1)
    writer.write(header + payload)
    await writer.drain()
    log.info("%s: sent Text frame with RSV1 set", peer)
    await hold(writer)


async def attack_masked_server(reader, writer, peer) -> None:
    """A server->client frame with the MASK bit set. RFC 6455 §5.1 forbids
    servers from masking; `parse_header` rejects any inbound frame with
    `h1.mask` set (`Masked`), regardless of payload content."""
    payload = b"hello"
    key = os.urandom(4)
    header = frame_header(fin=True, opcode=OP_TEXT, length=len(payload), mask=True)
    writer.write(header + key + mask_bytes(payload, key))
    await writer.drain()
    log.info("%s: sent masked server frame (servers must not mask)", peer)
    await hold(writer)


async def attack_bad_close_code(reader, writer, peer) -> None:
    """Close frame carrying 1005 (No_Status_Rcvd) on the wire. 1005 is
    synthesized-only — a real close body must never carry it explicitly —
    so `close_code_valid_on_wire` rejects it (`Invalid_Close_Code`)."""
    code = 1005
    body = struct.pack(">H", code)
    header = frame_header(fin=True, opcode=OP_CLOSE, length=len(body))
    writer.write(header + body)
    await writer.drain()
    log.info("%s: sent Close frame with wire-invalid code %d", peer, code)
    await hold(writer)


async def attack_bad_utf8_text(reader, writer, peer) -> None:
    """Text frame payload containing an invalid UTF-8 byte sequence (a bare
    0xFF/0xFE pair, which is not a valid UTF-8 lead byte). Reassembly
    validates Text payloads as UTF-8 (`Invalid_Utf8`)."""
    payload = b"valid-prefix-\xff\xfe-invalid"
    header = frame_header(fin=True, opcode=OP_TEXT, length=len(payload))
    writer.write(header + payload)
    await writer.drain()
    log.info("%s: sent Text frame with invalid UTF-8 payload", peer)
    await hold(writer)


async def attack_bad_utf8_close_reason(reader, writer, peer) -> None:
    """Close frame with a valid status code (1000) but a reason string that
    is not valid UTF-8. `parse_close` validates the code first, then the
    trailing reason bytes with `utf8.valid_string` (`Invalid_Utf8`)."""
    code = 1000
    reason = b"\xff\xfe not utf-8"
    body = struct.pack(">H", code) + reason
    header = frame_header(fin=True, opcode=OP_CLOSE, length=len(body))
    writer.write(header + body)
    await writer.drain()
    log.info("%s: sent Close frame code=1000 with invalid-UTF-8 reason", peer)
    await hold(writer)


async def attack_non_minimal_len(reader, writer, peer) -> None:
    """A 5-byte Text payload encoded with the 16-bit extended-length form
    (byte 2 == 126) instead of the single 7-bit length byte that could hold
    it. RFC 6455 §5.2 forbids non-minimal length encoding; `parse_header`
    checks `length < PAYLOAD_LEN_16` inside the 16-bit branch
    (`Non_Minimal_Length`)."""
    payload = b"short"
    header = frame_header(fin=True, opcode=OP_TEXT, length=len(payload), force_form="16")
    writer.write(header + payload)
    await writer.drain()
    log.info("%s: sent %d-byte Text frame using the 16-bit length form (non-minimal)", peer, len(payload))
    await hold(writer)


async def attack_ping_flood(reader, writer, peer) -> None:
    """A burst of Ping control frames in rapid succession. The client must
    auto-Pong each one without unbounded growth (control frames are handled
    inline, never handed to `on_message` or buffered as a message)."""
    n = 2000
    for i in range(n):
        payload = f"ping{i}".encode("ascii")[:125]  # control frames cap at 125 bytes
        header = frame_header(fin=True, opcode=OP_PING, length=len(payload))
        writer.write(header + payload)
        if i % 64 == 0:
            await writer.drain()  # periodic backpressure check, not per-frame
    await writer.drain()
    log.info("%s: sent %d rapid Ping frames", peer, n)
    await hold(writer)


async def attack_slow_body(reader, writer, peer) -> None:
    """A valid Text frame whose header announces the full length up front,
    but whose payload bytes are dribbled one at a time with a delay between
    each. Exercises the client's partial-read/`Need_More` path in
    `decoder_feed`/`parse_header` rather than any rejection — the message
    should ultimately be delivered intact."""
    payload = b"slow and steady payload, delivered byte by byte"
    header = frame_header(fin=True, opcode=OP_TEXT, length=len(payload))
    writer.write(header)
    await writer.drain()
    for b in payload:
        writer.write(bytes([b]))
        await writer.drain()
        await asyncio.sleep(0.02)
    log.info("%s: dribbled a %d-byte Text frame body one byte at a time", peer, len(payload))
    await hold(writer)


async def attack_abrupt_close(reader, writer, peer) -> None:
    """One valid Text frame, then the TCP connection is torn down with no
    Close frame at all. The client should surface this as
    `.Abnormal_Closure` (README: "a dropped TCP connection surfaces as
    `.Abnormal_Closure`"), not hang or misreport a clean close."""
    payload = b"one last message before the rug pull"
    header = frame_header(fin=True, opcode=OP_TEXT, length=len(payload))
    writer.write(header + payload)
    await writer.drain()
    log.info("%s: sent one valid Text frame, now dropping TCP with no Close frame", peer)
    # transport.abort() tears the connection down immediately (RST-ish) rather
    # than performing an orderly FIN handshake — no Close frame will ever be
    # written to the wire.
    writer.transport.abort()


async def attack_drip_handshake(reader, writer, peer) -> None:
    """Never completes the handshake. Drains whatever the client sent (its
    GET upgrade request) without needing to parse it, then dribbles a status
    line plus endless header-shaped filler that never reaches a `\\r\\n\\r\\n`
    terminator. `parse_upgrade_response` returns `.Need_More` forever, so
    this exercises both `MAX_HANDSHAKE_RESPONSE_BYTES` (64 KiB, client.odin)
    once the accumulated bytes cross the cap, and the per-read
    `handshake_timeout` if we stall instead."""
    try:
        await asyncio.wait_for(reader.read(MAX_HANDSHAKE_REQUEST_BYTES), timeout=2.0)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError):
        pass

    total = 0
    limit = 80 * 1024  # comfortably past the 64 KiB client-side cap
    filler = b"X-Filler: " + b"a" * 54 + b"\r\n"  # header-shaped, never the blank line

    try:
        status_line = b"HTTP/1.1 101 Switching Protocols\r\n"
        writer.write(status_line)
        await writer.drain()
        total += len(status_line)

        while total < limit:
            writer.write(filler)
            await writer.drain()
            total += len(filler)
            await asyncio.sleep(0.01)

        log.info("%s: dribbled %d handshake-response bytes with no terminator (past 64 KiB cap)", peer, total)
    except (ConnectionResetError, BrokenPipeError):
        log.info("%s: client disconnected mid-drip at %d bytes (expected once it gives up)", peer, total)
        return

    await hold(writer, seconds=1.0)


ATTACK_HANDLERS = {
    "oversize_frame": attack_oversize_frame,
    "oversize_message": attack_oversize_message,
    "bad_opcode": attack_bad_opcode,
    "rsv_bits": attack_rsv_bits,
    "masked_server": attack_masked_server,
    "bad_close_code": attack_bad_close_code,
    "bad_utf8_text": attack_bad_utf8_text,
    "bad_utf8_close_reason": attack_bad_utf8_close_reason,
    "non_minimal_len": attack_non_minimal_len,
    "ping_flood": attack_ping_flood,
    "slow_body": attack_slow_body,
    "abrupt_close": attack_abrupt_close,
    # drip_handshake is dispatched separately in handle_connection: it skips
    # the normal handshake entirely, so it does not belong in this table.
}


# ---------------------------------------------------------------------------
# Connection plumbing
# ---------------------------------------------------------------------------


def make_handler(attack: str):
    async def handle_connection(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        log.info("%s: accepted, attack=%s", peer, attack)

        try:
            if attack == "drip_handshake":
                await attack_drip_handshake(reader, writer, peer)
            else:
                request = await read_handshake_request(reader)
                key = parse_request_key(request)
                if key is None:
                    log.warning("%s: no Sec-WebSocket-Key in request, dropping", peer)
                    return

                await send_handshake_ok(writer, key)
                log.info("%s: handshake OK, running attack", peer)
                await ATTACK_HANDLERS[attack](reader, writer, peer)

        except asyncio.TimeoutError:
            log.info("%s: timed out waiting for handshake request", peer)
        except asyncio.IncompleteReadError:
            log.info("%s: connection closed before handshake completed", peer)
        except (ConnectionResetError, BrokenPipeError):
            log.info("%s: client disconnected mid-attack", peer)
        except Exception as exc:  # keep one bad connection from taking the server down
            log.exception("%s: unexpected error: %r", peer, exc)
        finally:
            try:
                if not writer.is_closing():
                    writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    return handle_connection


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Adversarial raw-TCP WebSocket server for break-it testing.")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8766)
    p.add_argument("--attack", required=True, choices=sorted(list(ATTACK_HANDLERS) + ["drip_handshake"]))
    p.add_argument("--quiet", action="store_true", help="suppress per-connection logging on stderr")
    return p.parse_args()


async def run(args: argparse.Namespace) -> None:
    handler = make_handler(args.attack)
    server = await asyncio.start_server(handler, args.host, args.port)
    addrs = ", ".join(str(sock.getsockname()) for sock in server.sockets)
    log.info("listening on %s (attack=%s)", addrs, args.attack)

    async with server:
        await server.serve_forever()


def main() -> None:
    args = parse_args()

    logging.basicConfig(
        stream=sys.stderr,
        level=logging.CRITICAL if args.quiet else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
