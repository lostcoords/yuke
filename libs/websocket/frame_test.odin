package websocket

import "core:slice"
import "core:testing"

// Client header length encodings, matched byte-for-byte against known vectors.
// A zero masking key leaves the four trailing mask bytes as 0x00.
@(test)
test_make_header_length_encodings :: proc(t: ^testing.T) {
    buf: [MAX_HEADER_BYTES]byte
    zero := [MASK_KEY_BYTES]byte{}

    // FIN + text, length 5: single-byte length.
    testing.expect(
        t,
        slice.equal(make_header(&buf, true, .Text, 5, zero), []byte{0x81, 0x85, 0x00, 0x00, 0x00, 0x00}),
        "text len 5",
    )

    // Non-final continuation, length 128: 16-bit extended length.
    testing.expect(
        t,
        slice.equal(
            make_header(&buf, false, .Continuation, 128, zero),
            []byte{0x00, 0xFE, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00},
        ),
        "continuation len 128",
    )

    // FIN + continuation, length 65536: 64-bit extended length.
    testing.expect(
        t,
        slice.equal(
            make_header(&buf, true, .Continuation, int(max(u16)) + 1, zero),
            []byte{0x80, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0},
        ),
        "continuation len 65536",
    )

    // FIN + ping, length 125: largest single-byte length.
    testing.expect(
        t,
        slice.equal(make_header(&buf, true, .Ping, 125, zero), []byte{0x89, 0xFD, 0x00, 0x00, 0x00, 0x00}),
        "ping len 125",
    )
}

// `make_header` switches to the 16-bit extended form exactly at its lower and
// upper bounds: 126 (smallest value requiring it) and 65535 (largest it holds).
@(test)
test_make_header_16bit_boundaries :: proc(t: ^testing.T) {
    buf: [MAX_HEADER_BYTES]byte
    zero := [MASK_KEY_BYTES]byte{}

    testing.expect(
        t,
        slice.equal(
            make_header(&buf, true, .Binary, 126, zero),
            []byte{0x82, 0xFE, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00},
        ),
        "binary len 126",
    )

    testing.expect(
        t,
        slice.equal(
            make_header(&buf, true, .Binary, 65535, zero),
            []byte{0x82, 0xFE, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00},
        ),
        "binary len 65535",
    )
}

// `encode_frame` carries the same 16-bit boundary through to a full masked
// frame, including the actual payload bytes.
@(test)
test_encode_frame_16bit_boundaries :: proc(t: ^testing.T) {
    key := [MASK_KEY_BYTES]byte{0x11, 0x22, 0x33, 0x44}

    payload_126 := make([]byte, 126, context.temp_allocator)
    frame_126 := encode_frame(true, .Binary, payload_126, key, context.temp_allocator)
    testing.expect_value(t, len(frame_126), 4 + MASK_KEY_BYTES + 126)
    testing.expect_value(t, frame_126[1], u8(0xFE))
    testing.expect_value(t, frame_126[2], u8(0x00))
    testing.expect_value(t, frame_126[3], u8(0x7E))

    payload_65535 := make([]byte, 65535, context.temp_allocator)
    frame_65535 := encode_frame(true, .Binary, payload_65535, key, context.temp_allocator)
    testing.expect_value(t, len(frame_65535), 4 + MASK_KEY_BYTES + 65535)
    testing.expect_value(t, frame_65535[1], u8(0xFE))
    testing.expect_value(t, frame_65535[2], u8(0xFF))
    testing.expect_value(t, frame_65535[3], u8(0xFF))
}

