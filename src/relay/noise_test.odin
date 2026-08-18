package relay

import "core:crypto/ecdh"
import "core:testing"

// A fresh X25519 static keypair for a test endpoint.
@(private = "file")
static_keypair :: proc() -> ecdh.Private_Key {
    key: ecdh.Private_Key
    ok := ecdh.private_key_generate(&key, .X25519)
    assert(ok, "test entropy source unavailable")

    return key
}

// The public half of a private key, as bytes.
@(private = "file")
static_public_bytes :: proc(priv: ^ecdh.Private_Key) -> [NOISE_STATIC_KEY_SIZE]u8 {
    pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&pub, priv)

    out: [NOISE_STATIC_KEY_SIZE]u8
    ecdh.public_key_bytes(&pub, out[:])

    return out
}

// Two in-proc endpoints complete the IK handshake, exchange transport frames both ways,
// and each learns the other's static key. This is the stage's accept criterion.
@(test)
test_noise_handshake_and_exchange :: proc(t: ^testing.T) {
    prologue := transmute([]u8)string("yuke-relay v1")

    daemon_key := static_keypair()
    client_key := static_keypair()

    daemon_pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&daemon_pub, &daemon_key)

    client, server: Session
    session_init_initiator(&client, &client_key, &daemon_pub, prologue)
    session_init_responder(&server, &daemon_key, prologue)
    defer session_destroy(&client)
    defer session_destroy(&server)

    msg1 := session_initiate(&client, context.temp_allocator)

    msg2, e2 := session_respond(&server, msg1, context.temp_allocator)
    testing.expect_value(t, e2, Noise_Error.None)

    e3 := session_complete(&client, msg2, context.temp_allocator)
    testing.expect_value(t, e3, Noise_Error.None)

    testing.expect(t, client.split && server.split, "both ends must split after the handshake")

    // Client -> daemon.
    ct, se := session_seal(&client, transmute([]u8)string("hello daemon"), context.temp_allocator)
    testing.expect_value(t, se, Noise_Error.None)
    pt, oe := session_open(&server, ct, context.temp_allocator)
    testing.expect_value(t, oe, Noise_Error.None)
    testing.expect(t, string(pt) == "hello daemon", "daemon must recover the client frame")

    // Daemon -> client.
    ct, se = session_seal(&server, transmute([]u8)string("hello client"), context.temp_allocator)
    testing.expect_value(t, se, Noise_Error.None)
    pt, oe = session_open(&client, ct, context.temp_allocator)
    testing.expect_value(t, oe, Noise_Error.None)
    testing.expect(t, string(pt) == "hello client", "client must recover the daemon frame")

    // The nonce advances: a second frame in the same direction still opens.
    ct, se = session_seal(&client, transmute([]u8)string("second"), context.temp_allocator)
    testing.expect_value(t, se, Noise_Error.None)
    pt, oe = session_open(&server, ct, context.temp_allocator)
    testing.expect_value(t, oe, Noise_Error.None)
    testing.expect(t, string(pt) == "second", "the second frame must open in order")

    // Each end learned the other's static key.
    client_pub := static_public_bytes(&client_key)
    learned, ok := session_peer_static(&server)
    testing.expect(t, ok, "responder must learn the initiator's static key")
    testing.expect(t, learned == client_pub, "responder learned the wrong client key")

    daemon_pub_bytes := static_public_bytes(&daemon_key)
    pinned, pok := session_peer_static(&client)
    testing.expect(t, pok, "initiator must retain the responder's static key")
    testing.expect(t, pinned == daemon_pub_bytes, "initiator retained the wrong daemon key")

    free_all(context.temp_allocator)
}

// A client that pins the wrong daemon static key cannot complete the handshake: this is
// the E2E guarantee — a relay lacking the daemon's private key cannot impersonate it.
@(test)
test_noise_wrong_pin_fails :: proc(t: ^testing.T) {
    prologue := transmute([]u8)string("yuke-relay v1")

    daemon_key := static_keypair()
    imposter_key := static_keypair()
    client_key := static_keypair()

    wrong_pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&wrong_pub, &imposter_key)

    client, server: Session
    session_init_initiator(&client, &client_key, &wrong_pub, prologue)
    session_init_responder(&server, &daemon_key, prologue)
    defer session_destroy(&client)
    defer session_destroy(&server)

    msg1 := session_initiate(&client, context.temp_allocator)

    _, e2 := session_respond(&server, msg1, context.temp_allocator)
    testing.expect_value(t, e2, Noise_Error.Handshake_Failed)

    free_all(context.temp_allocator)
}

// A prologue the two ends do not share fails the handshake: the prologue binds device_id
// and version into the transcript, so a mis-splice or downgrade cannot silently succeed.
@(test)
test_noise_prologue_mismatch_fails :: proc(t: ^testing.T) {
    daemon_key := static_keypair()
    client_key := static_keypair()

    daemon_pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&daemon_pub, &daemon_key)

    client, server: Session
    session_init_initiator(&client, &client_key, &daemon_pub, transmute([]u8)string("prologue-a"))
    session_init_responder(&server, &daemon_key, transmute([]u8)string("prologue-b"))
    defer session_destroy(&client)
    defer session_destroy(&server)

    msg1 := session_initiate(&client, context.temp_allocator)
    _, e := session_respond(&server, msg1, context.temp_allocator)
    testing.expect_value(t, e, Noise_Error.Handshake_Failed)

    free_all(context.temp_allocator)
}

// A tampered transport frame fails authentication rather than decrypting to garbage.
@(test)
test_noise_tampered_frame_fails :: proc(t: ^testing.T) {
    prologue := transmute([]u8)string("yuke-relay v1")

    daemon_key := static_keypair()
    client_key := static_keypair()

    daemon_pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&daemon_pub, &daemon_key)

    client, server: Session
    session_init_initiator(&client, &client_key, &daemon_pub, prologue)
    session_init_responder(&server, &daemon_key, prologue)
    defer session_destroy(&client)
    defer session_destroy(&server)

    msg1 := session_initiate(&client, context.temp_allocator)
    msg2, _ := session_respond(&server, msg1, context.temp_allocator)
    _ = session_complete(&client, msg2, context.temp_allocator)

    ct, _ := session_seal(&client, transmute([]u8)string("tamper me"), context.temp_allocator)
    ct[0] ~= 0xff

    _, e := session_open(&server, ct, context.temp_allocator)
    testing.expect_value(t, e, Noise_Error.Decrypt_Failed)

    free_all(context.temp_allocator)
}
