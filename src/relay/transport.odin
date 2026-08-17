// Transport fragmentation for the relay session: a wire frame larger than one Noise packet is
// split across ordered SEALED frames and reassembled on the far end. Both roles share it — the
// daemon responder and the client initiator fragment and reassemble identically. It sits above
// `Session`: the sender seals each chunk, the receiver opens each then feeds it here.
//
// This mirrors WebSocket's own fragmentation (a FIRST/LAST pair, like FIN plus a continuation
// opcode): the header is one byte inside the sealed, authenticated plaintext — invisible to and
// untamperable by the relay. The envelope tag stays `.Sealed`, so the relay and the wire protocol
// are unchanged; a large frame is simply more SEALED frames. Chunk bytes arrive from the peer, so
// a malformed one degrades to a `Transport_Error` the caller closes the link on, never a crash.
package relay

import "core:crypto"
import "core:crypto/noise"

// The 1-byte chunk header, prepended to each chunk's plaintext before sealing. A sole chunk
// carries both bits; a middle chunk carries neither. Any other bit set is a framing violation.
TRANSPORT_CHUNK_FIRST :: 0x01
TRANSPORT_CHUNK_LAST :: 0x02

// @private
// The set of defined header bits; a chunk with a bit outside it is `.Malformed`.
TRANSPORT_CHUNK_FLAGS :: u8(TRANSPORT_CHUNK_FIRST | TRANSPORT_CHUNK_LAST)

// Max plaintext bytes per chunk: the Noise packet budget less its tag and the 1-byte header.
TRANSPORT_CHUNK_MAX :: noise.MAX_PACKET_SIZE - noise.TAG_SIZE - 1

// Max reassembled frame, in bytes. Parity with the WebSocket message cap (`max_message_bytes`,
// 1 MiB) the local transport already enforces, so the relay path carries exactly what a local
// client does; larger transfers are out of band (`/aux` blobs).
TRANSPORT_FRAME_MAX :: 1 << 20

#assert(TRANSPORT_CHUNK_MAX > 0)

// Why a chunk could not be reassembled.
Transport_Error :: enum {
    // No error.
    None,

    // A chunk with no header byte, unknown header bits, or a continuation with no start.
    Malformed,

    // The reassembled frame would exceed `TRANSPORT_FRAME_MAX`.
    Frame_Too_Large,
}

// Reassembles a fragmented wire frame from its chunks. One per session receive direction; reset
// after each completed frame and on session teardown, freed with `reassembler_destroy`.
Reassembler :: struct {
    // @private
    // Accumulates chunk bodies until the LAST chunk; empty between frames. Only a multi-chunk
    // frame touches it — a sole chunk returns its body directly, without a copy.
    buf: [dynamic]u8,
}

// The number of chunks a `length`-byte frame fragments into, always at least one (a zero-length
// frame still sends one empty chunk).
transport_chunk_count :: proc(length: int) -> int {
    assert(length >= 0, "frame length is non-negative")

    if length <= TRANSPORT_CHUNK_MAX {
        return 1
    }

    return (length + TRANSPORT_CHUNK_MAX - 1) / TRANSPORT_CHUNK_MAX
}

// The header byte for chunk `index` of `count` total. FIRST on the first chunk, LAST on the last;
// a sole chunk (`count == 1`) carries both.
transport_chunk_header :: proc(index, count: int) -> u8 {
    assert(count >= 1, "a frame has at least one chunk")
    assert(index >= 0 && index < count, "chunk index out of range")

    flags: u8
    if index == 0 {
        flags |= TRANSPORT_CHUNK_FIRST
    }

    if index == count - 1 {
        flags |= TRANSPORT_CHUNK_LAST
    }

    return flags
}

// Seal one chunk of a fragmented frame into a ready-to-send SEALED envelope: prepend the
// 1-byte FIRST/LAST header to `body`, seal it, and encode the `.Sealed` frame — the single
// per-chunk operation both roles' send loops share, so the nonce-advancing framing lives in one
// place. The bytes are allocated from `allocator`; the caller queues them on its link and maps a
// seal failure to its own send policy (a sealed chunk cannot be shed, so that mapping differs by
// role and stays with the caller).
transport_seal_chunk :: proc(
    sess: ^Session,
    body: []u8,
    index, count: int,
    allocator := context.allocator,
) -> (
    []u8,
    Noise_Error,
) {
    chunk := make([]u8, 1 + len(body), allocator)
    chunk[0] = transport_chunk_header(index, count)
    copy(chunk[1:], body)

    sealed, serr := session_seal(sess, chunk, allocator)
    if serr != .None {
        return nil, serr
    }

    return frame_encode(Frame{type = .Sealed, payload = sealed}, allocator), .None
}

