package websocket

import "core:mem"
import "core:slice"
import "core:testing"

// Build one unmasked server frame, choosing the minimal length encoding for
// `payload`: a direct length under 126, a 16-bit extended length up to 65535,
// or a 64-bit extended length beyond that. `b0` is the FIN|opcode byte, e.g.
// 0x81 for a final text frame.
srv_frame :: proc(b0: u8, payload: []byte, allocator := context.temp_allocator) -> []byte {
    n := len(payload)

    header_buf: [10]byte
    header_buf[0] = b0

    header_length: int
    switch {
    case n < PAYLOAD_LEN_16:
        header_buf[1] = u8(n)
        header_length = 2

    case n <= int(max(u16)):
        header_buf[1] = PAYLOAD_LEN_16
        header_buf[2] = byte(u16(n) >> 8)
        header_buf[3] = byte(n)
        header_length = 4

    case:
        header_buf[1] = PAYLOAD_LEN_64
        u := u64(n)
        for i in 0 ..< 8 {
            header_buf[2 + i] = byte(u >> uint((7 - i) * 8))
        }
        header_length = 10
    }

    out := make([]byte, header_length + n, allocator)
    copy(out, header_buf[:header_length])
    copy(out[header_length:], payload)

    return out
}

// Build one masked client frame (server-role decoder input) under a fixed key, so
// the decoder must unmask to recover the payload. `b0` is the FIN|opcode byte,
// mirroring `srv_frame`; `encode_frame` chooses the minimal length encoding.
cli_frame :: proc(b0: u8, payload: []byte, allocator := context.temp_allocator) -> []byte {
    fin := (b0 & 0x80) != 0
    opcode := Op_Code(b0 & 0x0f)
    key := [MASK_KEY_BYTES]byte{0xA1, 0xB2, 0xC3, 0xD4}

    return encode_frame(fin, opcode, payload, key, allocator)
}

// A single final masked text frame decodes to one unmasked UTF-8 Text message
// under the server role.
@(test)
test_decode_server_single_masked_text :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Server, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, cli_frame(0x81, transmute([]byte)string("hello")))

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "a message should be ready")
    testing.expect_value(t, msg.kind, Message_Kind.Text)
    testing.expect_value(t, string(msg.data), "hello")
}

// A masked binary payload of arbitrary bytes unmasks correctly, including bytes
// that collide with the key.
@(test)
test_decode_server_masked_binary :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Server, context.temp_allocator)
    defer decoder_destroy(&d)

    payload := []byte{0x00, 0xFF, 0xA1, 0xB2, 0xC3, 0xD4, 0x80}
    decoder_feed(&d, cli_frame(0x82, payload))

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "a message should be ready")
    testing.expect_value(t, msg.kind, Message_Kind.Binary)
    testing.expect(t, slice.equal(msg.data, payload), "payload unmasked to original bytes")
}

// Server-role fragmentation with a masked control frame interleaved between the
// data fragments: the ping surfaces first, then the reassembled text, each unmasked.
@(test)
test_decode_server_control_between_fragments :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Server, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, cli_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0
    decoder_feed(&d, cli_frame(0x89, transmute([]byte)string("pp"))) // ping, FIN=1
    decoder_feed(&d, cli_frame(0x80, transmute([]byte)string("lo"))) // continuation, FIN=1

    ping, has1, err1 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err1, Protocol_Error.None)
    testing.expect(t, has1, "ping surfaces first")
    testing.expect_value(t, ping.kind, Message_Kind.Ping)
    testing.expect_value(t, string(ping.data), "pp")

    text, has2, err2 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err2, Protocol_Error.None)
    testing.expect(t, has2, "reassembled text follows")
    testing.expect_value(t, text.kind, Message_Kind.Text)
    testing.expect_value(t, string(text.data), "hello")
}

// A server-role decoder rejects an unmasked frame from the client (RFC 6455 §5.1).
@(test)
test_decode_server_rejects_unmasked :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Server, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x81, transmute([]byte)string("hello"))) // unmasked

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Unmasked)
}

