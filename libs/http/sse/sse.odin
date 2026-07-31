package sse

// Decoder behaviour and resource bounds.
Config :: struct {
    // Maximum bytes in one physical line, excluding the line ending.
    max_line_bytes:  int,

    // Maximum bytes in the joined `data:` payload for one event.
    max_event_bytes: int,
}

// 1 MiB per line and per event: providers put a whole JSON object on one `data:`
// line, so the line bound must not sit below the event bound.
DEFAULT_CONFIG :: Config {
    max_line_bytes  = 1 << 20,
    max_event_bytes = 1 << 20,
}

Error :: enum {
    None,
    Line_Too_Long,
    Event_Too_Large,
    Out_Of_Memory,
}

// `data` borrows the parser's buffer and is valid for the call only.
// Return false to stop feeding; the caller owns error reporting.
On_Event :: #type proc(user: rawptr, data: string) -> bool

// Incremental SSE parser owning reusable line/data scratch.
Parser :: struct {
    // The current incomplete physical line.
    line:            [dynamic]byte,

    // The joined `data:` payload for the in-progress event.
    data:            [dynamic]byte,

    // Whether at least one `data:` line was seen; gates dispatch and later lines
    // insert '\n' before joining.
    has_data:        bool,

    // Tracks a just-consumed '\r' so a following '\n' is skipped as CRLF, across feeds.
    last_was_cr:     bool,

    // True until the optional leading UTF-8 BOM has been handled.
    at_stream_start: bool,

    // Count of leading BOM bytes matched so far (for a BOM split across chunks).
    bom_matched:     int,

    // Maximum bytes in one physical line, excluding the line ending.
    max_line_bytes:  int,

    // Maximum bytes in the joined `data:` payload for one event.
    max_event_bytes: int,
}

// The UTF-8 byte-order mark the SSE grammar allows at stream start.
@(private)
@(rodata)
BOM := [3]byte{0xEF, 0xBB, 0xBF}

// Creates a parser with no buffered input. Buffers use `allocator` when they grow,
// which must outlive the parser.
parser_init :: proc(p: ^Parser, cfg: Config, allocator := context.allocator) {
    assert(p != nil, "parser_init needs a parser")
    assert(cfg.max_line_bytes > 0, "max_line_bytes must be positive")
    assert(cfg.max_event_bytes > 0, "max_event_bytes must be positive")

    p.line = make([dynamic]byte, allocator)
    p.data = make([dynamic]byte, allocator)
    p.has_data = false
    p.last_was_cr = false
    p.at_stream_start = true
    p.bom_matched = 0
    p.max_line_bytes = cfg.max_line_bytes
    p.max_event_bytes = cfg.max_event_bytes
}

// Releases the parser's buffers.
parser_destroy :: proc(p: ^Parser) {
    assert(p != nil, "parser_destroy needs a parser")
    delete(p.line)
    delete(p.data)
    p^ = {}
}

// Feeds a chunk and emits completed event payloads. A false callback result
// drops the remainder; after any error, destroy or reinitialize the parser.
feed :: proc(p: ^Parser, chunk: []byte, user: rawptr, on_event: On_Event) -> Error {
    assert(p != nil, "feed needs a parser")
    assert(p.max_line_bytes > 0, "max_line_bytes must be positive")
    assert(p.max_event_bytes > 0, "max_event_bytes must be positive")

    input := chunk
    if p.at_stream_start {
        input = consume_bom(p, input) or_return
    }

    for len(input) > 0 {
        // A '\r' just consumed swallows a leading '\n' as one CRLF ending.
        if p.last_was_cr {
            p.last_was_cr = false
            if input[0] == '\n' {
                input = input[1:]
                continue
            }
        }

        idx := find_line_end(input)
        if idx < 0 {
            push_line_bytes(p, input) or_return
            break
        }

        push_line_bytes(p, input[:idx]) or_return
        p.last_was_cr = input[idx] == '\r'
        keep_going := end_line(p, user, on_event) or_return
        input = input[idx + 1:]

        if !keep_going {
            return .None
        }
    }

    return .None
}

