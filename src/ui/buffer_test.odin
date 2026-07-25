package ui

import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"
import ts "libs:testsupport"

// A recording io.Writer with failure knobs, standing in for the real buffered terminal
// writer in tests. It captures every byte written so ordering and content can be asserted,
// and can be told to fail a specific write call or every flush. Its own buffer uses
// context.allocator, independent of any allocator injected into the Buffer under test.
Test_Writer :: struct {
    buf:          [dynamic]u8,
    write_calls:  int,
    // 1-indexed write call to fail; 0 means never fail a write.
    fail_at_call: int,
    // When true, every flush fails.
    fail_flush:   bool,
}

test_writer_stream :: proc(tw: ^Test_Writer) -> io.Writer {
    return io.Writer{procedure = test_writer_proc, data = tw}
}

test_writer_proc :: proc(
    stream_data: rawptr,
    mode: io.Stream_Mode,
    p: []byte,
    offset: i64,
    whence: io.Seek_From,
) -> (
    n: i64,
    err: io.Error,
) {
    tw := cast(^Test_Writer)stream_data

    #partial switch mode {
    case .Write:
        tw.write_calls += 1
        if tw.fail_at_call != 0 && tw.write_calls == tw.fail_at_call {
            return 0, .EOF
        }

        append(&tw.buf, ..p)
        return i64(len(p)), .None
    case .Flush:
        if tw.fail_flush {
            return 0, .EOF
        }

        return 0, .None
    case .Query:
        return io.query_utility({.Write, .Flush, .Query})
    }

    return 0, .Unsupported
}

test_writer_written :: proc(tw: ^Test_Writer) -> string {
    return string(tw.buf[:])
}

test_writer_destroy :: proc(tw: ^Test_Writer) {
    delete(tw.buf)
}

@(test)
test_buffer_narrow_over_wide_blanks_continuation :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 4, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "漢", {}) // wide: head at 0, continuation at 1
    buffer_set(&buf, 0, 0, "a", {}) // narrow overwrite

    sb: [4]u8
    testing.expect_value(t, buffer_symbol_at(&buf, 0, 0, &sb), "a")
    testing.expect_value(t, buffer_symbol_at(&buf, 1, 0, &sb), " ") // continuation blanked
}

@(test)
test_buffer_partial_clear_repairs_both_halves :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 3, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "漢", {})
    buffer_clear(&buf, Rect{x = 1, y = 0, width = 1, height = 1})

    sb: [4]u8
    testing.expect_value(t, buffer_symbol_at(&buf, 0, 0, &sb), " ")
    testing.expect_value(t, buffer_symbol_at(&buf, 1, 0, &sb), " ")
    testing.expect(t, !cell_is_wide(buffer_cell_at(&buf, 0, 0)^))
    testing.expect(t, !cell_is_continuation(buffer_cell_at(&buf, 1, 0)^))
}

@(test)
test_buffer_wide_landing_last_column_repairs_old_head :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 2, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "漢", {})
    buffer_set(&buf, 1, 0, "語", {})

    sb: [4]u8
    testing.expect_value(t, buffer_symbol_at(&buf, 0, 0, &sb), " ")
    testing.expect_value(t, buffer_symbol_at(&buf, 1, 0, &sb), " ")
}

@(test)
test_buffer_wide_fill_blanks_unmatched_final_cell :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 3, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 2, 0, "x", {})
    buffer_fill(&buf, Rect{width = 3, height = 1}, "漢", Style{bg = Indexed(4)})

    sb: [4]u8
    testing.expect_value(t, buffer_symbol_at(&buf, 0, 0, &sb), "漢")
    testing.expect_value(t, buffer_symbol_at(&buf, 2, 0, &sb), " ")
    // The unmatched final cell is blanked to a space that still carries the fill's style.
    testing.expect(t, buffer_cell_at(&buf, 2, 0).bg.(Indexed) == Indexed(4))
}

@(test)
test_buffer_rejects_malformed_multicluster_oversized_and_width3 :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 4, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    testing.expect_value(t, buffer_set(&buf, 0, 0, "\xff", {}), Buffer_Error.Invalid_Utf8)

    _, e1 := buffer_set_string_n(&buf, 0, 0, "\xff", 4, {})
    testing.expect_value(t, e1, Buffer_Error.Invalid_Utf8)

    // Truncation returns a partial count with no error: the "\xff" past the width budget is
    // never examined.
    used, e2 := buffer_set_string_n(&buf, 0, 0, "a\xff", 1, {})
    testing.expect_value(t, used, u16(1))
    testing.expect_value(t, e2, Buffer_Error.None)

    testing.expect_value(t, buffer_set(&buf, 0, 0, "ab", {}), Buffer_Error.Expected_Single_Grapheme)
    testing.expect_value(t, buffer_set(&buf, 0, 0, "⸻", {}), Buffer_Error.Unsupported_Grapheme_Width) // three-em dash (width 3)
    testing.expect_value(t, buffer_set(&buf, 0, 0, "\n", {}), Buffer_Error.Unsupported_Grapheme_Width) // width 0

    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "a")
    for _ in 0 ..< 2048 {
        strings.write_string(&sb, "́") // combining acute
    }
    oversized := strings.to_string(sb)

    testing.expect(t, len(oversized) > MAX_GRAPHEME_BYTES)
    testing.expect_value(t, buffer_set(&buf, 0, 0, oversized, {}), Buffer_Error.Grapheme_Too_Long)
}