// Feeding a masked frame one byte at a time yields `.Need_More` — through the mask
// key bytes as well as the payload — completing only on the final byte.
@(test)
test_decode_server_incremental_need_more :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Server, context.temp_allocator)
    defer decoder_destroy(&d)

    frame := cli_frame(0x81, transmute([]byte)string("hi")) // 2 + 4 mask + 2 payload = 8 bytes

    for i in 0 ..< len(frame) - 1 {
        decoder_feed(&d, frame[i:i + 1])
        _, has, err := decoder_next(&d, context.temp_allocator)
        testing.expect(t, !has, "not complete yet")
        testing.expect_value(t, err, Protocol_Error.None)
    }

    decoder_feed(&d, frame[len(frame) - 1:])
    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "complete on final byte")
    testing.expect_value(t, string(msg.data), "hi")
}

// Server-role ownership: a partially reassembled masked message still pending at
// `decoder_destroy`, plus a control message already drained and freed by the
// caller, leaves nothing behind. Mirrors the client-role no-leak test.
@(test)
test_decode_server_ownership_no_leaks_with_partial_message_pending :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Server, tracked)

    // Frames are temp-allocated so only the decoder's own tracked allocations count.
    decoder_feed(&d, cli_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0, left open
    decoder_feed(&d, cli_frame(0x89, transmute([]byte)string("pp"))) // ping, FIN=1

    ping, has1, err1 := decoder_next(&d, tracked)
    testing.expect_value(t, err1, Protocol_Error.None)
    testing.expect(t, has1, "ping surfaces first")
    delete(ping.data, tracked)

    _, has2, err2 := decoder_next(&d, tracked)
    testing.expect_value(t, err2, Protocol_Error.None)
    testing.expect(t, !has2, "text message still incomplete")

    decoder_destroy(&d)

    for _, leak in track.allocation_map {
        testing.expectf(t, false, "leaked %v bytes allocated at %v", leak.size, leak.location)
    }
    testing.expect_value(t, len(track.allocation_map), 0)
}

// A single final text frame decodes to one UTF-8 Text message.
@(test)
test_decode_single_text :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x81, transmute([]byte)string("hello")))

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "a message should be ready")
    testing.expect_value(t, msg.kind, Message_Kind.Text)
    testing.expect_value(t, string(msg.data), "hello")

    _, has2, _ := decoder_next(&d, context.temp_allocator)
    testing.expect(t, !has2, "no second message buffered")
}

// A binary frame decodes without UTF-8 validation.
@(test)
test_decode_binary :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x82, []byte{0x00, 0xFF, 0x80}))

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "a message should be ready")
    testing.expect_value(t, msg.kind, Message_Kind.Binary)
    testing.expect(t, slice.equal(msg.data, []byte{0x00, 0xFF, 0x80}), "payload preserved")
}

// A text message split across a non-final frame and a continuation reassembles.
@(test)
test_decode_fragmented_text :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0
    decoder_feed(&d, srv_frame(0x80, transmute([]byte)string("lo"))) // continuation, FIN=1

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "reassembled message ready")
    testing.expect_value(t, msg.kind, Message_Kind.Text)
    testing.expect_value(t, string(msg.data), "hello")
}

// A control frame interleaved between data fragments is returned on its own,
// ahead of the still-incomplete data message.
@(test)
test_decode_control_between_fragments :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0
    decoder_feed(&d, srv_frame(0x89, transmute([]byte)string("pp"))) // ping, FIN=1
    decoder_feed(&d, srv_frame(0x80, transmute([]byte)string("lo"))) // continuation, FIN=1

    ping, has1, err1 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err1, Protocol_Error.None)
    testing.expect(t, has1, "ping surfaces first")
    testing.expect_value(t, ping.kind, Message_Kind.Ping)
    testing.expect_value(t, string(ping.data), "pp")

    text, has2, err2 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err2, Protocol_Error.None)
    testing.expect(t, has2, "reassembled text follows")
    testing.expect_value(t, text.kind, Message_Kind.Text)
    testing.expect_value(t, string(text.data), "hello")
}

// A close frame surfaces as Close and its body parses to a code and reason.
@(test)
test_decode_close :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x88, []byte{0x03, 0xE8, 'b', 'y'})) // close 1000 "by"

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "close message ready")
    testing.expect_value(t, msg.kind, Message_Kind.Close)

    parsed, perr := parse_close(msg.data)
    testing.expect_value(t, perr, Protocol_Error.None)
    testing.expect_value(t, parsed.code, Close_Code.Normal_Closure)
    testing.expect_value(t, parsed.reason, "by")
}

