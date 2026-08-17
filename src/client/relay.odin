// The relay (remote) Transport backend: the initiator half of the Noise IK session the
// daemon's relay bridge answers. It dials the relay's /connect route, runs the handshake
// pinned to the daemon's static key from the roster, then carries plaintext wire frames as
// SEALED frames — fragmenting on send, reassembling on receive — so the driver above never
// learns it is remote. Create with `relay_create`; `client_open` takes ownership and drives
// it through the same `Transport` ops the local WebSocket backend implements.
//
// It is the mirror of `src/daemon/relay.odin`, inverted to the initiator: this end pins the
// responder's static key and speaks msg1 first, where the daemon learns the peer key and
// replies. A sealed frame cannot be shed — its Noise nonce has advanced — so a post-seal
// send failure is fatal here too, and the connection fails rather than desyncing the cipher.
package client

import "core:crypto/ecdh"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:time"

import ws "libs:websocket"
import "src:relay"

// Client-initiated keepalive on the /connect link, mirroring the daemon's /link keepalive. A
// half-open socket left by suspend/resume surfaces as a transport error instead of a hung
// session; stays well under the proxy idle window (Cloudflare ~100s).
RELAY_KEEPALIVE_INTERVAL :: 25 * time.Second
RELAY_KEEPALIVE_PONG_DEADLINE :: 10 * time.Second

// Relay backend behind a `Transport`: one `/connect` link, the initiator Noise session, and
// the reassembler for inbound fragments. Heap-owned by `relay_create` so its address is
// stable for the link's owner back-reference; freed by `destroy`.
@(private = "file")
Relay_Backend :: struct {
    // The outbound /connect link. Dialed by `open`; `dialed` says whether it holds buffers.
    link:          relay.Link,
    dialed:        bool,

    // Borrowed event loop the link runs on.
    loop:          ^nbio.Event_Loop,

    // The relay endpoint and connect ticket, owned until destroy. `relay_url` backs the
    // endpoint `open` parses, so it must outlive the dial.
    relay_url:     string,
    ticket:        string,

    // Our own static identity and the pinned responder static, stored here so their
    // addresses stay stable across the handshake.
    static_key:    ecdh.Private_Key,
    remote_static: ecdh.Public_Key,

    // The Noise session and whether its handshake has split into transport keys.
    session:       relay.Session,
    established:   bool,

    // Reassembles a wire frame fragmented across several inbound SEALED frames.
    reasm:         relay.Reassembler,

    // Scratch for one inbound open/reassemble and one outbound seal, reset per frame.
    recv_scratch:  virtual.Arena,
    send_scratch:  virtual.Arena,

    // Backing allocator and the driver reported to; `client` is nil until `open`.
    allocator:     mem.Allocator,
    client:        ^Client,
}

// Build a relay backend behind a `Transport`, dialing only on `open`. `relay_url` is the
// connect ticket's `ws://`/`wss://` endpoint and `ticket` its opaque token, both cloned.
// `static_seed` is this device's 32-byte X25519 private key (from its identity) and
// `remote_static` the target daemon's 32-byte public key (pinned from the roster). On error
// there is no handle to destroy.
relay_create :: proc(
    loop: ^nbio.Event_Loop,
    relay_url: string,
    ticket: string,
    static_seed: []u8,
    remote_static: []u8,
    allocator := context.allocator,
) -> (
    Transport,
    ws.Client_Error,
) {
    assert(loop != nil, "relay_create needs an event loop")
    assert(len(static_seed) == relay.NOISE_STATIC_KEY_SIZE, "relay_create needs a 32-byte static key")
    assert(len(remote_static) == relay.NOISE_STATIC_KEY_SIZE, "relay_create needs a 32-byte pinned key")

    if _, ok := relay.endpoint_parse(relay_url); !ok {
        return {}, .Invalid_Options
    }

    backend, aerr := new(Relay_Backend, allocator)
    if aerr != nil {
        return {}, .Out_Of_Memory
    }

    backend.loop = loop
    backend.allocator = allocator

    // X25519 set_bytes only fails on a wrong length, guarded above.
    ok_static := ecdh.private_key_set_bytes(&backend.static_key, .X25519, static_seed)
    ok_remote := ecdh.public_key_set_bytes(&backend.remote_static, .X25519, remote_static)
    assert(ok_static && ok_remote, "relay_create keys failed on validated 32-byte inputs")

    if virtual.arena_init_growing(&backend.recv_scratch) != nil ||
       virtual.arena_init_growing(&backend.send_scratch) != nil {
        relay_free(backend)

        return {}, .Out_Of_Memory
    }

    relay.reassembler_init(&backend.reasm, allocator)

    clone_err: mem.Allocator_Error
    backend.relay_url, clone_err = strings.clone(relay_url, allocator)
    if clone_err == nil {
        backend.ticket, clone_err = strings.clone(ticket, allocator)
    }
    if clone_err != nil {
        relay_free(backend)

        return {}, .Out_Of_Memory
    }

    return Transport {
            self = backend,
            open = relay_open,
            send_text = relay_send_text,
            close = relay_close,
            cancel = relay_cancel,
            abort = relay_abort,
            destroy = relay_destroy,
        },
        .None
}

