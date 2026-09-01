# yuke — networking & relay plan (Zig port)

Status: proposal.
Source of truth: `lib/wire/`, `src/daemon/`, and the relay protocol decision.
Last verified: 2026-09-01.

The technical plan for the layers above `lib/wire/`: the local HTTP+WebSocket front door, the
outbound relay transport, and the end-to-end crypto. It is a port of the Odin stack on `main`, with
deliberate simplifications. The Odin code is the migration reference, not a spec to copy
byte-for-byte. No relay client or Noise implementation is in the Zig tree yet.

## 1. Decisions (locked)

| Area | Decision | Why |
|---|---|---|
| Reactor | **zio, single-threaded** (`executors = .exact(1)`) on Zig 0.16 `std.Io` | Direct replacement of Odin's single-thread `nbio`; no worker threads, so shared daemon state needs no locks. zio is a full `std.Io` implementation, so `std.http.Client`/`std.crypto.tls` compose unmodified. |
| Protocol logic | **sans-IO cores** (pure buffer, `Need_More`-style), driven by the one reactor | Same grain as the wire layer. Cores are testable without a socket and swappable under the reactor. |
| TLS | **`std.crypto.tls.Client` first**; vendor **`ianic/tls.zig`** only if it flakes on Cloudflare | Pure Zig, no C dep. The 2024 Cloudflare TLS bug is fixed. `ianic/tls.zig` is the ready fallback (Cloudflare-tested, 463/500 vs std 419/500 on top sites). |
| HTTPS client | **`std.http.Client` over zio** for control-plane calls | Replaces libcurl. Removes a C dependency and two Odin bugs (the `CLOSE_WAIT` leak and the curl idle-cache issue). |
| WebSocket | **Hand-roll** RFC 6455 framing (both roles) as a sans-IO core | No maintained *sans-IO* WS lib exists; every option owns its own IO loop and fights the reactor. `std.http.Client` does not do WS upgrade. Reference karlseguin/websocket.zig for masking/close-code correctness. |
| Noise | **Hand-roll IK on `std.crypto`**, port `main:src/relay/noise.odin` | X25519 + AES-256-GCM + SHA-256 + HKDF are all in std 0.16. No 0.16 Noise lib exists. Validate against Cacophony IK test vectors. |
| Identity | **Tailscale-shaped**: keep device-code enrollment, the roster, and tickets | The roster is the out-of-band key-distribution channel; it removes the first-contact TOFU risk. Device-key vs session-key split is legitimate here. |
| Relay multiplexing | **Control link + dial on demand** (one WebSocket + one Noise session per client) | BUILT. The daemon parks one control link; the relay pushes `CONTROL dial{pair}` and the daemon dials `/link?pair=`. Per-client isolation, no cross-client head-of-line blocking, and no pool to size. `../yuke-relay/docs/protocol.md` is authoritative. |

## 2. Architecture

### 2.1 Local path (client ↔ daemon)

```
zio stream → WebSocket (ws://, our sans-IO framing) → wire JSON-RPC
```

The front door binds loopback. It parses the request head, runs the middleware chain
(mark-private → admit → auth), then routes. `/ws` upgrades and hands the socket to the WS server
core. `/identity` is plain HTTP. Blob data uses mux streams; HTTP PUT/GET blob transport is not
built, and `max_blob_bytes` stays a daemon-only 64 MiB limit. No TLS locally; a proxy terminates TLS if a remote
non-relay client ever needs it. No SSE on the front door — SSE is only for upstream LLM streams, a
separate concern in `src/provider/`.

### 2.2 Remote path (client ↔ relay ↔ daemon)

```
                         relay.yuke.sh (Cloudflare orange-cloud, Helsinki)
                         WSS /link (control + data)   WSS /connect (client)
                                  |                        |
   +------------------------------+--+                  +--+------------------------+
   |            DAEMON               |                  |          CLIENT           |
   |  parks ONE control link,        |                  |  dials /connect, initiator|
   |  dials one data link per client |<== Noise IK ====>|  pins daemon static key   |
   |  one Noise responder / data link|  (relay is a     |  from the roster          |
   +---------------------------------+   dumb pipe)     +---------------------------+

   per data link:  zio stream → std.crypto.tls.Client → WebSocket → Noise IK → wire JSON-RPC
```