@(test)
test_buffer_rejects_oversized_grid_without_allocating :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    alloc := mem.tracking_allocator(&track)

    _, err := buffer_init(alloc, 65535, 65535)
    testing.expect_value(t, err, Buffer_Error.Grid_Too_Large)
    testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_buffer_out_of_bounds_cursor_is_hidden :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 2, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set_cursor(&buf, 2, 0, true)
    testing.expect(t, !buf.cursor.visible)
}

@(test)
test_buffer_text_preserves_existing_background_wash :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 4, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_fill(&buf, Rect{x = 0, y = 0, width = 4, height = 1}, " ", Style{bg = Indexed(237)})
    _, serr := buffer_set_string_n(&buf, 0, 0, "hi", 2, Style{fg = Ansi_Color.Cyan})
    testing.expect_value(t, serr, Buffer_Error.None)

    testing.expect(t, buffer_cell_at(&buf, 0, 0).bg.(Indexed) == Indexed(237)) // bg kept
    testing.expect(t, buffer_cell_at(&buf, 0, 0).fg.(Ansi_Color) == Ansi_Color.Cyan) // fg applied
}

@(test)
test_buffer_flush_hides_cursor_before_painting_shows_after :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 2, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "x", {})
    buffer_set_cursor(&buf, 1, 0, true)

    tw: Test_Writer
    defer test_writer_destroy(&tw)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&tw), false), Buffer_Error.None)

    out := test_writer_written(&tw)
    hide := strings.index(out, "\x1b[?25l")
    glyph := strings.index(out, "x")
    show := strings.index(out, "\x1b[?25h")
    testing.expect(t, hide >= 0 && glyph >= 0 && show >= 0)
    testing.expect(t, hide < glyph)
    testing.expect(t, glyph < show)
}

@(test)
test_buffer_diff_repaints_only_changed_cells :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 4, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set_string_n(&buf, 0, 0, "abcd", 4, {})
    first: Test_Writer
    defer test_writer_destroy(&first)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&first), false), Buffer_Error.None) // full paint

    // Redraw the same content except one cell.
    buffer_set_string_n(&buf, 0, 0, "abXd", 4, {})
    second: Test_Writer
    defer test_writer_destroy(&second)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&second), false), Buffer_Error.None)

    out := test_writer_written(&second)
    testing.expect(t, strings.index(out, "X") >= 0) // changed cell painted
    testing.expect(t, strings.index(out, "a") < 0) // unchanged cell skipped
}

@(test)
test_buffer_failed_writer_flush_does_not_commit :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 1, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "x", {})

    failing := Test_Writer {
        fail_flush = true,
    }
    defer test_writer_destroy(&failing)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&failing), false), Buffer_Error.Write_Failed)

    retry: Test_Writer
    defer test_writer_destroy(&retry)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&retry), false), Buffer_Error.None)
    testing.expect(t, strings.index(test_writer_written(&retry), "x") >= 0)
}

@(test)
test_buffer_abandoning_failed_frame_forces_repaint :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 1, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "a", {})
    first: Test_Writer
    defer test_writer_destroy(&first)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&first), false), Buffer_Error.None)

    buffer_set(&buf, 0, 0, "b", {})
    failing := Test_Writer {
        fail_flush = true,
    }
    defer test_writer_destroy(&failing)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&failing), false), Buffer_Error.Write_Failed)

    buffer_begin_frame(&buf)
    buffer_set(&buf, 0, 0, "a", {}) // Equal to the last committed frame.
    retry: Test_Writer
    defer test_writer_destroy(&retry)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&retry), false), Buffer_Error.None)
    testing.expect(t, strings.index(test_writer_written(&retry), "a") >= 0)
}

