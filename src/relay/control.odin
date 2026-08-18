package relay

import "libs:json"

// The CONTROL messages the relay sends an endpoint, carried as the JSON payload of
// a CONTROL frame. relay -> endpoint only; never forwarded to the peer.
Control_Kind :: enum {
    // A client has been spliced onto this link (relay -> daemon).
    Peer_Attached,

    // The client went away; `reason` says why (relay -> daemon).
    Peer_Gone,
}

// A decoded CONTROL message. `reason` is set only for `.Peer_Gone`, and is
// allocated from the decode allocator.
Control :: struct {
    kind:   Control_Kind,
    reason: string,
}

// Parse a CONTROL frame's payload (the bytes after the tag). Malformed JSON is
// `.Control_Malformed`; a `type` outside this contract is `.Control_Unknown`. This
// is peer input, so it degrades to an error rather than asserting.
control_decode :: proc(payload: []u8, allocator := context.allocator) -> (out: Control, err: Error) {
    Raw :: struct {
        type:   string,
        reason: string,
    }

    raw: Raw
    if json.unmarshal(payload, &raw, .JSON, allocator) != nil {
        return {}, .Control_Malformed
    }

    switch raw.type {
    case "peer_attached":
        return {kind = .Peer_Attached}, .None

    case "peer_gone":
        return {kind = .Peer_Gone, reason = raw.reason}, .None

    case:
        return {}, .Control_Unknown
    }
}