// Feeding a frame one byte at a time yields `.Need_More` until the last byte.
@(test)
test_decode_incremental_need_more :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    frame := srv_frame(0x81, transmute([]byte)string("hi")) // 4 bytes total

    for i in 0 ..< len(frame) - 1 {
        decoder_feed(&d, frame[i:i + 1])
        _, has, err := decoder_next(&d, context.temp_allocator)
        testing.expect(t, !has, "not complete yet")
        testing.expect_value(t, err, Protocol_Error.None)
    }

    decoder_feed(&d, frame[len(frame) - 1:])
    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "complete on final byte")
    testing.expect_value(t, string(msg.data), "hi")
}

// Two whole frames delivered in one feed drain as two messages.
@(test)
test_decode_two_messages_one_feed :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    buf := make([dynamic]byte, context.temp_allocator)
    append(&buf, ..srv_frame(0x81, transmute([]byte)string("one")))
    append(&buf, ..srv_frame(0x81, transmute([]byte)string("two")))
    decoder_feed(&d, buf[:])

    m1, h1, _ := decoder_next(&d, context.temp_allocator)
    testing.expect(t, h1, "first ready")
    testing.expect_value(t, string(m1.data), "one")

    m2, h2, _ := decoder_next(&d, context.temp_allocator)
    testing.expect(t, h2, "second ready")
    testing.expect_value(t, string(m2.data), "two")

    _, h3, _ := decoder_next(&d, context.temp_allocator)
    testing.expect(t, !h3, "nothing more")
}

// A continuation frame with no open data message is a protocol error.
@(test)
test_decode_invalid_continuation :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x80, transmute([]byte)string("lo"))) // continuation, no prior

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Invalid_Continuation)
}

// A new data frame while a fragmented message is open is a protocol error.
@(test)
test_decode_interrupted :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0
    decoder_feed(&d, srv_frame(0x81, transmute([]byte)string("new"))) // new text, not continuation

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Interrupted)
}

// A text message with invalid UTF-8 fails per RFC 6455 §5.6.
@(test)
test_decode_invalid_utf8 :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x81, []byte{0x80})) // lone continuation byte

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Invalid_Utf8)
}

// A frame larger than `max_frame_bytes` fails before its payload is buffered.
@(test)
test_decode_frame_too_big :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 3, 1 << 20, .Client, context.temp_allocator) // frame cap = 3
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x81, transmute([]byte)string("hello"))) // 5-byte payload

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Frame_Too_Big)
}

// A reassembled message exceeding `max_message_bytes` fails.
@(test)
test_decode_message_too_big :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 4, .Client, context.temp_allocator) // message cap = 4
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x01, transmute([]byte)string("abc"))) // text, FIN=0 (3 bytes)
    decoder_feed(&d, srv_frame(0x80, transmute([]byte)string("de"))) // continuation (would total 5)

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Message_Too_Big)
}

// Even with a deliberately maximal configured cap, the decoded header plus payload
// length must not overflow the host integer used for buffer slicing.
@(test)
test_decode_rejects_header_plus_payload_length_overflow :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    d: Decoder
    init_err := decoder_init(&d, max(int), max(int), .Client, context.temp_allocator)
    testing.expect(t, init_err == nil, "decoder initializes at a maximal policy cap")
    defer decoder_destroy(&d)

    frame_header: [10]byte
    frame_header[0] = 0x82
    frame_header[1] = 0x7f
    payload_length := u64(max(int))
    for i in 0 ..< 8 {
        frame_header[2 + i] = byte(payload_length >> uint((7 - i) * 8))
    }

    testing.expect(t, decoder_feed(&d, frame_header[:]) == nil, "header fits in decoder scratch")
    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Frame_Length_Overflow)
}