// Consumes a leading UTF-8 BOM at stream start (possibly split across chunks),
// returning the remaining input. A partial BOM that diverges replays its matched
// prefix as ordinary line content.
@(private)
consume_bom :: proc(p: ^Parser, input: []byte) -> (remaining: []byte, err: Error) {
    assert(p.at_stream_start, "consume_bom called outside stream start")

    i := 0
    for i < len(input) {
        assert(p.bom_matched < len(BOM), "bom_matched must reset before reaching len(BOM)")
        if input[i] != BOM[p.bom_matched] {
            matched := p.bom_matched
            p.at_stream_start = false
            p.bom_matched = 0
            push_line_bytes(p, BOM[:matched]) or_return
            return input[i:], .None
        }

        p.bom_matched += 1
        i += 1
        if p.bom_matched == len(BOM) {
            p.at_stream_start = false
            p.bom_matched = 0
            return input[i:], .None
        }
    }

    return input[i:], .None
}

// Appends line-content bytes to the current line, enforcing the per-line cap.
@(private)
push_line_bytes :: proc(p: ^Parser, bytes: []byte) -> Error {
    if len(p.line) + len(bytes) > p.max_line_bytes {
        return .Line_Too_Long
    }

    _, aerr := append(&p.line, ..bytes)
    if aerr != nil {
        return .Out_Of_Memory
    }

    // Only reachable if the parser's validated internal state was corrupted.
    assert(len(p.line) <= p.max_line_bytes, "line buffer exceeds its cap")

    return .None
}

// Completes the current physical line: a blank line dispatches the event if any
// `data:` line was seen, else the line is parsed as a field and only `data`
// retained. Clears the line either way.
@(private)
end_line :: proc(p: ^Parser, user: rawptr, on_event: On_Event) -> (keep_going: bool, err: Error) {
    if len(p.line) == 0 {
        if !p.has_data {
            return true, .None
        }

        assert(len(p.data) <= p.max_event_bytes, "event payload exceeds its cap")
        keep_going = on_event(user, string(p.data[:]))
        clear(&p.data)
        p.has_data = false

        return keep_going, .None
    }

    if p.line[0] == ':' {
        clear(&p.line)
        return true, .None
    }

    // Only `data` is retained, matching what downstream decoders read; other
    // fields are parsed and dropped without affecting dispatch.
    colon := find_colon(p.line[:])
    name, value: []byte
    if colon >= 0 {
        name = p.line[:colon]
        value = p.line[colon + 1:]
    } else {
        name = p.line[:]
    }

    if len(value) > 0 && value[0] == ' ' {
        value = value[1:]
    }

    if string(name) == "data" {
        extra := len(value)
        if p.has_data {
            extra += 1
        }

        if len(p.data) + extra > p.max_event_bytes {
            err = .Event_Too_Large
            return
        }

        if p.has_data {
            _, aerr := append(&p.data, byte('\n'))
            if aerr != nil {
                err = .Out_Of_Memory
                return
            }
        }

        _, aerr := append(&p.data, ..value)
        if aerr != nil {
            err = .Out_Of_Memory
            return
        }

        p.has_data = true
        assert(len(p.data) <= p.max_event_bytes, "event payload exceeds its cap")
    }

    clear(&p.line)

    return true, .None
}

// Returns the line-ending index, or -1 when none is present.
@(private)
find_line_end :: proc(input: []byte) -> int {
    for b, i in input {
        if b == '\n' || b == '\r' {
            return i
        }
    }

    return -1
}

// Returns the colon index, or -1 when none is present.
@(private)
find_colon :: proc(bytes: []byte) -> int {
    for b, i in bytes {
        if b == ':' {
            return i
        }
    }

    return -1
}