// Masking XORs each payload byte with the key byte at index `i % 4`, out of place.
@(test)
test_mask_payload_xor :: proc(t: ^testing.T) {
    src := []byte{'h', 'i', 'y', 'a', 'z'}
    dst := make([]byte, len(src), context.temp_allocator)
    key := [MASK_KEY_BYTES]byte{0x01, 0x02, 0x03, 0x04}

    mask_payload(dst, src, key)

    testing.expect_value(t, dst[0], 'h' ~ 0x01)
    testing.expect_value(t, dst[1], 'i' ~ 0x02)
    testing.expect_value(t, dst[2], 'y' ~ 0x03)
    testing.expect_value(t, dst[3], 'a' ~ 0x04)
    testing.expect_value(t, dst[4], 'z' ~ 0x01)
    testing.expect(t, src[0] == 'h', "source is not mutated")
}

// A well-formed unmasked server text header decodes with the payload untouched.
@(test)
test_parse_header_unmasked_text :: proc(t: ^testing.T) {
    buf := []byte{0x81, 0x05, 'h', 'e', 'l', 'l', 'o'}

    h, header_length, status, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, status, Header_Status.Ready)
    testing.expect_value(t, header_length, 2)
    testing.expect_value(t, h.opcode, Op_Code.Text)
    testing.expect_value(t, h.payload_length, 5)
    testing.expect(t, h.fin, "fin should be set")
}

// A server frame with the mask bit set is a protocol error for a client.
@(test)
test_parse_header_rejects_masked :: proc(t: ^testing.T) {
    buf := []byte{0x81, 0x85, 0, 0, 0, 0, 'h', 'e', 'l', 'l', 'o'}

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Masked)
}

// A set reserved bit without a negotiated extension is a protocol error.
@(test)
test_parse_header_rejects_reserved_bit :: proc(t: ^testing.T) {
    buf := []byte{0xC1, 0x05, 'h', 'e', 'l', 'l', 'o'}

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Reserved_Bit_Set)
}

// An opcode outside the assigned set fails the connection.
@(test)
test_parse_header_rejects_unrecognized_opcode :: proc(t: ^testing.T) {
    buf := []byte{0x8F, 0x00} // FIN + opcode 0xF, unassigned

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Unrecognized_Opcode)
}

// A 16-bit extended length decodes at its minimal-encoding boundaries: 126 (the
// smallest value that requires the 16-bit form) and 65535 (the largest value
// the form can hold).
@(test)
test_parse_header_extended_length_16bit_boundaries :: proc(t: ^testing.T) {
    min_buf := []byte{0x82, 0x7E, 0x00, 0x7E} // binary, len 126
    h_min, header_length_min, status_min, err_min := parse_header(min_buf, .Client)
    testing.expect_value(t, err_min, Protocol_Error.None)
    testing.expect_value(t, status_min, Header_Status.Ready)
    testing.expect_value(t, header_length_min, 4)
    testing.expect_value(t, h_min.payload_length, 126)

    max_buf := []byte{0x82, 0x7E, 0xFF, 0xFF} // binary, len 65535
    h_max, header_length_max, status_max, err_max := parse_header(max_buf, .Client)
    testing.expect_value(t, err_max, Protocol_Error.None)
    testing.expect_value(t, status_max, Header_Status.Ready)
    testing.expect_value(t, header_length_max, 4)
    testing.expect_value(t, h_max.payload_length, 65535)
}

// A 64-bit extended length decodes at its minimal-encoding boundary: 65536, the
// smallest value that requires the 64-bit form.
@(test)
test_parse_header_extended_length_64bit_boundary :: proc(t: ^testing.T) {
    buf := []byte{0x82, 0x7F, 0, 0, 0, 0, 0, 1, 0, 0} // binary, len 65536

    h, header_length, status, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, status, Header_Status.Ready)
    testing.expect_value(t, header_length, 10)
    testing.expect_value(t, h.payload_length, 65536)
}

// A 16-bit extended length under 126 could have been encoded directly and is a
// protocol error (RFC 6455 §5.2 forbids non-minimal length encoding).
@(test)
test_parse_header_rejects_non_minimal_16bit_length :: proc(t: ^testing.T) {
    buf := []byte{0x82, 0x7E, 0x00, 0x7D} // binary, 16-bit ext encoding len 125

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Non_Minimal_Length)
}

