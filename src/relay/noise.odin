// The end-to-end Noise session carried inside SEALED frames. The relay forwards these
// bytes without a key, so this is what makes the transport safe over an untrusted
// middlebox: the client (initiator) pre-knows the daemon's (responder's) static key from
// the roster pin, and IK proves the daemon holds the matching private key. A relay that
// lacks it cannot complete the handshake, so it can neither read nor MITM the session.
//
// One Noise message per SEALED payload — the WebSocket boundary is the framing. msg1
// carries an empty payload (IK's first message is replay- and KCI-weak, so no real frame
// rides it); real frames start post-handshake, where the transport keys are strong.
package relay

import "core:crypto/ecdh"
import "core:crypto/noise"

// The Noise pattern: IK over X25519, ChaCha20-Poly1305, SHA-256. A change here is a
// protocol break that needs both ends and a version bump.
NOISE_PROTOCOL :: "Noise_IK_25519_ChaChaPoly_SHA256"

// The X25519 static public key size, in bytes.
NOISE_STATIC_KEY_SIZE :: 32

// The v1 handshake prologue both ends bind into the transcript. Version-only for now; the
// device_id is folded in once the control plane assigns one. Both ends must match exactly.
NOISE_PROLOGUE_V1 :: "yuke-relay v1"

// A relay session failure. Handshake and transport bytes arrive from the peer through the
// relay, so a bad one degrades to an error rather than crashing the daemon.
Noise_Error :: enum {
    // No error.
    None,

    // A handshake message was rejected: a wrong pinned key, a tampered message, or a
    // prologue the two ends do not share.
    Handshake_Failed,

    // A transport frame failed authentication.
    Decrypt_Failed,

    // A plaintext frame exceeds the Noise packet limit; the caller must bound frame size.
    Frame_Too_Large,
}

// One end of a relay session: the IK handshake, then the transport ciphers it splits into.
// The daemon is the responder, the client the initiator. Free with `session_destroy`,
// which wipes the key material.
Session :: struct {
    // @private
    // Handshake state, live until `split`, then reset to wipe its secrets.
    hs:          noise.Handshake_State,

    // @private
    // Transport AEAD instances, valid once `split` is true.
    cs:          noise.Cipher_States,

    // @private
    // Whether the handshake completed and produced transport keys.
    split:       bool,

    // @private
    // Our role: the daemon is the responder (false).
    initiator:   bool,

    // @private
    // The peer's static public key, captured at split before the handshake is wiped, and read
    // back via `session_peer_static`. v1 trusts the relay's account-scoping rather than gating
    // on a specific peer key; the capture is what a later gate would consume.
    peer_static: [NOISE_STATIC_KEY_SIZE]u8,

    // @private
    // Whether `peer_static` was captured.
    has_peer:    bool,
}

// Begin the initiator (client) half. `static_key` is our own static; `remote_static` is
// the responder's static, pinned from the roster; `prologue` must byte-match the
// responder's. The keys are validated where they are loaded, so a bad one here is a
// programmer error, asserted rather than returned.
session_init_initiator :: proc(
    sess: ^Session,
    static_key: ^ecdh.Private_Key,
    remote_static: ^ecdh.Public_Key,
    prologue: []u8,
) {
    assert(sess != nil, "session_init_initiator needs session storage")

    sess^ = {}
    sess.initiator = true

    status := noise.handshake_init(&sess.hs, true, prologue, static_key, remote_static, NOISE_PROTOCOL)
    assert(status == .Ok, "IK initiator init failed on validated inputs")
}

// Begin the responder (daemon) half. We learn the initiator's static key from its first
// message, so no peer key is supplied here.
session_init_responder :: proc(sess: ^Session, static_key: ^ecdh.Private_Key, prologue: []u8) {
    assert(sess != nil, "session_init_responder needs session storage")

    sess^ = {}
    sess.initiator = false

    status := noise.handshake_init(&sess.hs, false, prologue, static_key, nil, NOISE_PROTOCOL)
    assert(status == .Ok, "IK responder init failed on validated inputs")
}

