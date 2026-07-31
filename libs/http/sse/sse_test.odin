package sse

import "core:strings"
import "core:testing"

// Appends a clone of `data` to the `[dynamic]string` pointed at by `user`, since
// `data` only borrows the parser's buffer for the call.
@(private)
collect_event :: proc(user: rawptr, data: string) -> bool {
    out := cast(^[dynamic]string)user
    append(out, strings.clone(data, context.temp_allocator))

    return true
}

// Feeds the whole input in one call and returns every completed event's data.
@(private)
events :: proc(t: ^testing.T, input: string) -> [dynamic]string {
    p: Parser
    parser_init(&p, DEFAULT_CONFIG, context.temp_allocator)
    defer parser_destroy(&p)

    out := make([dynamic]string, context.temp_allocator)
    feed_err := feed(&p, transmute([]byte)input, &out, collect_event)
    testing.expect_value(t, feed_err, Error.None)

    return out
}

@(test)
test_single_event_with_data :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "data: hello\n\n")
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "hello")
}

// A `data:` line with an empty value still sets `has_data`, so the blank line
// after it dispatches an empty-string event.
@(test)
test_empty_data_value_still_dispatches :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "data:\n\n")
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "")
}

@(test)
test_multiple_events :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "data: one\n\ndata: two\n\n")
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], "one")
    testing.expect_value(t, out[1], "two")
}

@(test)
test_fragmented_input_across_boundaries :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    p: Parser
    parser_init(&p, DEFAULT_CONFIG, context.temp_allocator)
    defer parser_destroy(&p)

    out := make([dynamic]string, context.temp_allocator)
    testing.expect_value(t, feed(&p, transmute([]byte)string("da"), &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 0)

    testing.expect_value(t, feed(&p, transmute([]byte)string("ta: hel"), &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 0)

    testing.expect_value(t, feed(&p, transmute([]byte)string("lo\n\n"), &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "hello")
}

@(test)
test_multi_line_data_joined_with_newline :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "data: hello\ndata: world\n\n")
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "hello\nworld")
}

// Comments and unknown fields are parsed and dropped; the event still dispatches
// because a `data:` line is also present.
@(test)
test_comment_and_unknown_fields_are_dropped_but_data_line_still_dispatches :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, ": keep-alive\nevent: message\nid: 1\ndata: hi\n\n")
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "hi")
}

@(test)
test_supports_lf_crlf_and_lone_cr :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    lf := events(t, "data: lf\n\n")
    testing.expect_value(t, len(lf), 1)
    testing.expect_value(t, lf[0], "lf")

    crlf := events(t, "data: crlf\r\n\r\n")
    testing.expect_value(t, len(crlf), 1)
    testing.expect_value(t, crlf[0], "crlf")

    cr := events(t, "data: cr\r\r")
    testing.expect_value(t, len(cr), 1)
    testing.expect_value(t, cr[0], "cr")
}

// `last_was_cr` persists across `feed` calls: a chunk ending in '\r' followed by a
// chunk starting with '\n' is one CRLF terminator, not a blank line plus content.
@(test)
test_cr_lf_split_across_feeds_is_one_terminator :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    p: Parser
    parser_init(&p, DEFAULT_CONFIG, context.temp_allocator)
    defer parser_destroy(&p)

    out := make([dynamic]string, context.temp_allocator)
    testing.expect_value(t, feed(&p, transmute([]byte)string("data: a\r"), &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 0)

    // A per-feed reset of `last_was_cr` would treat the leading '\n' here as a
    // second, blank line ending, splitting this into two events instead of one.
    testing.expect_value(t, feed(&p, transmute([]byte)string("\ndata: b\n\n"), &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "a\nb")
}

@(test)
test_blank_frames_do_not_dispatch :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "\n\n\r\n")
    testing.expect_value(t, len(out), 0)
}

@(test)
test_leading_bom_is_stripped :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "\xEF\xBB\xBFdata: hello\n\n")
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "hello")
}

@(test)
test_leading_bom_split_across_chunks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    p: Parser
    parser_init(&p, DEFAULT_CONFIG, context.temp_allocator)
    defer parser_destroy(&p)

    out := make([dynamic]string, context.temp_allocator)
    testing.expect_value(t, feed(&p, []byte{0xEF}, &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 0)

    testing.expect_value(t, feed(&p, []byte{0xBB}, &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 0)

    tail := transmute([]byte)string("\xBFdata: hello\n\n")
    testing.expect_value(t, feed(&p, tail, &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "hello")
}

// A partial BOM that diverges replays its matched prefix as ordinary line content
// instead of discarding it. Here the replayed byte prepends onto "data", making the
// field name "\xEFdata" — unknown, so it does not dispatch; discarding the matched
// prefix instead would leave a real "data" field and wrongly dispatch "hi". A
// second, unprefixed event in the same stream proves parsing recovered.
@(test)
test_bom_divergence_replays_matched_prefix_as_line_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    p: Parser
    parser_init(&p, DEFAULT_CONFIG, context.temp_allocator)
    defer parser_destroy(&p)

    out := make([dynamic]string, context.temp_allocator)
    chunk := transmute([]byte)string("\xEFdata: hi\n\ndata: ok\n\n")
    testing.expect_value(t, feed(&p, chunk, &out, collect_event), Error.None)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "ok")
}

