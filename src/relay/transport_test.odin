package relay

import "core:crypto/ecdh"
import "core:mem"
import "core:slice"
import "core:testing"

// The chunk-count and header helpers agree on the FIRST/LAST framing: one chunk up to the max, a
// split past it, and the header bits land on the right chunks.
@(test)
test_transport_chunking_helpers :: proc(t: ^testing.T) {
    testing.expect_value(t, transport_chunk_count(0), 1)
    testing.expect_value(t, transport_chunk_count(1), 1)
    testing.expect_value(t, transport_chunk_count(TRANSPORT_CHUNK_MAX), 1)
    testing.expect_value(t, transport_chunk_count(TRANSPORT_CHUNK_MAX + 1), 2)
    testing.expect_value(t, transport_chunk_count(2 * TRANSPORT_CHUNK_MAX), 2)
    testing.expect_value(t, transport_chunk_count(2 * TRANSPORT_CHUNK_MAX + 1), 3)

    testing.expect_value(t, transport_chunk_header(0, 1), u8(TRANSPORT_CHUNK_FIRST | TRANSPORT_CHUNK_LAST))
    testing.expect_value(t, transport_chunk_header(0, 3), u8(TRANSPORT_CHUNK_FIRST))
    testing.expect_value(t, transport_chunk_header(1, 3), u8(0))
    testing.expect_value(t, transport_chunk_header(2, 3), u8(TRANSPORT_CHUNK_LAST))
}

// A sole chunk completes in one push and its frame aliases the input body — no copy.
@(test)
test_reassembler_single_chunk :: proc(t: ^testing.T) {
    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    chunk := []u8{TRANSPORT_CHUNK_FIRST | TRANSPORT_CHUNK_LAST, 'h', 'i'}

    frame, done, err := reassembler_push(&ra, chunk)
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect(t, done, "a sole chunk completes immediately")
    testing.expect(t, slice.equal(frame, []u8{'h', 'i'}), "frame is the chunk body")
    testing.expect(t, raw_data(frame) == raw_data(chunk[1:]), "a sole chunk is returned without a copy")
}

// FIRST, middle, then LAST reassemble to the concatenated body.
@(test)
test_reassembler_multi_chunk :: proc(t: ^testing.T) {
    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    _, done0, err0 := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_FIRST, 'a', 'b'})
    testing.expect_value(t, err0, Transport_Error.None)
    testing.expect(t, !done0, "the first chunk of many is not complete")

    _, done1, err1 := reassembler_push(&ra, []u8{0, 'c'})
    testing.expect_value(t, err1, Transport_Error.None)
    testing.expect(t, !done1, "a middle chunk is not complete")

    frame, done2, err2 := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_LAST, 'd', 'e'})
    testing.expect_value(t, err2, Transport_Error.None)
    testing.expect(t, done2, "the last chunk completes the frame")
    testing.expect(t, slice.equal(frame, []u8{'a', 'b', 'c', 'd', 'e'}), "the frame is the concatenated bodies")
}

// An empty chunk, a chunk with bits outside the mask, and a continuation with no start all reject.
@(test)
test_reassembler_malformed :: proc(t: ^testing.T) {
    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    _, _, empty := reassembler_push(&ra, nil)
    testing.expect_value(t, empty, Transport_Error.Malformed)

    _, _, bad_bits := reassembler_push(&ra, []u8{0x04, 'x'})
    testing.expect_value(t, bad_bits, Transport_Error.Malformed)

    // A LAST-only chunk with nothing buffered: the FIRST was never seen.
    _, _, orphan := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_LAST, 'x'})
    testing.expect_value(t, orphan, Transport_Error.Malformed)
}

// A reassembly that would pass the frame cap rejects rather than growing without bound.
@(test)
test_reassembler_frame_too_large :: proc(t: ^testing.T) {
    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    first := make([]u8, 1 + TRANSPORT_FRAME_MAX, context.temp_allocator)
    first[0] = TRANSPORT_CHUNK_FIRST

    _, done, err := reassembler_push(&ra, first)
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect(t, !done, "the frame is not yet terminated")

    _, _, over := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_LAST, 'x'})
    testing.expect_value(t, over, Transport_Error.Frame_Too_Large)
}

