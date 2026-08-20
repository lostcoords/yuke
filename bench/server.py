#!/usr/bin/env python3
"""bench/server.py — clean WebSocket benchmark server for the Odin `libs:websocket`
client harness. See bench/SPEC.md for the shared contract this must honor.

Uses the `websockets` library (v16 asyncio API: `websockets.asyncio.server.serve`
with a single-argument connection handler). Two modes:

  echo  — echo every inbound text/binary message back unchanged, as fast as
          possible. Must survive thousands of short sequential connections
          (the client's soak test) without leaking memory or slowing down.
  flood — on connect, send --flood-count messages of --flood-size bytes as
          fast as the socket accepts backpressure for, then idle until the
          client disconnects. Exercises the client's inbound throughput and
          message-reassembly path.

Listens on ws://<host>:<port>/ per SPEC.md (default 127.0.0.1:8765).
"""

import argparse
import asyncio
import itertools
import logging
import sys

import websockets
from websockets.asyncio.server import ServerConnection, serve

# Monotonically increasing id for correlating log lines with connections;
# cheaper and more readable than the (host, port) tuple for a soak test that
# opens thousands of short-lived sockets.
_connection_ids = itertools.count(1)

log = logging.getLogger("bench.server")


async def handle_echo(ws: ServerConnection, conn_id: int) -> None:
    """Echo every inbound message back unchanged, unmodified in kind (text stays
    text, binary stays binary) since `send` mirrors the type of what `recv`
    handed us."""
    count = 0
    nbytes = 0

    async for message in ws:
        # `message` is `str` for a text frame, `bytes` for binary; `send`
        # re-encodes the same frame type, so this is a byte-exact echo.
        await ws.send(message)
        count += 1
        nbytes += len(message)

    log.info("conn %d: echo closed after %d messages, %d bytes", conn_id, count, nbytes)


async def handle_flood(ws: ServerConnection, conn_id: int, flood_count: int, flood_size: int) -> None:
    """Push `flood_count` text messages of `flood_size` bytes as fast as the
    transport accepts them, then hold the connection open idle so the client
    can keep draining/close on its own schedule.

    `await ws.send(...)` already respects the library's internal write-buffer
    backpressure (bounded by `write_limit`), so no extra throttling is needed
    here beyond awaiting each send.
    """
    payload = "x" * flood_size

    sent = 0
    try:
        for _ in range(flood_count):
            await ws.send(payload)
            sent += 1
    except websockets.ConnectionClosed:
        log.info("conn %d: flood interrupted by client after %d/%d messages", conn_id, sent, flood_count)
        return

    log.info("conn %d: flood sent %d messages (%d bytes each), idling", conn_id, sent, flood_size)

    # Idle until the client closes; `ws.wait_closed()` just parks this
    # coroutine on the connection's close event without polling.
    await ws.wait_closed()


def make_handler(mode: str, flood_count: int, flood_size: int):
    async def handler(ws: ServerConnection) -> None:
        conn_id = next(_connection_ids)
        peer = ws.remote_address
        log.info("conn %d: accepted from %s (mode=%s)", conn_id, peer, mode)

        try:
            if mode == "echo":
                await handle_echo(ws, conn_id)
            else:
                await handle_flood(ws, conn_id, flood_count, flood_size)
        except websockets.ConnectionClosedOK:
            log.info("conn %d: closed cleanly", conn_id)
        except websockets.ConnectionClosedError as exc:
            # Abrupt disconnects (client soak test, dropped TCP) are expected
            # traffic for this harness, not a server bug — log tersely and
            # move on instead of letting asyncio print a traceback.
            log.info("conn %d: closed abnormally (%s)", conn_id, exc)
        except Exception:
            log.exception("conn %d: handler failed", conn_id)

    return handler


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Clean echo/flood WebSocket benchmark server.")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--mode", choices=["echo", "flood"], default="echo")
    p.add_argument("--flood-count", type=int, default=100_000, help="messages to send per connection in flood mode")
    p.add_argument("--flood-size", type=int, default=256, help="bytes per flood message")
    p.add_argument("--quiet", action="store_true", help="suppress per-connection logging on stderr")
    return p.parse_args()


async def run(args: argparse.Namespace) -> None:
    handler = make_handler(args.mode, args.flood_count, args.flood_size)

    async with serve(handler, args.host, args.port) as server:
        log.info("listening on ws://%s:%d/ (mode=%s)", args.host, args.port, args.mode)
        await server.serve_forever()


def main() -> None:
    args = parse_args()

    # Everything goes to stderr so the Odin client's own benchmark output
    # (throughput, timing) stays readable on stdout when both run together.
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
