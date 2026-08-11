package websocket

import "base:runtime"
import "core:crypto"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"

bytes_zero :: proc(data: []byte) {
    if len(data) > 0 {
        crypto.zero_explicit(raw_data(data), len(data))
    }
}

owned_bytes_destroy :: proc(data: []byte, allocator: mem.Allocator) {
    bytes_zero(data)
    delete(data, allocator)
}

dynamic_bytes_destroy :: proc(data: ^[dynamic]byte) {
    assert(data != nil, "dynamic byte cleanup needs storage")
    if cap(data^) > 0 {
        crypto.zero_explicit(raw_data(data^), cap(data^))
    }
    delete(data^)
    data^ = nil
}

dynamic_bytes_clear :: proc(data: ^[dynamic]byte) {
    assert(data != nil, "dynamic byte reset needs storage")
    bytes_zero(data^[:])
    clear(data)
}

dynamic_bytes_append :: proc(data: ^[dynamic]byte, added: []byte) -> runtime.Allocator_Error {
    assert(data != nil, "dynamic byte append needs storage")
    if len(added) == 0 {
        return nil
    }
    if len(added) > max(int) - len(data^) {
        return runtime.Allocator_Error.Out_Of_Memory
    }

    old_len := len(data^)
    needed := old_len + len(added)
    if needed > cap(data^) {
        allocator := data^.allocator
        new_capacity := max(needed, max(64, min(cap(data^), max(int) / 2) * 2))
        replacement, aerr := make([dynamic]byte, old_len, new_capacity, allocator)
        if aerr != nil {
            return aerr
        }
        copy(replacement[:], data^[:])
        dynamic_bytes_destroy(data)
        data^ = replacement
    }

    resize(data, needed)
    copied := copy(data^[old_len:], added)
    assert(copied == len(added), "dynamic byte append was short")

    return nil
}

// The kind of a decoded message. Ping/Pong/Close are control frames the driver
// acts on; Text/Binary are application payloads.
Message_Kind :: enum {
    // Text data; `data` has been validated as UTF-8.
    Text,

    // Binary data; `data` is uninterpreted bytes.
    Binary,

    // Ping control frame; the driver should answer with a matching Pong.
    Ping,

    // Pong control frame; typically ignored.
    Pong,

    // Close control frame; `data` is the close body (parse with `parse_close`).
    Close,
}

// One complete decoded message. `data` is allocated in the `out` allocator passed
// to `decoder_next` and owned by the caller (free with `delete(data, out)`).
Message :: struct {
    // Message classification.
    kind: Message_Kind,

    // Payload bytes, owned by the caller (see above).
    data: []byte,
}

// Streaming reassembly state for one connection. Internal buffers capture the
// allocator from `decoder_init` and are released by `decoder_destroy`.
Decoder :: struct {
    // @private
    // Received bytes not yet consumed. `head` marks the start of unconsumed data;
    // the consumed prefix is reclaimed on the next `decoder_feed`.
    scratch:           [dynamic]byte,

    // @private
    // Offset of the first unconsumed byte within `scratch`.
    head:              int,

    // @private
    // Accumulator for the fragments of the data message currently in progress.
    message:           [dynamic]byte,

    // @private
    // Opcode (Text or Binary) of the fragmented message in progress, if any.
    continuing:        Maybe(Op_Code),

    // @private
    // Direction this decoder reads for. `.Client` rejects masked frames; `.Server`
    // requires masking and unmasks each payload in place before surfacing it.
    role:              Role,

    // @private
    // Reject any single frame whose announced payload exceeds this many bytes.
    max_frame_bytes:   int,

    // @private
    // Reject any reassembled message that would exceed this many bytes.
    max_message_bytes: int,
}

// Initialize a decoder with the given size caps and direction. Internal buffers are
// allocated from `allocator`, which must outlive the decoder.
decoder_init :: proc(
    d: ^Decoder,
    max_frame_bytes, max_message_bytes: int,
    role: Role,
    allocator := context.allocator,
) -> runtime.Allocator_Error {
    assert(d != nil, "decoder_init needs a decoder")
    assert(max_frame_bytes > 0 && max_message_bytes > 0, "decoder limits must be positive")
    assert(role == .Client || role == .Server, "decoder role is invalid")

    scratch, aerr := make([dynamic]byte, allocator)
    if aerr != nil {
        return aerr
    }

    message: [dynamic]byte
    message, aerr = make([dynamic]byte, allocator)
    if aerr != nil {
        dynamic_bytes_destroy(&scratch)
        return aerr
    }

    d.scratch = scratch
    d.message = message
    d.head = 0
    d.continuing = nil
    d.role = role
    d.max_frame_bytes = max_frame_bytes
    d.max_message_bytes = max_message_bytes

    return nil
}

