package relay

import "core:slice"
import "core:testing"

// The golden vectors, mirroring yuke-relay/internal/envelope/testdata/vectors.json.
// These are the interop contract: the exact bytes both implementations agree on. A
// framing change needs new vectors on both sides and a version bump.
@(test)
test_envelope_golden :: proc(t: ^testing.T) {
    Vector :: struct {
        name:    string,
        type:    Frame_Type,
        payload: []u8,
        wire:    []u8,
    }

    vectors := []Vector {
        {"sealed single zero byte", .Sealed, []u8{0x00}, []u8{0x01, 0x00}},
        {"sealed ascii hello", .Sealed, []u8{0x68, 0x65, 0x6c, 0x6c, 0x6f}, []u8{0x01, 0x68, 0x65, 0x6c, 0x6c, 0x6f}},
        {"sealed high bytes", .Sealed, []u8{0xde, 0xad, 0xbe, 0xef}, []u8{0x01, 0xde, 0xad, 0xbe, 0xef}},
        {"sealed payload that is itself a tag byte", .Sealed, []u8{0x02}, []u8{0x01, 0x02}},
        {"control empty object", .Control, []u8{0x7b, 0x7d}, []u8{0x02, 0x7b, 0x7d}},
        {
            "control small object",
            .Control,
            []u8{0x7b, 0x22, 0x74, 0x22, 0x3a, 0x22, 0x78, 0x22, 0x7d},
            []u8{0x02, 0x7b, 0x22, 0x74, 0x22, 0x3a, 0x22, 0x78, 0x22, 0x7d},
        },
    }

    for v in vectors {
        enc := frame_encode(Frame{type = v.type, payload = v.payload}, context.temp_allocator)
        testing.expectf(t, slice.equal(enc, v.wire), "%s: encode mismatch", v.name)

        dec, err := frame_decode(v.wire)
        testing.expect_value(t, err, Error.None)
        testing.expect_value(t, dec.type, v.type)
        testing.expectf(t, slice.equal(dec.payload, v.payload), "%s: decode payload mismatch", v.name)
    }

    free_all(context.temp_allocator)
}

// Length is checked before type, so a one-byte unknown tag is `.Empty_Payload`, and
// an unknown tag only surfaces once there is a payload to go with it.
@(test)
test_envelope_decode_rejects :: proc(t: ^testing.T) {
    Case :: struct {
        name: string,
        msg:  []u8,
        want: Error,
    }

    cases := []Case {
        {"empty message", []u8{}, .Empty},
        {"lone sealed tag", []u8{0x01}, .Empty_Payload},
        {"lone unknown tag", []u8{0x03}, .Empty_Payload},
        {"unknown tag with payload", []u8{0x03, 0x00}, .Unknown_Type},
        {"zero tag with payload", []u8{0x00, 0x01}, .Unknown_Type},
    }

    for c in cases {
        _, err := frame_decode(c.msg)
        testing.expectf(t, err == c.want, "%s: got %v, want %v", c.name, err, c.want)
    }
}

// Decode aliases the source message; it must not copy the payload.
@(test)
test_envelope_decode_aliases :: proc(t: ^testing.T) {
    msg := []u8{0x01, 0xaa, 0xbb}

    dec, err := frame_decode(msg)
    testing.expect_value(t, err, Error.None)
    testing.expect(t, raw_data(dec.payload) == raw_data(msg[1:]), "payload must alias the source message")
}

@(test)
test_control_decode :: proc(t: ^testing.T) {
    attached, err1 := control_decode(transmute([]u8)string(`{"type":"peer_attached"}`), context.temp_allocator)
    testing.expect_value(t, err1, Error.None)
    testing.expect_value(t, attached.kind, Control_Kind.Peer_Attached)

    gone, err2 := control_decode(
        transmute([]u8)string(`{"type":"peer_gone","reason":"replaced"}`),
        context.temp_allocator,
    )
    testing.expect_value(t, err2, Error.None)
    testing.expect_value(t, gone.kind, Control_Kind.Peer_Gone)
    testing.expect(t, gone.reason == "replaced", "peer_gone must carry its reason")

    _, err3 := control_decode(transmute([]u8)string(`{"type":"nope"}`), context.temp_allocator)
    testing.expect_value(t, err3, Error.Control_Unknown)

    _, err4 := control_decode(transmute([]u8)string(`not json`), context.temp_allocator)
    testing.expect_value(t, err4, Error.Control_Malformed)

    free_all(context.temp_allocator)
}