// A FIRST chunk discards a partial frame whose tail was dropped, so the stream self-corrects.
@(test)
test_reassembler_self_correct :: proc(t: ^testing.T) {
    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    // A frame begins but its tail never arrives (shed under backpressure).
    _, done0, err0 := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_FIRST, 's', 't', 'a', 'l', 'e'})
    testing.expect_value(t, err0, Transport_Error.None)
    testing.expect(t, !done0, "the abandoned frame is still open")

    // The next frame starts fresh; the stale bytes are gone.
    frame, done1, err1 := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_FIRST | TRANSPORT_CHUNK_LAST, 'o', 'k'})
    testing.expect_value(t, err1, Transport_Error.None)
    testing.expect(t, done1, "the fresh frame completes")
    testing.expect(t, slice.equal(frame, []u8{'o', 'k'}), "only the fresh frame's bytes remain")
}

@(test)
test_reassembler_reset_wipes_plaintext :: proc(t: ^testing.T) {
    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    _, done, err := reassembler_push(&ra, []u8{TRANSPORT_CHUNK_FIRST, 's', 'e', 'c', 'r', 'e', 't'})
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect(t, !done, "partial secret frame remains buffered")
    backing := mem.slice_ptr(raw_data(ra.buf), cap(ra.buf))

    reassembler_reset(&ra)
    for byte in backing {
        testing.expect_value(t, byte, u8(0))
    }
}

// A full session round-trip for a frame several packets long: seal each chunk through the Noise
// initiator, open and reassemble on the responder, and recover the original bytes exactly. This
// is the accept criterion for the fix — a frame past the 65535-byte Noise packet limit crosses.
@(test)
test_transport_roundtrip_large_frame :: proc(t: ^testing.T) {
    prologue := transmute([]u8)string("yuke-relay v1")

    server_key: ecdh.Private_Key
    testing.expect(t, ecdh.private_key_generate(&server_key, .X25519), "server key")
    client_key: ecdh.Private_Key
    testing.expect(t, ecdh.private_key_generate(&client_key, .X25519), "client key")

    server_pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&server_pub, &server_key)

    client, server: Session
    session_init_initiator(&client, &client_key, &server_pub, prologue)
    session_init_responder(&server, &server_key, prologue)
    defer session_destroy(&client)
    defer session_destroy(&server)

    msg1, e1 := session_initiate(&client, context.temp_allocator)
    testing.expect_value(t, e1, Noise_Error.None)
    msg2, e2 := session_respond(&server, msg1, context.temp_allocator)
    testing.expect_value(t, e2, Noise_Error.None)
    testing.expect_value(t, session_complete(&client, msg2, context.temp_allocator), Noise_Error.None)

    // A frame that spans four chunks: well past one Noise packet, with a partial final chunk.
    original := make([]u8, 3 * TRANSPORT_CHUNK_MAX + 123, context.temp_allocator)
    for i in 0 ..< len(original) {
        original[i] = u8(i * 31 + 7)
    }

    ra: Reassembler
    reassembler_init(&ra, context.allocator)
    defer reassembler_destroy(&ra)

    count := transport_chunk_count(len(original))
    testing.expect_value(t, count, 4)

    recovered: []u8
    got := false
    for i in 0 ..< count {
        lo := i * TRANSPORT_CHUNK_MAX
        hi := min(lo + TRANSPORT_CHUNK_MAX, len(original))

        chunk := make([]u8, 1 + (hi - lo), context.temp_allocator)
        chunk[0] = transport_chunk_header(i, count)
        copy(chunk[1:], original[lo:hi])

        sealed, se := session_seal(&client, chunk, context.temp_allocator)
        testing.expect_value(t, se, Noise_Error.None)

        opened, oe := session_open(&server, sealed, context.temp_allocator)
        testing.expect_value(t, oe, Noise_Error.None)

        frame, done, re := reassembler_push(&ra, opened)
        testing.expect_value(t, re, Transport_Error.None)

        if done {
            recovered = slice.clone(frame, context.temp_allocator)
            got = true
        }
    }

    testing.expect(t, got, "the final chunk yields the whole frame")
    testing.expect(t, slice.equal(recovered, original), "the reassembled frame matches the original bytes")
}