@(test)
test_buffer_failed_synchronized_frame_attempts_to_close_2026 :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 1, 1)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    buffer_set(&buf, 0, 0, "x", {})

    // Fail the second write call: the sync-open (call 1) lands, the cursor-hide (call 2)
    // fails, and the error path still emits the mode-2026 close (call 3).
    failing := Test_Writer {
        fail_at_call = 2,
    }
    defer test_writer_destroy(&failing)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&failing), true), Buffer_Error.Write_Failed)

    written := test_writer_written(&failing)
    testing.expect(t, strings.index(written, "\x1b[?2026h") >= 0)
    testing.expect(t, strings.index(written, "\x1b[?2026l") >= 0)
}

// Exercise a mixed inline/pooled/ZWJ write, synchronized flush, second-frame pooled write,
// and resize against `alloc`, mirroring the Zig exerciseBufferAllocations helper.
exercise_buffer :: proc(alloc: mem.Allocator) -> Buffer_Error {
    buf, err := buffer_init(alloc, 4, 1)
    if err != .None {
        return err
    }
    defer buffer_destroy(&buf)

    tw: Test_Writer
    defer test_writer_destroy(&tw)
    w := test_writer_stream(&tw)

    buffer_set(&buf, 0, 0, "é", {}) or_return // combining acute -> pooled
    flush_diff(&buf, w, true) or_return

    buffer_set(&buf, 0, 0, "\U0001F468‍\U0001F33E", {}) or_return // ZWJ farmer -> pooled
    flush_diff(&buf, w, true) or_return

    buffer_resize(&buf, 8, 2) or_return

    return .None
}

@(test)
test_buffer_allocation_failures_leave_it_valid :: proc(t: ^testing.T) {
    fail_at := 0

    for {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        backing := mem.tracking_allocator(&track)

        fa := ts.Failing_Allocator{}
        ts.failing_allocator_init(&fa, backing, fail_at)
        alloc := ts.failing_allocator(&fa)

        err := exercise_buffer(alloc)

        // Regardless of where (or whether) the injected failure landed, teardown must leave
        // nothing allocated and no bad frees.
        testing.expect_value(t, len(track.allocation_map), 0)
        testing.expect_value(t, len(track.bad_free_array), 0)

        completed := err == .None
        mem.tracking_allocator_destroy(&track)

        if completed {
            break
        }

        fail_at += 1
        testing.expect(t, fail_at < 10_000) // safety bound; a real bug must not hang the suite
        if fail_at >= 10_000 {
            break
        }
    }
}

@(test)
test_buffer_integration_geometry_draw_clip_diff_flush :: proc(t: ^testing.T) {
    buf, err := buffer_init(context.allocator, 20, 3)
    testing.expect_value(t, err, Buffer_Error.None)
    defer buffer_destroy(&buf)

    inner := Rect {
        x      = 1,
        y      = 1,
        width  = 18,
        height = 1,
    }
    wash := Style {
        bg = Indexed(236),
    }
    title_style := Style {
        fg = Ansi_Color.Cyan,
        bg = Indexed(236),
    }
    title := clip_cells("hello, terminal world", int(inner.width)) // clipped to 18 cells

    // Draw: a background wash, the clipped title over it, cursor after the title.
    buffer_fill(&buf, inner, " ", wash)
    buffer_put_str(&buf, inner.x, inner.y, title, title_style)
    buffer_set_cursor(&buf, inner.x + u16(cell_width(title)), inner.y, true)

    // In-memory state: title drawn, background wash preserved under it.
    sb: [4]u8
    testing.expect_value(t, buffer_symbol_at(&buf, inner.x, inner.y, &sb), "h")
    testing.expect(t, buffer_cell_at(&buf, inner.x, inner.y).bg.(Indexed) == Indexed(236))

    // Frame 1 flush (synchronized): title painted, wrapped in mode 2026, cursor shown.
    frame1: Test_Writer
    defer test_writer_destroy(&frame1)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&frame1), true), Buffer_Error.None)
    out1 := test_writer_written(&frame1)
    testing.expect(t, strings.index(out1, "\x1b[?2026h") >= 0)
    testing.expect(t, strings.index(out1, "\x1b[?2026l") >= 0)
    testing.expect(t, strings.index(out1, "w") >= 0) // a title cell painted
    testing.expect(t, strings.index(out1, "\x1b[?25h") >= 0) // cursor shown

    // Frame 2: redraw identical content -> the diff paints no title cells.
    buffer_fill(&buf, inner, " ", wash)
    buffer_put_str(&buf, inner.x, inner.y, title, title_style)
    buffer_set_cursor(&buf, inner.x + u16(cell_width(title)), inner.y, true)
    frame2: Test_Writer
    defer test_writer_destroy(&frame2)
    testing.expect_value(t, flush_diff(&buf, test_writer_stream(&frame2), true), Buffer_Error.None)
    testing.expect(t, strings.index(test_writer_written(&frame2), "w") < 0) // unchanged: no repaint
}