The remote path is six layers — `TCP → TLS → WS → Noise → mux → wire` — versus Odin's seven. The mux
is `docs/session-protocol.md`; the local path is the same minus Noise. The
envelope tag survives; the CONTROL channel shrank to one message, and the routing byte and the
shared per-channel arenas are gone.

## 3. The relay protocol (BUILT — see `../yuke-relay/docs/protocol.md`)

That document is authoritative; this is the daemon's half of it.

**Daemon side:**
1. Fetch a link ticket (`POST /api/v1/link_tickets`, device bearer).
2. Dial `wss://relay/link?ticket=…`. This is the device's ONE control link. Keepalive it (~25 s
   ping). Send nothing on it: the relay treats any frame as a protocol error.
3. On `CONTROL {"type":"dial","pair":N}`, dial `wss://relay/link?pair=N`. That data link needs no
   ticket and no control-plane call.
4. Run the Noise responder on the data link. Its close is the detach signal.

**Client side:** unchanged — fetch a connect ticket, dial `wss://relay/connect?ticket=…`, run Noise
IK as initiator, pin the daemon static key from the roster.

**Ticket issuance is resolved.** The relay mints the pair nonce itself, so issuance stays at one
ticket per park and one per client however many clients a device serves. No parking grant, no
batch tickets, no extra round trips — the open question this section used to carry is closed.

## 4. Layer inventory (what to build)

### 4.1 sans-IO cores — hand-rolled, pure buffer, tested first

- **WebSocket framing** (`main:libs/websocket/{frame,decoder,handshake}.odin`)
  - Frame codec, both roles: RFC 6455 §5 header parse/encode, direction-strict masking (client
    masks, server rejects unmasked with a protocol error).
  - Streaming decoder: reassemble fragmented data frames (FIN + continuation), control frames whole,
    enforce a max message size.
  - Upgrade handshake, both directions: `Sec-WebSocket-Key`/`-Accept` (SHA-1 + base64, both in std),
    request/response build+parse.
  - Ping/pong (auto-pong), close codes + reason, close handshake with a deadline.
- **HTTP head + router** (`main:libs/http/{head,request}.odin`, `server/router.odin`)
  - Request head parse + target/field validation. Consider `std.http.Server.receiveHead` for the
    parse; our tiny static-dispatch router on top (exact match + one `/*` capture).
  - Middleware chain: mark-private → admit (DNS-rebinding / Origin check) → auth (bearer / `?token`).
    Order is load-bearing: route/method existence is disclosed only after auth.
- **Noise IK** (`main:src/relay/noise.odin`) — see §5.

The wire codec (`lib/wire/`) is done.

### 4.2 reactor integration — zio + std.Io

- **Event loop** — one `zio.Runtime` (`.exact(1)`), an `Io.Group`, one `group.concurrent` task per
  long-lived job (front door accept loop, each connection, the relay pool manager, keepalive
  timers). `group.cancel(io)` for shutdown; each blocking call returns `error.Canceled`.
- **Front door server** (`main:libs/http/server/server.odin`, `src/daemon/front_door.odin`) —
  accept, head parse, middleware, route, `/ws` upgrade (hijack the stream, hand to the WS server
  core), `/blob` streaming with digest verify.
- **Outbound relay client** (`main:src/daemon/relay.odin`, `src/client/relay.odin`) — zio stream →
  `std.crypto.tls.Client` → WS client core → park; the Noise session over it; keepalive and
  full-jitter backoff.
- **Relay pool manager (model B)** — hold N warm `/link` sockets, replenish on pairing, per §3.
- **Control-plane client** (`main:src/relay/control_plane.odin`) — `std.http.Client` over zio:
  device-code enrollment, roster, link/connect tickets. The Odin codec is pure and ports directly;
  the transport is new. Replaces libcurl.

### 4.3 the zio daemon loop (verified shape)

```zig
const std = @import("std");
const zio = @import("zio");
const Io = std.Io;

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{}); // .{} == exact(1), single-threaded
    defer rt.deinit();
    const io = rt.io();

    var group: Io.Group = .init;
    defer group.cancel(io); // shutdown cancels every child task

    // Several long-lived jobs, all concurrent on ONE thread:
    try group.concurrent(io, frontDoor,   .{ io, &group });
    try group.concurrent(io, relayPool,   .{ io });        // parks the /link spares (model B)
    try group.concurrent(io, keepalive,   .{ io });
    try group.await(io);
}
```

