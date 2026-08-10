package client

import "core:nbio"
import "core:testing"

import ws "libs:websocket"

// `relay_create` builds a complete transport and `destroy` frees it with no leak (the test
// runner tracks memory), and a bad endpoint is rejected before anything is allocated.
@(test)
test_relay_create_lifecycle :: proc(t: ^testing.T) {
    if nbio.acquire_thread_event_loop() != nil {
        return
    }

    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    static_seed: [32]u8
    remote_static: [32]u8
    for i in 0 ..< 32 {
        static_seed[i] = u8(i)
        remote_static[i] = u8(255 - i)
    }

    // A malformed relay URL fails before allocating a backend.
    _, bad := relay_create(loop, "http://relay", "tkt", static_seed[:], remote_static[:])
    testing.expect_value(t, bad, ws.Client_Error.Invalid_Options)

    // A well-formed create yields a complete ops bag; destroy frees it (never dialed, so the
    // link is untouched) without leaking the cloned strings, arenas, or key material.
    transport, err := relay_create(loop, "wss://relay.yuke.sh/connect", "tkt-123", static_seed[:], remote_static[:])
    testing.expect_value(t, err, ws.Client_Error.None)
    testing.expect(
        t,
        transport.open != nil &&
        transport.send_text != nil &&
        transport.close != nil &&
        transport.cancel != nil &&
        transport.abort != nil &&
        transport.destroy != nil,
        "relay_create must return a complete transport",
    )

    transport->destroy()
}