// Begin the initiator handshake and dial the relay. Success is async: the first SEALED reply
// completes the handshake and only then reports `transport_on_open`, so the driver's
// `initialize` rides the encrypted session, never the bare socket.
@(private = "file")
relay_open :: proc(t: Transport, c: ^Client) -> ws.Client_Error {
    assert(c != nil, "relay_open needs a client")

    backend := (^Relay_Backend)(t.self)
    assert(backend != nil, "relay_open needs a backend from a successful create")
    assert(backend.client == nil, "relay backend opened twice")

    backend.client = c

    endpoint, ok := relay.endpoint_parse(backend.relay_url)
    assert(ok, "relay url was validated in relay_create")

    relay.session_init_initiator(
        &backend.session,
        &backend.static_key,
        &backend.remote_static,
        transmute([]u8)string(relay.NOISE_PROLOGUE_V1),
    )

    callbacks := relay.Link_Callbacks {
        on_parked = relay_on_parked,
        on_sealed = relay_on_sealed,
        on_closed = relay_on_closed,
        on_error  = relay_on_error,
    }

    err := relay.link_dial(
        &backend.link,
        backend.loop,
        endpoint,
        .Connect,
        backend.ticket,
        callbacks,
        backend,
        backend.allocator,
        keepalive_interval = RELAY_KEEPALIVE_INTERVAL,
        keepalive_pong_deadline = RELAY_KEEPALIVE_PONG_DEADLINE,
    )
    if err != .None {
        return err
    }

    backend.dialed = true

    return .None
}

// Seal one plaintext wire frame and queue it on the link. A frame larger than one Noise
// packet rides several SEALED frames, each a chunk header then a slice of the plaintext;
// each is sealed before it is queued, so the Noise nonce advances per chunk. A sealed chunk
// cannot be dropped without desyncing the cipher, so any post-seal send failure is fatal.
@(private = "file")
relay_send_text :: proc(t: Transport, data: []byte) -> ws.Client_Error {
    backend := (^Relay_Backend)(t.self)
    assert(backend != nil, "relay_send_text needs a backend")
    assert(backend.established, "relay send before the handshake completed")
    assert(len(data) > 0, "relay send needs a non-empty frame")

    temp := virtual.arena_temp_begin(&backend.send_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&backend.send_scratch)

    count := relay.transport_chunk_count(len(data))

    for i in 0 ..< count {
        lo := i * relay.TRANSPORT_CHUNK_MAX
        hi := min(lo + relay.TRANSPORT_CHUNK_MAX, len(data))

        frame, serr := relay.transport_seal_chunk(&backend.session, data[lo:hi], i, count, scratch)
        if serr != .None {
            return relay_seal_error(serr)
        }

        // Not_Open means the link is already closing; its terminal fails the connection. Any
        // other failure is fatal: the chunk is sealed, so the nonce advanced, and unlike a
        // stateless frame a sealed one cannot be dropped without corrupting every later frame.
        // Report it so the connection fails rather than silently desyncing.
        if send_err := relay.link_send_binary(&backend.link, frame); send_err != .None {
            return send_err
        }
    }

    return .None
}

@(private = "file")
relay_close :: proc(t: Transport, code: Close_Code) -> ws.Client_Error {
    backend := (^Relay_Backend)(t.self)
    assert(backend != nil, "relay_close needs a backend")

    return relay.link_close(&backend.link, ws.Close_Code(code))
}

@(private = "file")
relay_cancel :: proc(t: Transport) {
    backend := (^Relay_Backend)(t.self)
    assert(backend != nil, "relay_cancel needs a backend")

    relay.link_cancel(&backend.link)
}

