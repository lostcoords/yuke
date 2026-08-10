// Package relay is the client/daemon side of the yuke-relay transport: the link
// envelope, the control-plane client, the Noise session, and the dial/pump loop
// both roles share. This file is the envelope — the framing on a spliced link.
//
// One frame per binary WebSocket message: a one-byte type tag then a non-empty
// payload. It is an interop surface with yuke-relay/internal/envelope, so it is
// strict — unknown tags are rejected rather than skipped, and each malformed input
// is a distinct error. The golden vectors in the test are the contract; keep them
// honest.
package relay

// The one-byte frame tag. Unknown tags are rejected on decode, never skipped, so a
// future type is a versioned extension rather than a flag day.
Frame_Type :: enum u8 {
    // Opaque ciphertext, forwarded to the peer verbatim; the relay holds no key.
    Sealed  = 0x01,

    // JSON between the relay and one endpoint; never forwarded to the peer.
    Control = 0x02,
}

// The relay decode errors. Each malformed input is distinct so callers and the
// interop test can tell them apart. `frame_decode` checks length before type, so a
// one-byte message is `.Empty_Payload` even when that byte is an unknown tag.
Error :: enum {
    // No error.
    None,

    // Zero-length message: not even a type byte.
    Empty,

    // A lone type byte with no payload; every frame carries at least one byte.
    Empty_Payload,

    // A tag that is neither SEALED nor CONTROL (reserved 0x03 included).
    Unknown_Type,

    // A text WebSocket message. The envelope rides only binary; the socket reader
    // returns this, `frame_decode` never does.
    Text,

    // A CONTROL payload that is not the JSON object this contract defines.
    Control_Malformed,

    // A CONTROL message whose `type` is not one this contract defines.
    Control_Unknown,

    // A CONTROL frame on the client's /connect link. CONTROL is relay→daemon only; a
    // client must never receive one, so it fails the link rather than acting on it.
    Control_Unexpected,
}

// A decoded link message: a known type and a non-empty payload. On decode the
// payload aliases the source bytes — do not retain it past the life of that buffer.
Frame :: struct {
    type:    Frame_Type,
    payload: []u8,
}

// Serialise a frame to its wire bytes, allocated from `allocator`. The payload must
// be non-empty — an empty SEALED or CONTROL frame is meaningless — which is a
// programmer error here, since we only ever encode frames we built.
frame_encode :: proc(f: Frame, allocator := context.allocator) -> []u8 {
    assert(len(f.payload) > 0, "frame_encode: payload must be non-empty")

    out := make([]u8, 1 + len(f.payload), allocator)
    out[0] = u8(f.type)
    copy(out[1:], f.payload)

    return out
}

// Parse one binary WebSocket message into a frame. The returned payload aliases
// `msg` rather than copying it — the caller must not retain it past the life of
// `msg`. Length is checked before type: a one-byte message is `.Empty_Payload`,
// never `.Unknown_Type`.
frame_decode :: proc(msg: []u8) -> (frame: Frame, err: Error) {
    switch len(msg) {
    case 0:
        return {}, .Empty

    case 1:
        return {}, .Empty_Payload
    }

    t := Frame_Type(msg[0])

    if t != .Sealed && t != .Control {
        return {}, .Unknown_Type
    }

    return {type = t, payload = msg[1:]}, .None
}