// A 64-bit extended length under 65536 could have been encoded with the 16-bit
// form and is a protocol error.
@(test)
test_parse_header_rejects_non_minimal_64bit_length :: proc(t: ^testing.T) {
    buf := []byte{0x82, 0x7F, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF} // binary, 64-bit ext encoding len 65535

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Non_Minimal_Length)
}

// A 64-bit extended length with the high bit set overflows what an `int` can
// represent and is a protocol error rather than a silent wraparound.
@(test)
test_parse_header_rejects_64bit_length_overflow :: proc(t: ^testing.T) {
    buf := []byte{0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0} // binary, 64-bit ext, MSB set

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Frame_Length_Overflow)
}

// A control frame may not carry an extended length (payload is capped at 125).
@(test)
test_parse_header_rejects_control_extended_length :: proc(t: ^testing.T) {
    // Unmasked ping (0x89) whose length code 0x7E promises a 16-bit length.
    buf := []byte{0x89, 0x7E, 0x00, 0x80}

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Control_Frame_Too_Big)
}

// A close frame body of exactly one byte is too short for a status code.
@(test)
test_parse_header_rejects_bad_close :: proc(t: ^testing.T) {
    buf := []byte{0x88, 0x01, 0x03}

    _, _, _, err := parse_header(buf, .Client)

    testing.expect_value(t, err, Protocol_Error.Bad_Close)
}

// A buffer shorter than the encoded header yields `.Need_More`, not an error:
// both the two fixed bytes and any promised extended-length bytes must arrive.
@(test)
test_parse_header_need_more :: proc(t: ^testing.T) {
    short, _, s1, e1 := parse_header([]byte{0x81}, .Client)
    testing.expect_value(t, s1, Header_Status.Need_More)
    testing.expect_value(t, e1, Protocol_Error.None)
    testing.expect_value(t, short.payload_length, 0)

    // 16-bit length code present but its two length bytes are missing.
    _, _, s2, e2 := parse_header([]byte{0x81, 0x7E}, .Client)
    testing.expect_value(t, s2, Header_Status.Need_More)
    testing.expect_value(t, e2, Protocol_Error.None)
}

// `encode_frame` produces a masked client frame. `parse_header` intentionally
// rejects masked frames (those flow client -> server), so verify the built bytes
// directly: fixed header, the mask key, then a payload that unmasks to the input.
@(test)
test_encode_frame_masked_layout :: proc(t: ^testing.T) {
    text := "hello world"
    payload := transmute([]byte)text
    key := [MASK_KEY_BYTES]byte{0x37, 0xFA, 0x21, 0x3D}

    frame := encode_frame(true, .Text, payload, key, context.temp_allocator)

    testing.expect_value(t, len(frame), 2 + MASK_KEY_BYTES + len(payload))
    testing.expect_value(t, frame[0], u8(0x81)) // FIN + text
    testing.expect_value(t, frame[1], u8(0x80 | len(payload))) // mask bit + length
    testing.expect(t, slice.equal(frame[2:2 + MASK_KEY_BYTES], key[:]), "mask key is written verbatim")

    masked := frame[2 + MASK_KEY_BYTES:]
    recovered := make([]byte, len(masked), context.temp_allocator)
    mask_payload(recovered, masked, key)
    testing.expect(t, slice.equal(recovered, payload), "unmasked payload matches original")
}