The local daemon uses zio through its `std.Io` implementation in `src/daemon/http.zig`. Keep the
same `std.Io` boundary when the relay pool lands.

Notes from the zio/std.Io verification:
- Use `group.concurrent` (not `group.async`) for long-lived jobs — `concurrent` guarantees an
  independent scheduling unit; `async` may run inline.
- `rt.io()` returns the real `std.Io.VTable`, so `std.http.Client{ .io = io, ... }` and
  `std.crypto.tls.Client.init(reader, writer, ...)` run unmodified.
- Single-thread guarantee holds only at `.exact(1)`. Never switch to `.auto` without adding locks.
- A few zio vtable slots `@panic` (mmap files, `processExecutableOpen`, `netWriteFile`) or fall back
  to a blocking `Threaded` (`processSpawn`). None are on the daemon hot path.

**wss upgrade (no std helper):** `std.http.Client` does *not* do WebSocket upgrade. The parked leg
is: `Io.net.IpAddress.connect` → buffered `stream.reader/writer` → `std.crypto.tls.Client.init` over
those → write the RFC 6455 `GET ... Upgrade: websocket` handshake, read the 101, then our WS framing
over the TLS reader/writer. Cancellation via the enclosing `Io.Group` unblocks a parked read.

## 5. Noise IK — implementation map

Pattern `Noise_IK_25519_AESGCM_SHA256`, prologue `"yuke-relay v1"` (match both ends exactly).
`../yuke-cloud/docs/security.md` is authoritative for the suite. The browser client runs Noise on
WebCrypto, which has X25519, AES-GCM, SHA-256 and HKDF but no ChaChaPoly.
Client = initiator (pins daemon static key), daemon = responder. msg1 payload is empty (IK's first
message is replay/KCI-weak); real frames start after the split.

Three types: `CipherState { k, n }`, `SymmetricState { cs, ck, h }`, `HandshakeState`. Build the
12-byte AEAD nonce as **4 zero bytes ‖ BE64(n)**. Error at `n == 2^64-1`; never wrap.
AESGCM is big-endian here; ChaChaPoly is little-endian. A port from the ChaChaPoly form breaks interop.

| Noise op | Zig std.crypto call |
|---|---|
| `GENERATE_KEYPAIR` | `X25519.KeyPair.generate(io)` / `.generateDeterministic(seed)` |
| `DH` (es/ee/se/ss) | `X25519.scalarmult(secret, public)` → handle `IdentityElementError` (peer input → error, not assert) |
| `ENCRYPT` | `Aes256Gcm.encrypt(ct, &tag, pt, ad, nonce12, k)` |
| `DECRYPT` | `Aes256Gcm.decrypt(pt, ct, tag, ad, nonce12, k)` → `AuthenticationError` |
| MixHash | `Sha256.hash(h ‖ data, &out, .{})` |
| MixKey / Split `HKDF(ck, ikm, n)` | `HkdfSha256.extract(ck, ikm)` then `HkdfSha256.expand(out, "", prk)` (info MUST be empty) |
| REKEY | `Aes256Gcm.encrypt` with nonce `2^64-1`, empty ad, 32 zero bytes; take first 32 |
| wipe secrets | Do not. yuke removed secret wiping on purpose; the boundary controls stay. |

Footguns: MixHash the prologue even when empty; transport AEAD uses **empty AD** (not the running
`h`); `ck` starts equal to `h` then diverges after the first MixKey; split direction — initiator
sends with `cs[0]`, responder with `cs[1]`; `"Noise_IK_25519_AESGCM_SHA256"` is 28
bytes, so `h` is the name zero-padded to 32, not hashed. The ChaChaPoly name was exactly 32 and
needed no padding; do not carry that assumption over. Validate byte-exactly against Cacophony IK
vectors; cross-check HKDF/nonce details against `mcginty/snow` and `flynn/noise`.

## 6. Simplifications vs Odin

