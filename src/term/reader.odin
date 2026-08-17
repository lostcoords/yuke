package term

import "core:mem"
import "core:strings"

// Bracketed-paste terminator; the reader scans for it while assembling a paste.
PASTE_END :: "\x1b[201~"

// Cap on one assembled paste; past it bytes are dropped and `Paste.truncated` is set.
MAX_PASTE_BYTES :: 4 * 1024 * 1024

// Paste capacity retained after the previous paste borrow expires.
PASTE_KEEP_BYTES :: 64 * 1024
#assert(PASTE_KEEP_BYTES <= MAX_PASTE_BYTES)

// Cap on an unresolved escape sequence held in `tail`. Real sequences are tens of
// bytes; past this it is garbage and the whole tail is dropped to bound growth.
MAX_SEQ_BYTES :: 4096

// Max byte batch accepted by the reusable Reader API; prevents one oversized push from
// inflating retained capacity. Drive uses the smaller `DRIVE_READ_BYTES` granule.
MAX_PUSH_BYTES :: 64 * 1024

// One unresolved sequence plus one fresh stdin read.
MAX_TAIL_BYTES :: MAX_SEQ_BYTES + MAX_PUSH_BYTES

// A whole terminal event handed to the caller. `Paste` borrows the reader buffer.
Paste :: struct {
    text:      string,
    // `text` is a prefix: the paste passed MAX_PASTE_BYTES and was cut.
    truncated: bool,
}

Event :: union {
    Key,
    Mouse,
    Paste,
    Resize,
    Input_Closed,
}

// Why a live drive stopped accepting terminal input. Session and paint may remain live
// until `drive_stop` unless the reader itself failed.
Input_Closed_Reason :: enum {
    None = 0,
    Peer_EOF,
    Recv_Error,
    Reader_Failed,
}

// Input-lifecycle event. Unlike parsed terminal events, this is emitted by `Drive`.
Input_Closed :: struct {
    reason: Input_Closed_Reason,
}

// Failure modes of `reader_push`. `None` is success.
Reader_Error :: enum {
    None,
    Input_Too_Large,
}

// Stateful input assembler — see the module doc for the contract.
Reader :: struct {
    // Backing allocator for `tail` and `paste`, retained for the reader's lifetime.
    allocator:       mem.Allocator,

    // Unconsumed bytes carried across pushes (a partial sequence, or paste tail).
    tail:            [dynamic]u8,

    // First unconsumed byte in `tail`; consumed events advance this instead of
    // shifting the remaining bytes after every event.
    tail_start:      int,

    // Raw content of the paste in progress.
    paste:           [dynamic]u8,

    // Between `Paste_Start` and `Paste_End`; bytes accumulate into `paste`.
    in_paste:        bool,

    // Set when the paste in progress hit `MAX_PASTE_BYTES`.
    paste_truncated: bool,
}

// Create a reader backed by `allocator`; free it with `reader_destroy`. The two
// buffers start empty and allocate lazily on first append, so init itself never
// touches the allocator.
reader_init :: proc(r: ^Reader, allocator: mem.Allocator) {
    r.allocator = allocator
    r.tail.allocator = allocator
    r.paste.allocator = allocator
    r.tail_start = 0
    r.in_paste = false
}

// Free the `tail` and `paste` buffers.
reader_destroy :: proc(r: ^Reader) {
    delete(r.tail)
    delete(r.paste)
}

// Append at most 64 KiB of freshly read bytes; then drain with `reader_next`.
// `Input_Too_Large` leaves the pending bytes unchanged.
reader_push :: proc(r: ^Reader, bytes: []u8) -> Reader_Error {
    if len(bytes) > MAX_PUSH_BYTES {
        return .Input_Too_Large
    }

    pending_len := len(r.tail) - r.tail_start
    if len(bytes) > MAX_TAIL_BYTES - pending_len {
        return .Input_Too_Large
    }

    // Compact once per stdin read, not once per parsed event: draining N events
    // otherwise shifts the tail N times, which is O(n^2) under a burst.
    if r.tail_start != 0 {
        copy(r.tail[:pending_len], r.tail[r.tail_start:])
        resize(&r.tail, pending_len)
        r.tail_start = 0
    }

    append(&r.tail, ..bytes)

    return .None
}