// Initiator: produce the first handshake message. It carries an empty payload and must be
// sent as the first SEALED frame. Returns the message allocated from `allocator`.
session_initiate :: proc(sess: ^Session, allocator := context.allocator) -> (msg1: []u8, err: Noise_Error) {
    assert(sess != nil && sess.initiator && !sess.split, "session_initiate needs a fresh initiator")

    out, _, status := noise.handshake_initiator_step(&sess.hs, nil, nil, nil, allocator)
    if status == .Handshake_Pending {
        return out, .None
    }

    // Writing our own msg1 with validated keys has no other outcome.
    unreachable()
}

// Responder: consume the initiator's first message and produce the reply. On success the
// session is complete and split, and `reply` is the SEALED payload to send back. A rejected
// msg1 — wrong pinned key, tamper, or prologue mismatch — is `.Handshake_Failed`.
session_respond :: proc(
    sess: ^Session,
    msg1: []u8,
    allocator := context.allocator,
) -> (
    reply: []u8,
    err: Noise_Error,
) {
    assert(sess != nil && !sess.initiator && !sess.split, "session_respond needs a fresh responder")

    out, _, status := noise.handshake_responder_step(&sess.hs, msg1, nil, nil, allocator)
    if status != .Handshake_Complete {
        return nil, .Handshake_Failed
    }

    session_split(sess)

    return out, .None
}

// Initiator: consume the responder's reply, completing and splitting the session. A
// rejected reply is `.Handshake_Failed`.
session_complete :: proc(sess: ^Session, msg2: []u8, allocator := context.allocator) -> Noise_Error {
    assert(sess != nil && sess.initiator && !sess.split, "session_complete needs a pending initiator")

    _, _, status := noise.handshake_initiator_step(&sess.hs, msg2, nil, nil, allocator)
    if status != .Handshake_Complete {
        return .Handshake_Failed
    }

    session_split(sess)

    return .None
}

// Seal one plaintext frame into a SEALED payload, allocated from `allocator`. Only valid
// after the handshake split — a call before then is a caller-ordering bug.
session_seal :: proc(
    sess: ^Session,
    plaintext: []u8,
    allocator := context.allocator,
) -> (
    ciphertext: []u8,
    err: Noise_Error,
) {
    assert(sess != nil && sess.split, "session_seal before the handshake split")

    out, status := noise.seal_message(&sess.cs, nil, plaintext, nil, allocator)
    if status == .Ok {
        return out, .None
    }

    if status == .Max_Packet_Size {
        return nil, .Frame_Too_Large
    }

    // Sealing our own frame past a split has no other failure on valid input.
    unreachable()
}

// Open one SEALED payload back to plaintext, allocated from `allocator`. A frame that fails
// authentication is `.Decrypt_Failed` — peer input, so it degrades rather than crashing.
// Only valid after the handshake split.
session_open :: proc(
    sess: ^Session,
    ciphertext: []u8,
    allocator := context.allocator,
) -> (
    plaintext: []u8,
    err: Noise_Error,
) {
    assert(sess != nil && sess.split, "session_open before the handshake split")

    out, status := noise.open_message(&sess.cs, nil, ciphertext, nil, allocator)
    if status != .Ok {
        return nil, .Decrypt_Failed
    }

    return out, .None
}

// The peer's static public key, valid once the handshake split. `ok` is false before then.
session_peer_static :: proc(sess: ^Session) -> (key: [NOISE_STATIC_KEY_SIZE]u8, ok: bool) {
    assert(sess != nil, "session_peer_static needs a session")

    return sess.peer_static, sess.has_peer
}

// Release the session, wiping the handshake and transport key material. Safe to call once,
// on either a completed or an abandoned session.
session_destroy :: proc(sess: ^Session) {
    assert(sess != nil, "session_destroy needs a session")

    noise.handshake_reset(&sess.hs)
    noise.cipherstates_reset(&sess.cs)
    sess^ = {}
}

// Derive the transport ciphers from the completed handshake, capture the peer's static
// key for logging, then wipe the handshake secrets. Only called on a completed handshake,
// which is always splittable, so a failure here is our own bug.
@(private = "file")
session_split :: proc(sess: ^Session) {
    status := noise.handshake_split(&sess.hs, &sess.cs)
    assert(status == .Ok, "split of a completed handshake failed")

    if peer, s := noise.handshake_peer_identity(&sess.hs); s == .Ok {
        ecdh.public_key_bytes(peer, sess.peer_static[:])
        sess.has_peer = true
    }

    noise.handshake_reset(&sess.hs)
    sess.split = true
}