// Release the decoder's buffers. Does not free `Message.data` from `decoder_next`
// — that is owned by the caller.
decoder_destroy :: proc(d: ^Decoder) {
    assert(d != nil, "decoder_destroy needs a decoder")
    assert(d.head >= 0 && d.head <= len(d.scratch), "decoder head outside scratch")

    dynamic_bytes_destroy(&d.scratch)
    dynamic_bytes_destroy(&d.message)
    d^ = {}
}

// Append received bytes, first reclaiming the consumed prefix so buffered memory
// stays bounded by the unconsumed tail plus this chunk.
decoder_feed :: proc(d: ^Decoder, data: []byte) -> runtime.Allocator_Error {
    assert(d != nil, "decoder_feed needs a decoder")
    assert(d.head >= 0 && d.head <= len(d.scratch), "decoder head outside scratch")

    if d.head > 0 {
        remaining := len(d.scratch) - d.head
        if remaining > 0 {
            copy(d.scratch[:remaining], d.scratch[d.head:])
        }

        bytes_zero(d.scratch[remaining:])
        resize(&d.scratch, remaining)
        d.head = 0
    }

    return dynamic_bytes_append(&d.scratch, data)
}

// Decode the next complete message from buffered bytes. `has_msg` is true when a
// full message was produced (its `data` is allocated in `out`, caller-owned);
// false with `err == .None` means more bytes are needed. A non-`.None` `err` is a
// protocol violation and the connection must be failed.
decoder_next :: proc(d: ^Decoder, out := context.allocator) -> (msg: Message, has_msg: bool, err: Protocol_Error) {
    assert(d != nil, "decoder_next needs a decoder")
    assert(d.head >= 0 && d.head <= len(d.scratch), "decoder head outside scratch")
    assert(len(d.message) <= d.max_message_bytes, "reassembly buffer exceeds its cap")

    for {
        buf := d.scratch[d.head:]

        header, header_length, status, perr := parse_header(buf, d.role)
        if perr != .None {
            return {}, false, perr
        }

        if status == .Need_More {
            return {}, false, .None
        }

        // Enforce the single-frame cap on the announced length before buffering the
        // payload, so an oversized frame fails fast.
        if header.payload_length > d.max_frame_bytes {
            return {}, false, .Frame_Too_Big
        }

        if header.payload_length > max(int) - header_length {
            return {}, false, .Frame_Length_Overflow
        }

        frame_length := header_length + header.payload_length
        if len(buf) < frame_length {
            return {}, false, .None
        }

        payload := buf[header_length:frame_length]

        if header.masked {
            // Server role: unmask in place on scratch before the payload is cloned
            // out (control frames) or appended to the reassembly buffer (data).
            mask_payload(payload, payload, header.mask_key)
        }

        if op_code_is_control(header.opcode) {
            // `parse_header` already rejected fragmented control frames, so a whole
            // control message is present; hand it up, the driver decides to reply.
            kind: Message_Kind = header.opcode == .Ping ? .Ping : header.opcode == .Pong ? .Pong : .Close
            out_data, aerr := slice.clone(payload, out)
            if aerr != nil {
                return {}, false, .Out_Of_Memory
            }

            bytes_zero(payload)
            d.head += frame_length

            return {kind = kind, data = out_data}, true, .None
        }

        // Written as `payload_length > budget` (not an overflowing addition), so a
        // cap near `max(int)` is safe. `len(d.message)
        // <= cap` is a loop invariant, so the subtraction never wraps.
        if header.payload_length > d.max_message_bytes - len(d.message) {
            return {}, false, .Message_Too_Big
        }

        // Resolve this frame's data opcode and update fragmentation state: a
        // continuation must follow an open message; a fresh data frame must not
        // interrupt one.
        message_opcode: Op_Code
        if header.opcode == .Continuation {
            recalled, open := d.continuing.?
            if !open {
                return {}, false, .Invalid_Continuation
            }

            if header.fin {
                d.continuing = nil
            }

            message_opcode = recalled
        } else {
            if d.continuing != nil {
                return {}, false, .Interrupted
            }

            if !header.fin {
                d.continuing = header.opcode
            }

            message_opcode = header.opcode
        }

        if aerr := dynamic_bytes_append(&d.message, payload); aerr != nil {
            return {}, false, .Out_Of_Memory
        }
        bytes_zero(payload)

        d.head += frame_length

        if !header.fin {
            continue
        }

        // Text must be valid UTF-8 (RFC 6455 §5.6). Validate before cloning so the
        // failure path allocates nothing.
        if message_opcode == .Text && !utf8.valid_string(string(d.message[:])) {
            dynamic_bytes_clear(&d.message)
            return {}, false, .Invalid_Utf8
        }

        out_data, aerr := slice.clone(d.message[:], out)
        if aerr != nil {
            return {}, false, .Out_Of_Memory
        }
        dynamic_bytes_clear(&d.message)

        kind: Message_Kind = message_opcode == .Text ? .Text : .Binary

        return {kind = kind, data = out_data}, true, .None
    }
}