// Exactly one leading space after the colon is stripped; further spaces are data.
@(test)
test_exactly_one_leading_space_after_colon_is_stripped :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "data:  x\n\n")
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], " x")
}

// A colon-less non-empty line is field name = whole line, value = "". A non-"data"
// name is dropped and never dispatches; a colon-less "data" line is still
// recognized as the data field and dispatches an empty-string event.
@(test)
test_colon_less_line_is_field_name_with_empty_value :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "foo\n\n")
    testing.expect_value(t, len(out), 0)

    data_out := events(t, "data\n\n")
    testing.expect_value(t, len(data_out), 1)
    testing.expect_value(t, data_out[0], "")
}

// Only a `data:` line makes an event dispatchable; comments never do.
@(test)
test_comment_only_lines_never_dispatch :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, ": just a keep-alive\n: another\n\n")
    testing.expect_value(t, len(out), 0)
}

// Unknown fields are parsed and dropped; with no `data:` line present, the event
// never dispatches (WHATWG's dispatch step requires a non-empty data buffer).
@(test)
test_unknown_field_alone_does_not_dispatch :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    out := events(t, "id: 1\n\n")
    testing.expect_value(t, len(out), 0)
}

// `max_line_bytes` excludes the terminator: a line of exactly the cap fits, one
// byte more does not.
@(test)
test_oversized_line_errors :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cfg := Config {
        max_line_bytes  = 4,
        max_event_bytes = DEFAULT_CONFIG.max_event_bytes,
    }

    fits: Parser
    parser_init(&fits, cfg, context.temp_allocator)
    defer parser_destroy(&fits)

    fits_out := make([dynamic]string, context.temp_allocator)
    fits_err := feed(&fits, transmute([]byte)string("data\n\n"), &fits_out, collect_event)
    testing.expect_value(t, fits_err, Error.None)

    too_long: Parser
    parser_init(&too_long, cfg, context.temp_allocator)
    defer parser_destroy(&too_long)

    too_long_out := make([dynamic]string, context.temp_allocator)
    too_long_err := feed(&too_long, transmute([]byte)string("data:"), &too_long_out, collect_event)
    testing.expect_value(t, too_long_err, Error.Line_Too_Long)
}

// `max_event_bytes` counts the joining '\n' before it is appended: "hello" (5) +
// '\n' (1) + "world" (5) is 11, so a cap of 10 rejects it and a cap of 11 admits it.
@(test)
test_oversized_event_errors :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    too_small: Parser
    too_small_cfg := Config {
        max_line_bytes  = DEFAULT_CONFIG.max_line_bytes,
        max_event_bytes = 10,
    }
    parser_init(&too_small, too_small_cfg, context.temp_allocator)
    defer parser_destroy(&too_small)

    too_small_out := make([dynamic]string, context.temp_allocator)
    too_small_err := feed(
        &too_small,
        transmute([]byte)string("data: hello\ndata: world\n\n"),
        &too_small_out,
        collect_event,
    )
    testing.expect_value(t, too_small_err, Error.Event_Too_Large)

    fits: Parser
    fits_cfg := Config {
        max_line_bytes  = DEFAULT_CONFIG.max_line_bytes,
        max_event_bytes = 11,
    }
    parser_init(&fits, fits_cfg, context.temp_allocator)
    defer parser_destroy(&fits)

    fits_out := make([dynamic]string, context.temp_allocator)
    fits_err := feed(&fits, transmute([]byte)string("data: hello\ndata: world\n\n"), &fits_out, collect_event)
    testing.expect_value(t, fits_err, Error.None)
    testing.expect_value(t, len(fits_out), 1)
    testing.expect_value(t, fits_out[0], "hello\nworld")
}

// `On_Event` returning false stops feeding immediately; `feed` still returns `.None`.
@(test)
test_on_event_returning_false_stops_feeding :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    p: Parser
    parser_init(&p, DEFAULT_CONFIG, context.temp_allocator)
    defer parser_destroy(&p)

    out := make([dynamic]string, context.temp_allocator)
    stop_after_one :: proc(user: rawptr, data: string) -> bool {
        out := cast(^[dynamic]string)user
        append(out, strings.clone(data, context.temp_allocator))

        return false
    }

    err := feed(&p, transmute([]byte)string("data: one\n\ndata: two\n\n"), &out, stop_after_one)
    testing.expect_value(t, err, Error.None)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], "one")
}
