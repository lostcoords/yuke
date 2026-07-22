package term

import "core:testing"
import ts "src:testsupport"

// Push a string as bytes (test convenience over `reader_push`).
push :: proc(r: ^Reader, s: string) -> Reader_Error {
    return reader_push(r, transmute([]u8)s)
}

@(test)
test_reader_key_extraction_drains_one_event_per_byte :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    // Single byte: push yields one key, then nothing until more bytes arrive.
    testing.expect_value(t, push(&r, "a"), Reader_Error.None)
    ev, err := reader_next(&r)
    testing.expect_value(t, err, Reader_Error.None)
    k, ok := ev.(Key)
    testing.expect(t, ok)
    testing.expect_value(t, k.code, Key_Code.Char)
    testing.expect_value(t, k.char, 'a')

    none, _ := reader_next(&r)
    testing.expect(t, none == nil)

    // Multiple keys in one push: each next advances tail_start without shifting.
    testing.expect_value(t, push(&r, "bc"), Reader_Error.None)
    b, _ := reader_next(&r)
    testing.expect_value(t, b.(Key).char, 'b')
    testing.expect_value(t, r.tail_start, 1)
    c, _ := reader_next(&r)
    testing.expect_value(t, c.(Key).char, 'c')
    testing.expect_value(t, r.tail_start, 0)
    tail, _ := reader_next(&r)
    testing.expect(t, tail == nil)
}

@(test)
test_reader_escape_sequence_split_across_pushes :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b["), Reader_Error.None)
    part, _ := reader_next(&r)
    testing.expect(t, part == nil)

    testing.expect_value(t, push(&r, "A"), Reader_Error.None)
    ev, _ := reader_next(&r)
    testing.expect_value(t, ev.(Key).code, Key_Code.Up)
}

@(test)
test_reader_bracketed_paste_assembles_raw_content :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b[200~a\nb\x1b[201~"), Reader_Error.None)
    ev, err := reader_next(&r)
    testing.expect_value(t, err, Reader_Error.None)
    p, ok := ev.(Paste)
    testing.expect(t, ok)
    testing.expect_value(t, string(p), "a\nb")

    none, _ := reader_next(&r)
    testing.expect(t, none == nil)
}

@(test)
test_reader_paste_content_split_across_pushes :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b[200~hel"), Reader_Error.None)
    part, _ := reader_next(&r)
    testing.expect(t, part == nil)

    testing.expect_value(t, push(&r, "lo\x1b[201~"), Reader_Error.None)
    ev, _ := reader_next(&r)
    testing.expect_value(t, string(ev.(Paste)), "hello")
}

@(test)
test_reader_paste_terminator_split_across_pushes :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b[200~hello\x1b[20"), Reader_Error.None)
    part, _ := reader_next(&r)
    testing.expect(t, part == nil)

    testing.expect_value(t, push(&r, "1~"), Reader_Error.None)
    ev, _ := reader_next(&r)
    testing.expect_value(t, string(ev.(Paste)), "hello")
}

@(test)
test_reader_in_band_resize_report :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b[48;24;80;600;800t"), Reader_Error.None)
    ev, _ := reader_next(&r)
    _, ok := ev.(Resize)
    testing.expect(t, ok)

    none, _ := reader_next(&r)
    testing.expect(t, none == nil)
}

@(test)
test_reader_lone_esc_resolves_via_flush :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b"), Reader_Error.None)
    part, _ := reader_next(&r)
    testing.expect(t, part == nil)

    ev := reader_flush(&r)
    testing.expect_value(t, ev.(Key).code, Key_Code.Esc)
}

@(test)
test_reader_oversized_unresolved_sequence_is_dropped :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    // A CSI with no final byte never completes; once it passes the cap the reader
    // drops the tail instead of holding it forever.
    big := make([]u8, MAX_SEQ_BYTES + 16)
    defer delete(big)
    big[0] = 0x1b
    big[1] = '['
    for i in 2 ..< len(big) {
        big[i] = '1'
    }

    testing.expect_value(t, reader_push(&r, big), Reader_Error.None)
    ev, _ := reader_next(&r)
    testing.expect(t, ev == nil)
    testing.expect_value(t, len(r.tail), 0)
}

@(test)
test_reader_rejects_oversized_push_before_allocating :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    big := make([]u8, MAX_PUSH_BYTES + 1)
    defer delete(big)
    testing.expect_value(t, reader_push(&r, big), Reader_Error.Input_Too_Large)
    testing.expect_value(t, cap(r.tail), 0)
}

@(test)
test_reader_bounds_pending_bytes_when_caller_does_not_drain :: proc(t: ^testing.T) {
    r: Reader
    reader_init(&r, context.allocator)
    defer reader_destroy(&r)

    chunk := make([]u8, MAX_PUSH_BYTES)
    defer delete(chunk)
    for i in 0 ..< len(chunk) {
        chunk[i] = 'a'
    }
    testing.expect_value(t, reader_push(&r, chunk), Reader_Error.None)

    remainder := make([]u8, MAX_SEQ_BYTES)
    defer delete(remainder)
    for i in 0 ..< len(remainder) {
        remainder[i] = 'b'
    }
    testing.expect_value(t, reader_push(&r, remainder), Reader_Error.None)

    testing.expect_value(t, push(&r, "b"), Reader_Error.Input_Too_Large)
}

@(test)
test_reader_oom_during_paste_assembly_propagates :: proc(t: ^testing.T) {
    // alloc 0 is the tail append in push; alloc 1 is the paste-content append in
    // next, which the failing allocator rejects. next must surface the error and
    // leave the pending bytes unconsumed rather than spinning.
    fa := ts.Failing_Allocator{}
    ts.failing_allocator_init(&fa, context.allocator, 1)
    alloc := ts.failing_allocator(&fa)

    r: Reader
    reader_init(&r, alloc)
    defer reader_destroy(&r)

    testing.expect_value(t, push(&r, "\x1b[200~hello world"), Reader_Error.None)
    ev, err := reader_next(&r)
    testing.expect(t, ev == nil)
    testing.expect_value(t, err, Reader_Error.Out_Of_Memory)
}
