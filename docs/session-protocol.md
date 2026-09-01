# Session protocol — streams inside one connection

Status: proposal.
Source of truth: this document until `lib/wire/` and `lib/session/` implement it.
Last verified: 2026-08-31.

The layer between the WebSocket and the wire JSON-RPC. It carries the control stream, interactive
terminals, and blob transfers over one connection, in one framing, on both the local and the relay
path.

The relay never sees this layer. Remotely it travels inside the Noise ciphertext, so the relay
forwards it as opaque bytes.

## 1. Why one framing

SSH already proved this shape. RFC 4254 multiplexes shells, forwarded connections and file
transfer into one encrypted tunnel, with a credit window per channel. This document follows that
design, and departs from it only where a decision is written down below.

The alternative was a second socket per blob transfer (`/aux`). It cost about seven round trips
before the first byte, a second Noise session, and a second byte-stream implementation in the
daemon. It is deleted.

## 2. Decisions (locked)

| Area | Decision | Why |
|---|---|---|
| Local and relay framing | **The same** | The daemon holds one reader, one writer, one flow controller. This is the largest saving in the Zig port. Local frames stop being readable in devtools; that is the price. |
| Stream open | **No handshake frame** | JSON-RPC already answers requests. `terminal.open` and `blob.read` return a stream id. A second control plane inside the protocol is not needed. |
| Blob transport | **A stream** | `PUT`/`GET` over HTTP stays local-only and is not built. The relay stops needing to know what a blob is. |
| `max_blob_bytes` | **64 MiB, daemon only** | `lib/wire/meta.zig` already says 64 MiB. The relay no longer caps blobs, so `OperationalLimits.max_blob_bytes` is removed rather than reconciled. |
| Priority | **Two classes, no tree** | HTTP/2 shipped a priority dependency tree in RFC 7540 and deprecated it in RFC 9113 because nobody implemented it usefully. |
| Flow control | **A credit window on every stream** | Uniform, so one code path. |

## 3. Frame

Every frame is six header bytes and a payload. Several frames may pack into one WebSocket message
or one Noise packet, so a keystroke costs seven bytes rather than a packet.

```
byte 0..1   stream id   u16 big-endian
byte 2      type        u8
byte 3      flags       u8
byte 4..5   length      u16 big-endian, payload bytes
byte 6..    payload
```

| Type | Value | Payload |
|---|---|---|
| `DATA` | `0x01` | stream bytes |
| `WINDOW` | `0x02` | `u32` big-endian credit, in payload bytes |
| `RESET` | `0x03` | `u16` big-endian reason code |

| Flag | Bit | Meaning |
|---|---|---|
| `FIN` | `0` | The last `DATA` in this direction. The sender half-closes. |
| `MSG` | `1` | The last `DATA` of one application message. Used by the control stream. |

A frame never spans a Noise packet. A large message becomes several `DATA` frames, and the last
carries `MSG`. This replaces the `FIRST`/`LAST` chunk header in the SDK's `fragment.ts`.

`max_stream_frame_bytes` is 32768. Two frames then fit one Noise packet with room to spare, and a
terminal frame waits behind at most 32 KiB of a blob.

## 4. Streams

Stream `0` is the control stream. It carries the wire JSON-RPC exactly as today, as UTF-8 in `DATA`
payloads, with `MSG` marking each message boundary. It never closes.

Every other stream carries raw bytes and has no message boundaries. A client allocates odd ids and
a daemon allocates even ids, so neither side negotiates and the two spaces cannot collide.

A stream ends when both directions have sent `FIN`, or at once when either side sends `RESET`. A
`RESET` abandons the stream and any credit on it.

`max_streams` is 64 per connection, which with the initial window bounds receive buffering.

### Stream kinds

A stream's kind is fixed when the control stream opens it. The kind decides its scheduling class and
nothing else on the wire, so a new kind never changes the framing.

| Kind | Direction | Class | Payload |
|---|---|---|---|
| control | both | interactive | wire JSON-RPC, UTF-8, `MSG` per message |
| terminal | both | interactive | raw PTY bytes |
| blob | mostly one way | bulk | raw blob bytes |
| screen frames | daemon → client | bulk | one encoded image per message, `MSG` per frame |
| screen input | client → daemon | interactive | one input event per message, `MSG` per event |

**A screen session uses two streams, not one.** Its directions belong to different classes: frames
are bulk and input is interactive, and a class applies to a whole stream. Splitting them is what
keeps a click from queueing behind a screen frame.

Frames carry the image as raw bytes. A daemon that reads them from a source encoding them in base64,
as the Chrome DevTools Protocol does, decodes first. This protocol is binary, and base64 inside it
would cost a third of the bandwidth for nothing.

**Frame credit is the frame acknowledgement.** A screencast source that waits for an ack before it
renders the next frame — again, as CDP does — is acked when the viewer consumes the frame, never
when it arrives. A slow viewer then lowers its own frame rate instead of growing a queue, which is
the same rule §5 states for every stream. The two mechanisms compose with no adapter between them.

## 5. Flow control

Each direction of each stream has a credit window, counted in `DATA` payload bytes. A sender may
write only while it holds credit. A receiver sends `WINDOW` as it consumes.

The initial window is 64 KiB. A receiver may grant far more on a bulk stream; the initial value is
a starting credit, not a ceiling. A high-latency link needs a large window to fill, so a blob
receiver should grant aggressively.

