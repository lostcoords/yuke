package websocket

import "core:slice"
import "core:unicode/utf8"

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
    // Received bytes not yet consumed. `head` marks the start of unconsumed data;
    // the consumed prefix is reclaimed on the next `decoder_feed`.
    scratch:           [dynamic]byte,

    // Offset of the first unconsumed byte within `scratch`.
    head:              int,

    // Accumulator for the fragments of the data message currently in progress.
    message:           [dynamic]byte,

    // Opcode (Text or Binary) of the fragmented message in progress, if any.
    continuing:        Maybe(Op_Code),

    // Reject any single frame whose announced payload exceeds this many bytes.
    max_frame_bytes:   int,

    // Reject any reassembled message that would exceed this many bytes.
    max_message_bytes: int,
}

// Initialize a decoder with the given size caps. Internal buffers are allocated
// from `allocator`, which must outlive the decoder.
decoder_init :: proc(d: ^Decoder, max_frame_bytes, max_message_bytes: int, allocator := context.allocator) {
    d.scratch = make([dynamic]byte, allocator)
    d.message = make([dynamic]byte, allocator)
    d.head = 0
    d.continuing = nil
    d.max_frame_bytes = max_frame_bytes
    d.max_message_bytes = max_message_bytes
}

// Release the decoder's buffers. Does not free `Message.data` from `decoder_next`
// — that is owned by the caller.
decoder_destroy :: proc(d: ^Decoder) {
    delete(d.scratch)
    delete(d.message)
    d^ = {}
}

// Append received bytes, first reclaiming the consumed prefix so buffered memory
// stays bounded by the unconsumed tail plus this chunk.
decoder_feed :: proc(d: ^Decoder, data: []byte) {
    if d.head > 0 {
        remaining := len(d.scratch) - d.head
        if remaining > 0 {
            copy(d.scratch[:remaining], d.scratch[d.head:])
        }

        resize(&d.scratch, remaining)
        d.head = 0
    }

    append(&d.scratch, ..data)
}

// Decode the next complete message from buffered bytes. `has_msg` is true when a
// full message was produced (its `data` is allocated in `out`, caller-owned);
// false with `err == .None` means more bytes are needed. A non-`.None` `err` is a
// protocol violation and the connection must be failed.
decoder_next :: proc(d: ^Decoder, out := context.allocator) -> (msg: Message, has_msg: bool, err: Protocol_Error) {
    for {
        buf := d.scratch[d.head:]

        header, header_len, status, perr := parse_header(buf)
        if perr != .None {
            return {}, false, perr
        }

        if status == .Need_More {
            return {}, false, .None
        }

        // Enforce the single-frame cap on the announced length before buffering the
        // payload, so an oversized frame fails fast.
        if header.len > d.max_frame_bytes {
            return {}, false, .Frame_Too_Big
        }

        frame_len := header_len + header.len
        if len(buf) < frame_len {
            return {}, false, .None
        }

        payload := buf[header_len:frame_len]

        if op_code_is_control(header.opcode) {
            // `parse_header` already rejected fragmented control frames, so a whole
            // control message is present; hand it up, the driver decides to reply.
            kind: Message_Kind = header.opcode == .Ping ? .Ping : header.opcode == .Pong ? .Pong : .Close
            out_data := slice.clone(payload, out)
            d.head += frame_len

            return Message{kind = kind, data = out_data}, true, .None
        }

        // Written as `header.len > budget` (not `len(d.message) + header.len > cap`)
        // so a cap near `max(int)` cannot overflow the addition. `len(d.message)
        // <= cap` is a loop invariant, so the subtraction never wraps.
        if header.len > d.max_message_bytes - len(d.message) {
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

        append(&d.message, ..payload)
        d.head += frame_len

        if !header.fin {
            continue
        }

        // Text must be valid UTF-8 (RFC 6455 §5.6). Validate before cloning so the
        // failure path allocates nothing.
        if message_opcode == .Text && !utf8.valid_string(string(d.message[:])) {
            clear(&d.message)
            return {}, false, .Invalid_Utf8
        }

        out_data := slice.clone(d.message[:], out)
        clear(&d.message)

        kind: Message_Kind = message_opcode == .Text ? .Text : .Binary

        return Message{kind = kind, data = out_data}, true, .None
    }
}