// A well-formed masked client text frame decodes under the server role: the
// header length includes the 4 mask bytes and the key is copied out verbatim.
@(test)
test_parse_header_server_masked_text :: proc(t: ^testing.T) {
    key := [MASK_KEY_BYTES]byte{0x37, 0xFA, 0x21, 0x3D}
    payload := transmute([]byte)string("hello")
    masked := make([]byte, len(payload), context.temp_allocator)
    mask_payload(masked, payload, key)

    buf := make([dynamic]byte, context.temp_allocator)
    append(&buf, 0x81, 0x85, key[0], key[1], key[2], key[3])
    append(&buf, ..masked)

    h, header_length, status, err := parse_header(buf[:], .Server)

    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, status, Header_Status.Ready)
    testing.expect_value(t, header_length, 2 + MASK_KEY_BYTES)
    testing.expect_value(t, h.opcode, Op_Code.Text)
    testing.expect_value(t, h.payload_length, 5)
    testing.expect(t, h.fin, "fin should be set")
    testing.expect(t, h.masked, "masked flag should be set")
    testing.expect(t, slice.equal(h.mask_key[:], key[:]), "mask key copied out verbatim")

    // Unmasking the payload with the recovered key restores the plaintext.
    recovered := make([]byte, h.payload_length, context.temp_allocator)
    mask_payload(recovered, buf[header_length:header_length + h.payload_length], h.mask_key)
    testing.expect_value(t, string(recovered), "hello")
}

// A masked 16-bit extended-length header places the mask key after the two length
// bytes, so the full header is 8 bytes.
@(test)
test_parse_header_server_masked_extended_length :: proc(t: ^testing.T) {
    key := [MASK_KEY_BYTES]byte{0x11, 0x22, 0x33, 0x44}
    buf := []byte{0x82, 0xFE, 0x00, 0x7E, key[0], key[1], key[2], key[3]} // binary, masked, len 126

    h, header_length, status, err := parse_header(buf, .Server)

    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, status, Header_Status.Ready)
    testing.expect_value(t, header_length, 4 + MASK_KEY_BYTES)
    testing.expect_value(t, h.payload_length, 126)
    testing.expect(t, slice.equal(h.mask_key[:], key[:]), "mask key follows the length bytes")
}

// A server rejects an unmasked client frame (RFC 6455 §5.1 requires the client to
// mask), the mirror of the client rejecting a masked server frame.
@(test)
test_parse_header_server_rejects_unmasked :: proc(t: ^testing.T) {
    buf := []byte{0x81, 0x05, 'h', 'e', 'l', 'l', 'o'} // unmasked

    _, _, _, err := parse_header(buf, .Server)

    testing.expect_value(t, err, Protocol_Error.Unmasked)
}

// Under the server role a masked header whose mask key bytes have not all arrived
// yet reports `.Need_More`, not a spurious error.
@(test)
test_parse_header_server_need_more_for_mask_key :: proc(t: ^testing.T) {
    // Fixed bytes present, but only 2 of the 4 mask-key bytes buffered.
    buf := []byte{0x81, 0x85, 0x00, 0x00}

    _, _, status, err := parse_header(buf, .Server)

    testing.expect_value(t, status, Header_Status.Need_More)
    testing.expect_value(t, err, Protocol_Error.None)
}

// `make_header` with no masking key builds an unmasked server header: the mask bit
// is clear and no key bytes are appended.
@(test)
test_make_header_server_unmasked :: proc(t: ^testing.T) {
    buf: [MAX_HEADER_BYTES]byte

    // FIN + text, length 5: single-byte length, no mask key.
    testing.expect(t, slice.equal(make_header(&buf, true, .Text, 5, nil), []byte{0x81, 0x05}), "unmasked text len 5")

    // 16-bit extended length stays unmasked and ends after the two length bytes.
    testing.expect(
        t,
        slice.equal(make_header(&buf, true, .Binary, 126, nil), []byte{0x82, 0x7E, 0x00, 0x7E}),
        "unmasked binary len 126",
    )
}

// `encode_frame` with no key builds a complete unmasked server frame: the mask bit
// is clear and the payload is copied verbatim (no masking transform).
@(test)
test_encode_frame_server_unmasked_layout :: proc(t: ^testing.T) {
    payload := transmute([]byte)string("hello world")

    frame := encode_frame(true, .Text, payload, nil, context.temp_allocator)

    testing.expect_value(t, len(frame), 2 + len(payload))
    testing.expect_value(t, frame[0], u8(0x81)) // FIN + text
    testing.expect_value(t, frame[1], u8(len(payload))) // no mask bit
    testing.expect(t, slice.equal(frame[2:], payload), "payload copied verbatim")
}