Three invariants prevent the deadlocks that HTTP/2 implementations have shipped:

1. **A reader always drains and processes frames.** Application handling never blocks frame
   processing. curl and Go's `x/net/http2` both stalled unrelated streams by breaking this.
2. **`WINDOW` and `RESET` are never flow-controlled**, and never queue behind `DATA`. A window
   update that cannot travel is a deadlock.
3. **Priority is scheduling only.** A receiver must never withhold a window to make another stream
   go faster. That is a documented deadlock, and it is why §6 is separate from this section.

## 6. Scheduling

Two classes. **Interactive** is stream `0` and every terminal stream. **Bulk** is every blob
stream. A writer drains interactive first and gives the rest to bulk. Within a class it round-robins.

**A writer must stop at the link's high-water mark.** A writer that drains every ready stream
straight into the socket never holds a queue, and a scheduler with no queue to arbitrate does
nothing at all. The bulk stream simply wins by arriving first. So a writer sends only while the
link wants more bytes, and resumes when it drains. This is a protocol requirement, not a browser
detail; §8 is the browser's version of the same rule.

This is what one socket buys over two: with separate connections, TCP splits the bandwidth and the
endpoint cannot change that. Here the terminal wins by construction.

## 6.1 What an endpoint must do

Three rules a terminal found. Each was a silent failure, not an error, so none of them would have
surfaced from reading the protocol.

1. **Bound your own write queue.** The credit window bounds what a peer buffers. Nothing bounds what
   you queue for it. A host reading a fast source — a shell printing megabytes — must pause that
   source at a high-water mark and resume when the queue drains, or it converts a slow reader into
   unbounded memory on its own side.
2. **Hold data that arrives before a handler exists.** A peer writes as soon as it is spliced, and a
   process writes without being asked: a shell prints its prompt immediately. A stream that delivers
   only to an attached handler loses those bytes with no error. Hold them until a handler attaches;
   the credit window already bounds how many there can be.
3. **End a stream when its source ends, not when its process exits.** A PTY delivers buffered output
   after the child is gone. Ending on exit truncates the tail, and the late write then fails.

## 7. Transport

Locally, one WebSocket binary message carries one or more frames. There is no envelope tag and no
Noise.

Remotely, the frames are the Noise plaintext. The ciphertext is the payload of a `SEALED` envelope
frame, which is one binary WebSocket message to the relay. See `../yuke-relay/docs/protocol.md`.

Text WebSocket messages are a protocol error on both paths.

## 8. The browser send path

The standard WebSocket API applies no backpressure. `bufferedAmount` is a poll, not a mechanism,
and a large upload through it can exhaust memory or kill the tab. `WebSocketStream` solves it but
is non-standard and Chrome-only.

A browser client therefore gates every write twice: it must hold protocol credit **and** see a low
`bufferedAmount`. It uses `WebSocketStream` when the browser has it. This applies to any WebSocket,
so it was never an argument for a second socket.

`bufferedAmount` is also what answers §6's high-water mark in a browser. The two rules are one
mechanism: the writer stops, a queue forms, and the scheduler then has something to order.

## 9. Open

- **Capability.** A share is boolean today, and the daemon cannot map a Noise peer to a user, so it
  cannot tell one client from another. Terminal v1 is owner-only. Screen control and web preview
  must not ship on that: both drive software on the daemon's machine, already logged in. They need
  client-session static keys registered in the control plane first.
- **A browser for the agent.** Screen streams carry frames from a browser the daemon owns. The agent
  has `read`, `write`, `edit` and `exec` and no browser tool, so there is nothing to watch yet. That
  tool is a prerequisite, not part of this protocol.
- **Window tuning.** 64 KiB initial and 32 KiB frames are starting points. Measure a real link
  before fixing them.

## 10. Build order

The rule is that no Zig is written until the framing is proven somewhere cheaper.

1. **This document, and the wire additions.** `terminal.*` and `blob.*` methods in `lib/wire/`,
   which hand back stream ids. Type declarations only; no IO.
2. **`yuke-ts-sdk`.** Framing, windows and the scheduler. Then `sim.py`, so the smoke harness drives
   the same protocol through the real relay.
   **Done when three tests pass:** a terminal-rate stream beside a saturating blob stream, which is
   the exact case that deadlocked curl; a stalled reader that does not wedge other streams; and a
   browser-shaped send path gated on credit and `bufferedAmount`.
3. **Relay and cloud cleanup.** Delete `/aux`, the aux rendezvous, the `aux` ticket kind, and
   `OperationalLimits.max_blob_bytes`. Runs beside step 2.
4. **Zig.** Noise IK against Cacophony vectors, TLS and WebSocket client, the control link and
   dial-on-demand, then this framing as a sans-IO core. It passes the same tests step 2 passed.
5. **Terminal.** PTY, terminal streams, xterm.js.
6. **Blobs.** Blob streams, and the collector in `blob-gc-design.md`, which this change does not
   alter.
7. **Screen.** Frame and input streams, behind the browser tool and the capability work.

Steps 5 to 7 add stream kinds and wire methods. None of them changes the framing, the windows or the
scheduler, and none of them changes the relay or the control plane. That is the test of whether this
layer is drawn in the right place.