// A payload requiring the 16-bit extended length header decodes end-to-end.
@(test)
test_decode_extended_length_payload :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    payload := make([]byte, 200, context.temp_allocator)
    for i in 0 ..< len(payload) {
        payload[i] = byte('a' + i % 26)
    }

    decoder_feed(&d, srv_frame(0x82, payload)) // binary, FIN=1, 200-byte payload

    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "message ready")
    testing.expect_value(t, msg.kind, Message_Kind.Binary)
    testing.expect(t, slice.equal(msg.data, payload), "payload preserved through extended-length header")
}

// Feeding an extended-length frame one byte at a time yields `.Need_More`
// through both the header's extra length bytes and the payload, completing
// only on the final byte.
@(test)
test_decode_incremental_extended_length_header :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    payload := make([]byte, 200, context.temp_allocator)
    for i in 0 ..< len(payload) {
        payload[i] = byte(i)
    }
    frame := srv_frame(0x82, payload) // 4-byte header + 200-byte payload

    for i in 0 ..< len(frame) - 1 {
        decoder_feed(&d, frame[i:i + 1])
        _, has, err := decoder_next(&d, context.temp_allocator)
        testing.expect(t, !has, "not complete yet")
        testing.expect_value(t, err, Protocol_Error.None)
    }

    decoder_feed(&d, frame[len(frame) - 1:])
    msg, has, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.None)
    testing.expect(t, has, "complete on final byte")
    testing.expect(t, slice.equal(msg.data, payload), "payload preserved")
}

// A close frame and a pong, both interleaved between fragments of an open data
// message, each surface on their own ahead of the eventual reassembled text.
@(test)
test_decode_close_and_pong_interleaved_mid_fragmentation :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0
    decoder_feed(&d, srv_frame(0x8A, transmute([]byte)string("pong"))) // pong, FIN=1
    decoder_feed(&d, srv_frame(0x88, []byte{0x03, 0xE8})) // close 1000, FIN=1
    decoder_feed(&d, srv_frame(0x80, transmute([]byte)string("lo"))) // continuation, FIN=1

    pong, has1, err1 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err1, Protocol_Error.None)
    testing.expect(t, has1, "pong surfaces first")
    testing.expect_value(t, pong.kind, Message_Kind.Pong)

    close_msg, has2, err2 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err2, Protocol_Error.None)
    testing.expect(t, has2, "close surfaces second")
    testing.expect_value(t, close_msg.kind, Message_Kind.Close)

    text, has3, err3 := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err3, Protocol_Error.None)
    testing.expect(t, has3, "reassembled text follows")
    testing.expect_value(t, text.kind, Message_Kind.Text)
    testing.expect_value(t, string(text.data), "hello")
}

// A close frame with a 1-byte body fails at header parsing before `parse_close`
// ever runs, surfacing as `.Bad_Close` through the full decode pipeline.
@(test)
test_decode_close_bad_body_rejected :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer decoder_destroy(&d)

    decoder_feed(&d, srv_frame(0x88, []byte{0x03})) // close, 1-byte body

    _, _, err := decoder_next(&d, context.temp_allocator)
    testing.expect_value(t, err, Protocol_Error.Bad_Close)
}

// A partially reassembled message still pending at `decoder_destroy`, plus a
// control message already drained and freed by the caller, leaves nothing
// behind: every byte the decoder allocated is accounted for.
@(test)
test_decode_ownership_no_leaks_with_partial_message_pending :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    d: Decoder
    decoder_init(&d, 1 << 20, 1 << 20, .Client, tracked)

    decoder_feed(&d, srv_frame(0x01, transmute([]byte)string("hel"))) // text, FIN=0, left open
    decoder_feed(&d, srv_frame(0x89, transmute([]byte)string("pp"))) // ping, FIN=1

    ping, has1, err1 := decoder_next(&d, tracked)
    testing.expect_value(t, err1, Protocol_Error.None)
    testing.expect(t, has1, "ping surfaces first")
    delete(ping.data, tracked)

    _, has2, err2 := decoder_next(&d, tracked)
    testing.expect_value(t, err2, Protocol_Error.None)
    testing.expect(t, !has2, "text message still incomplete")

    decoder_destroy(&d)

    for _, leak in track.allocation_map {
        testing.expectf(t, false, "leaked %v bytes allocated at %v", leak.size, leak.location)
    }
    testing.expect_value(t, len(track.allocation_map), 0)
}