| Change | Verdict | Coordination |
|---|---|---|
| One data link + one Noise session per client; delete the routing byte and the per-channel arenas | **DONE** | `../yuke-relay`, shipped |
| Drop libcurl → `std.http.Client` + `std.crypto.tls` | **DELETE dependency** | Local |
| `max_stream_frame_bytes` locked at 32768; mux DATA frames carry terminal and blob streams | **LOCKED** (deletes the chunker) | `docs/session-protocol.md` |
| Full-jitter exponential backoff on reconnect | **IMPROVE** | Local |
| Anti-replay in Noise msg1 (monotonic timestamp, WireGuard-style); optional peer-key gate | **IMPROVE** | Local (both ends) |
| Session resumable across transport loss (stable session id, reattach) | **IMPROVE** | Reconcile with the wire `session.resync` path |
| Close the front-door `origin_allowed` @Todo (require pairing) | **IMPROVE** | Local |
| Identity: keep enrollment + roster + tickets (Tailscale-shaped) | **KEEP** | `../yuke-cloud`; possibly fold link+connect into one ticket type |

## 7. Vendor policy

Vendor almost nothing. Everything below is std or hand-rolled; the one candidate to copy in is a TLS
fallback.

- **`ianic/tls.zig`** — VENDOR *only if* `std.crypto.tls.Client` proves unreliable against
  Cloudflare. MIT, pure Zig, tracks Zig master. The single defensible dependency.
- std: `std.crypto` (X25519, Aes256Gcm, Sha256, Hkdf), `std.crypto.tls.Client`,
  `std.http.Client`, `std.http.Server.receiveHead`, `std.base64`, `std.fmt` hex, `std.Uri`,
  `std.heap` arena/pool.
- Hand-roll: WS framing, HTTP router, Noise IK, the mux, the relay pool, blob hashing (sha256+hex
  over a consumed stream).
- Reference-only (do not depend): karlseguin/websocket.zig (owns its IO), spiral-ladder/noiz (0.14,
  unaudited), nikneym/ws (stale).

## 8. Open decisions

- **Max inline frame size. DECIDED.** `docs/session-protocol.md` locks `max_stream_frame_bytes` at
  32768. A large message becomes several mux DATA frames and the last carries `MSG`, so no chunker
  and no blob round-trip is needed. The relay does not enforce the daemon's 64 MiB blob limit.
- **First-connect latency.** A client waits one daemon dial (TCP+TLS+WS, ~200–400 ms) because
  nothing is pre-parked. One warm spare would hide it; measure before adding one, since a pool
  brings back the sizing and burst problems this design removed.

## 9. Build order

1. **sans-IO cores + tests** — WS framing, HTTP head + router, Noise IK (Cacophony vectors). No IO.
2. **zio skeleton** — single-thread runtime, `Io.Group`, per-connection task, a keepalive timer.
3. **Local front door** — `ws://` only, no TLS, no relay. A local client talks to the daemon
   end-to-end. Mirrors Odin's dependency order and de-risks the WS + reactor seam early.
4. **Outbound wss** — TLS client + WS client core + park + keepalive + jittered backoff. Validate
   the TLS handshake against the real `relay.yuke.sh` early (the historical std-TLS risk).
5. **Control-plane client** — enrollment, roster, tickets over `std.http.Client`.
6. **Relay pool (model B)** — coordinate the `../yuke-relay` change (§3), then the daemon pool + the
   client initiator backend + Noise sessions.
7. **Integration** — front door + relay pool + providers on one loop.

## 10. Risks

- **zio churn.** `std.Io` is not frozen across Zig minors; zio tracks it per-branch. Pin Zig 0.16.0
  (done via `.mise.toml`) and pin a zio tag. A future std routing through a zio `@panic` slot would
  panic — none are on the daemon hot path today.
- **Single-thread discipline.** The no-lock guarantee holds only while `executors = .exact(1)`.
- **std TLS vs Cloudflare.** Validate early against `relay.yuke.sh`; keep `ianic/tls.zig` ready.
- **Packaging.** The daemon must survive user logout: launchd `KeepAlive` (macOS) / a systemd-user
  service with `enable-linger` (Linux). See `main:bugs/2026-08-16-relay-offline-*.md`.
- **Half-open sockets** after sleep/resume: rely on the app-level ping/pong (~25 s ping, ~10 s pong
  deadline), not TCP keepalive. Keepalive the idle pool spares too.