// A frame built by the client encoder decodes back through the server-role header
// parser: `encode_frame` (masked) and `parse_header(.Server)` are exact duals.
@(test)
test_encode_then_parse_header_server_round_trip :: proc(t: ^testing.T) {
    key := [MASK_KEY_BYTES]byte{0x01, 0x02, 0x03, 0x04}
    payload := transmute([]byte)string("round trip")

    frame := encode_frame(true, .Binary, payload, key, context.temp_allocator)

    h, header_length, status, err := parse_header(frame, .Server)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, status, Header_Status.Ready)
    testing.expect_value(t, h.opcode, Op_Code.Binary)
    testing.expect_value(t, h.payload_length, len(payload))
    testing.expect(t, slice.equal(h.mask_key[:], key[:]), "mask key round-trips")

    recovered := make([]byte, h.payload_length, context.temp_allocator)
    mask_payload(recovered, frame[header_length:header_length + h.payload_length], h.mask_key)
    testing.expect(t, slice.equal(recovered, payload), "payload round-trips")
}

// A valid code with a UTF-8 reason round-trips through decode.
@(test)
test_parse_close_valid_round_trip :: proc(t: ^testing.T) {
    body := []byte{0x03, 0xE8, 'b', 'y', 'e'} // 1000 = Normal_Closure

    p, err := parse_close(body)

    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, p.code, Close_Code.Normal_Closure)
    testing.expect_value(t, p.reason, "bye")
}

// An empty body is legal on the wire and synthesizes 1005 locally, even though
// 1005 itself may never appear as an on-wire code.
@(test)
test_parse_close_empty_synthesizes_no_status_rcvd :: proc(t: ^testing.T) {
    p, err := parse_close([]byte{})

    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect_value(t, p.code, Close_Code.No_Status_Rcvd)
    testing.expect_value(t, p.reason, "")
}

// Codes below the assigned range (including 0) are rejected.
@(test)
test_parse_close_rejects_low_code :: proc(t: ^testing.T) {
    body := []byte{0x00, 0x00}

    _, err := parse_close(body)

    testing.expect_value(t, err, Protocol_Error.Invalid_Close_Code)
}

// 1004, 1005, 1006, and 1015 are reserved or synthesized-only and must never
// appear on the wire.
@(test)
test_parse_close_rejects_reserved_codes :: proc(t: ^testing.T) {
    reserved := []u16{1004, 1005, 1006, 1015}

    for code in reserved {
        body := []byte{byte(code >> 8), byte(code)}
        _, err := parse_close(body)
        testing.expect_value(t, err, Protocol_Error.Invalid_Close_Code)
    }
}

// The unassigned gap between the last assigned code and the registered range
// (1016-2999) is rejected.
@(test)
test_parse_close_rejects_unassigned_gap :: proc(t: ^testing.T) {
    body := []byte{0x07, 0xD0} // 2000

    _, err := parse_close(body)

    testing.expect_value(t, err, Protocol_Error.Invalid_Close_Code)
}

// Codes at and above 5000 fall outside the registered/private-use range.
@(test)
test_parse_close_rejects_above_private_use :: proc(t: ^testing.T) {
    body := []byte{0x13, 0x88} // 5000

    _, err := parse_close(body)

    testing.expect_value(t, err, Protocol_Error.Invalid_Close_Code)
}

// A close reason that is not valid UTF-8 is rejected the same way a Text
// message's payload is.
@(test)
test_parse_close_rejects_invalid_utf8_reason :: proc(t: ^testing.T) {
    body := []byte{0x03, 0xE8, 0x80} // 1000, lone continuation byte

    _, err := parse_close(body)

    testing.expect_value(t, err, Protocol_Error.Invalid_Utf8)
}