// Open one inbound SEALED payload and feed it to the reassembler — the per-frame receive step
// both roles share. `ok` is false when the payload failed to decrypt or the chunk violated the
// framing, both of which the caller closes the link on; on `ok && done`, `frame` is the complete
// wire frame, aliasing the reassembler or the opened chunk until the next push or reset.
transport_open_fragment :: proc(
    sess: ^Session,
    reasm: ^Reassembler,
    payload: []u8,
    allocator := context.allocator,
) -> (
    frame: []u8,
    done: bool,
    ok: bool,
) {
    chunk, oerr := session_open(sess, payload, allocator)
    if oerr != .None {
        return nil, false, false
    }

    rerr: Transport_Error
    frame, done, rerr = reassembler_push(reasm, chunk)
    if rerr != .None {
        return nil, false, false
    }

    return frame, done, true
}

// Prepare a reassembler backed by `allocator`. Its buffer grows on demand and is bounded by
// `TRANSPORT_FRAME_MAX`.
reassembler_init :: proc(r: ^Reassembler, allocator := context.allocator) {
    assert(r != nil, "reassembler_init needs storage")

    r^ = {}
    r.buf.allocator = allocator
}

// Drop any partial frame, keeping the buffer's capacity. Call after consuming a completed frame
// and whenever the session is torn down, so a fresh peer never inherits stale bytes.
reassembler_reset :: proc(r: ^Reassembler) {
    assert(r != nil, "reassembler_reset needs a reassembler")

    if len(r.buf) > 0 {
        crypto.zero_explicit(raw_data(r.buf[:]), len(r.buf))
    }
    clear(&r.buf)
}

// Release the reassembler's buffer. Safe on a zero-valued reassembler.
reassembler_destroy :: proc(r: ^Reassembler) {
    assert(r != nil, "reassembler_destroy needs a reassembler")

    if cap(r.buf) > 0 {
        crypto.zero_explicit(raw_data(r.buf), cap(r.buf))
    }
    delete(r.buf)
    r^ = {}
}

reassembler_append :: proc(r: ^Reassembler, body: []u8) {
    assert(r != nil, "reassembler append needs a reassembler")
    assert(len(r.buf) + len(body) <= TRANSPORT_FRAME_MAX, "reassembler append exceeds its bound")
    if len(body) == 0 {
        return
    }

    old_len := len(r.buf)
    needed := old_len + len(body)
    if needed > cap(r.buf) {
        allocator := r.buf.allocator
        new_capacity := min(TRANSPORT_FRAME_MAX, max(needed, max(64, cap(r.buf) * 2)))
        replacement := make([dynamic]u8, old_len, new_capacity, allocator)
        copy(replacement[:], r.buf[:])
        reassembler_destroy(r)
        r.buf = replacement
    }

    resize(&r.buf, needed)
    copied := copy(r.buf[old_len:], body)
    assert(copied == len(body), "reassembler append was short")
}

// Feed one opened chunk (a header byte then its body) into the reassembler. When the chunk was
// the LAST, `done` is true and `frame` is the complete wire frame; otherwise `done` is false and
// `frame` is nil. On a sole chunk `frame` aliases `chunk`; on a multi-chunk frame it aliases the
// reassembler's buffer — either way valid only until the next push or reset. A FIRST chunk drops
// any buffered partial, so a frame whose tail was shed self-corrects at the next frame's start.
reassembler_push :: proc(r: ^Reassembler, chunk: []u8) -> (frame: []u8, done: bool, err: Transport_Error) {
    assert(r != nil, "reassembler_push needs a reassembler")

    if len(chunk) == 0 {
        return nil, false, .Malformed
    }

    flags := chunk[0]
    body := chunk[1:]

    if flags & ~TRANSPORT_CHUNK_FLAGS != 0 {
        return nil, false, .Malformed
    }

    is_first := flags & TRANSPORT_CHUNK_FIRST != 0
    is_last := flags & TRANSPORT_CHUNK_LAST != 0

    // Sole chunk on an empty buffer: hand the body straight back, no copy.
    if is_first && is_last && len(r.buf) == 0 {
        return body, true, .None
    }

    if is_first {
        reassembler_reset(r)
    } else if len(r.buf) == 0 {
        // A continuation with no started frame: the peer skipped a FIRST. Only a sender bug or a
        // forged/reordered stream reaches here — Noise counters already reject reordering.
        return nil, false, .Malformed
    }

    if len(r.buf) + len(body) > TRANSPORT_FRAME_MAX {
        return nil, false, .Frame_Too_Large
    }

    reassembler_append(r, body)

    if is_last {
        return r.buf[:], true, .None
    }

    return nil, false, .None
}