@(private = "file")
relay_abort :: proc(t: Transport, err: ws.Client_Error) {
    backend := (^Relay_Backend)(t.self)
    assert(backend != nil, "relay_abort needs a backend")
    assert(err != .None && err != .Not_Open, "relay_abort needs a terminal error")

    relay.link_abort(&backend.link, err)
}

// Release the backend, wiping the Noise session and static key. Safe after a failed `open`
// (nothing dialed) or once the link has closed.
@(private = "file")
relay_destroy :: proc(t: Transport) {
    backend := (^Relay_Backend)(t.self)
    assert(backend != nil, "relay_destroy needs a backend from a successful create")

    if backend.dialed {
        relay.link_destroy(&backend.link)
    }

    relay_free(backend)
}

// Free a backend whose link was never dialed (or already destroyed): the session, reassembler,
// scratch, key material, and owned strings. `relay_destroy` handles the link separately.
@(private = "file")
relay_free :: proc(backend: ^Relay_Backend) {
    relay.session_destroy(&backend.session)
    relay.reassembler_destroy(&backend.reasm)
    ecdh.private_key_clear(&backend.static_key)
    virtual.arena_destroy(&backend.recv_scratch)
    virtual.arena_destroy(&backend.send_scratch)
    delete(backend.relay_url, backend.allocator)
    delete(backend.ticket, backend.allocator)
    free(backend, backend.allocator)
}

// Recover the backend from a link callback's owner pointer.
@(private = "file")
relay_of :: proc(l: ^relay.Link) -> ^Relay_Backend {
    backend := (^Relay_Backend)(l.user_data)
    assert(backend != nil, "relay link lost its backend")
    assert(&backend.link == l, "relay callback crossed backend ownership")

    return backend
}

// The /connect link is spliced onto the parked daemon the moment it opens: send the
// initiator's first handshake message (empty payload) as the first SEALED frame.
@(private = "file")
relay_on_parked :: proc(l: ^relay.Link) {
    backend := relay_of(l)

    temp := virtual.arena_temp_begin(&backend.send_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&backend.send_scratch)

    msg1, err := relay.session_initiate(&backend.session, scratch)
    if err != .None {
        log.errorf("client: relay handshake could not start: %v", err)
        _ = relay.link_close(l, .Protocol_Error)

        return
    }

    frame := relay.frame_encode(relay.Frame{type = .Sealed, payload = msg1}, scratch)
    if send_err := relay.link_send_binary(l, frame); send_err != .None {
        log.errorf("client: relay handshake send failed: %v", send_err)
        _ = relay.link_close(l)
    }
}

// One SEALED payload from the daemon. Before the handshake completes it is the responder's
// reply: complete and split, then report the transport open so the driver sends `initialize`.
// After, it is a transport frame: open it, reassemble, and hand a whole wire frame up.
@(private = "file")
relay_on_sealed :: proc(l: ^relay.Link, payload: []u8) {
    backend := relay_of(l)

    temp := virtual.arena_temp_begin(&backend.recv_scratch)
    defer virtual.arena_temp_end(temp)
    scratch := virtual.arena_allocator(&backend.recv_scratch)

    if !backend.established {
        if err := relay.session_complete(&backend.session, payload, scratch); err != .None {
            log.errorf("client: relay handshake rejected: %v", err)
            _ = relay.link_close(l, .Protocol_Error)

            return
        }

        backend.established = true
        transport_on_open(backend.client)

        return
    }

    frame, done, ok := relay.transport_open_fragment(&backend.session, &backend.reasm, payload, scratch)
    if !ok {
        log.error("client: relay frame rejected")
        _ = relay.link_close(l, .Protocol_Error)

        return
    }

    if !done {
        return
    }

    transport_on_text(backend.client, frame)
    relay.reassembler_reset(&backend.reasm)
}

@(private = "file")
relay_on_closed :: proc(l: ^relay.Link, code: ws.Close_Code) {
    backend := relay_of(l)
    transport_on_close(backend.client, Close_Code(code))
}

@(private = "file")
relay_on_error :: proc(l: ^relay.Link, err: ws.Client_Error) {
    backend := relay_of(l)
    transport_on_error(backend.client, err)
}

// Map a Noise seal failure onto the transport error the driver speaks. A frame past the
// packet limit is a message-too-large; the rest are generic send failures.
@(private = "file")
relay_seal_error :: proc(err: relay.Noise_Error) -> ws.Client_Error {
    #partial switch err {
    case .Frame_Too_Large:
        return .Message_Too_Large
    }

    return .Send_Failed
}