// Next assembled event, or a `nil` event when more bytes are needed. On a returned
// `Paste`, the borrowed slice stays valid until the next paste starts.
reader_next :: proc(r: ^Reader) -> Event {
    for {
        if r.in_paste {
            pending := reader_pending(r)
            if i := strings.index(string(pending), PASTE_END); i >= 0 {
                append_paste(r, pending[:i])

                reader_consume(r, i + len(PASTE_END))
                r.in_paste = false

                // Borrows `paste`; valid only until the next paste begins.
                return Paste{text = string(r.paste[:]), truncated = r.paste_truncated}
            }

            // No terminator yet. Move all but a possible split marker (the last
            // len(PASTE_END)-1 bytes) into the paste buffer; keep the rest.
            keep := min(len(pending), len(PASTE_END) - 1)
            move_to_paste(r, len(pending) - keep)

            return nil
        }

        event, consumed, incomplete := parse(reader_pending(r))
        if incomplete {
            // An oversized unresolved tail is garbage (see MAX_SEQ_BYTES).
            if len(r.tail) - r.tail_start > MAX_SEQ_BYTES {
                reader_clear_tail(r)
            }

            return nil
        }

        reader_consume(r, consumed)
        switch e in event {
        case Key:
            return e
        case Mouse:
            return e
        case Resize:
            return e
        case Paste_Start:
            paste_reset(r)
            r.in_paste = true
        case Paste_End, Invalid:
        // Stray terminator and non-events: drop and keep parsing.
        }
    }
}

// Resolve a pending partial when no more bytes are coming (ESC-timeout / EOF): a
// lone ESC becomes Escape. Returns a `nil` event mid-paste or with an empty tail.
reader_flush :: proc(r: ^Reader) -> Event {
    if r.in_paste || len(r.tail) - r.tail_start == 0 {
        return nil
    }

    ev := flush(reader_pending(r))
    reader_clear_tail(r)
    switch e in ev {
    case Key:
        return e
    case Mouse:
        return e
    case Resize:
        return e
    case Paste_Start, Paste_End, Invalid:
        return nil
    }

    return nil
}

// Unconsumed tail bytes.
reader_pending :: proc(r: ^Reader) -> []u8 {
    return r.tail[r.tail_start:]
}

// Ready `paste` for the next paste. A delivered `Paste` borrows the buffer, so this is the
// first point its capacity can be reduced. Keep a bounded allocation for ordinary reuse.
paste_reset :: proc(r: ^Reader) {
    assert(!r.in_paste, "paste_reset during a paste discards the buffer it borrows")

    if cap(r.paste) > PASTE_KEEP_BYTES {
        clear(&r.paste)

        if shrunk, _ := shrink(&r.paste, PASTE_KEEP_BYTES); !shrunk {
            delete(r.paste)
            r.paste = {}
            r.paste.allocator = r.allocator
        }
    } else {
        clear(&r.paste)
    }

    r.paste_truncated = false
}

// Append `bytes` to the paste buffer, dropping and recording anything past MAX_PASTE_BYTES.
append_paste :: proc(r: ^Reader, bytes: []u8) {
    room := MAX_PASTE_BYTES - len(r.paste)
    if room <= 0 {
        if len(bytes) > 0 {
            r.paste_truncated = true
        }

        return
    }

    n := min(room, len(bytes))
    if n < len(bytes) {
        r.paste_truncated = true
    }

    needed := len(r.paste) + n
    if needed > cap(r.paste) {
        // Preserve geometric growth without allowing capacity the paste hard limit can
        // never use. Odin's generic append otherwise doubles past MAX_PASTE_BYTES.
        grown := 2 * cap(r.paste) + max(8, n)
        target := min(MAX_PASTE_BYTES, max(needed, grown))
        assert(target >= needed && target <= MAX_PASTE_BYTES, "paste reserve escaped its bounds")

        non_zero_reserve(&r.paste, target)
    }

    non_zero_append(&r.paste, ..bytes[:n])
}

// Move `n` tail bytes into `paste` (honoring the cap).
move_to_paste :: proc(r: ^Reader, n: int) {
    append_paste(r, reader_pending(r)[:n])
    reader_consume(r, n)
}

// Drop the first `n` unconsumed bytes of `tail`.
reader_consume :: proc(r: ^Reader, n: int) {
    r.tail_start += n
    if r.tail_start == len(r.tail) {
        reader_clear_tail(r)
    }
}

// Drop all tail bytes (retaining capacity for reuse) and reset the read cursor.
reader_clear_tail :: proc(r: ^Reader) {
    clear(&r.tail)
    r.tail_start = 0
}
