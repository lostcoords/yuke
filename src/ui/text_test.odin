package ui

import "core:mem"
import "core:testing"

@(test)
test_clip_cells_truncates_on_grapheme_and_width_boundary :: proc(t: ^testing.T) {
    testing.expect_value(t, clip_cells("hello", 3), "hel")
    testing.expect_value(t, clip_cells("a漢b", 2), "a") // 漢 is 2 cells, won't fit in 1 left
    testing.expect_value(t, clip_cells("a漢b", 3), "a漢") // a(1)+漢(2)=3
    testing.expect_value(t, clip_cells("hello", 100), "hello")
}

@(test)
test_clip_cells_saturates_on_max_int :: proc(t: ^testing.T) {
    testing.expect_value(t, clip_cells("hello", max(int)), "hello")
}

@(test)
test_cell_width :: proc(t: ^testing.T) {
    testing.expect_value(t, cell_width("Hello"), 5)
    testing.expect_value(t, cell_width("a漢b"), 4) // 1+2+1
}

@(test)
test_slice_cells_returns_a_cell_window :: proc(t: ^testing.T) {
    testing.expect_value(t, slice_cells("abcde", 1, 3), "bcd")
    testing.expect_value(t, slice_cells("abc", 9, 3), "") // past end
    // A wide cluster straddling the window edge is excluded.
    testing.expect_value(t, slice_cells("a漢b", 0, 2), "a") // 漢 would straddle cell 1..3
    testing.expect_value(t, slice_cells("abc", max(int), max(int)), "")
}

@(test)
test_slice_cells_excludes_wide_cluster_straddling_start :: proc(t: ^testing.T) {
    // 漢 occupies cells 1..3; a window starting at cell 2 must not include it.
    testing.expect_value(t, slice_cells("a漢b", 2, 1), "")
    testing.expect_value(t, slice_cells("a漢b", 2, 2), "b")
}

@(test)
test_slice_cells_includes_zero_width_cluster_at_start :: proc(t: ^testing.T) {
    // A zero-width cluster aligned with `start` is included. Zig's sliceCells used
    // `next <= start` and would have dropped the leading control.
    str := "\u0003漢"
    testing.expect_value(t, slice_cells(str, 0, 2), "\u0003漢")
    testing.expect_value(t, slice_cells(str, 0, 1), "\u0003")
    testing.expect_value(t, slice_cells(str, 1, 1), "")
}

@(test)
test_wrap_text_greedy_soft_wrap :: proc(t: ^testing.T) {
    rows, err := wrap_text("abcdef", 3, context.allocator)
    testing.expect_value(t, err, mem.Allocator_Error.None)
    defer delete(rows, context.allocator)

    testing.expect_value(t, len(rows), 2)
    testing.expect_value(t, rows[0], "abc")
    testing.expect_value(t, rows[1], "def")
}

@(test)
test_wrap_text_respects_wide_glyphs :: proc(t: ^testing.T) {
    rows, err := wrap_text("a漢b", 2, context.allocator)
    testing.expect_value(t, err, mem.Allocator_Error.None)
    defer delete(rows, context.allocator)

    // a(1) then 漢(2) overflows width 2 -> new row; then b.
    testing.expect_value(t, len(rows), 3)
    testing.expect_value(t, rows[0], "a")
    testing.expect_value(t, rows[1], "漢")
    testing.expect_value(t, rows[2], "b")
}

@(test)
test_wrap_text_width_floored_to_one :: proc(t: ^testing.T) {
    rows, err := wrap_text("ab", 0, context.allocator)
    testing.expect_value(t, err, mem.Allocator_Error.None)
    defer delete(rows, context.allocator)

    testing.expect_value(t, len(rows), 2)
    testing.expect_value(t, rows[0], "a")
    testing.expect_value(t, rows[1], "b")
}

@(test)
test_wrap_text_overlong_cluster_gets_its_own_row :: proc(t: ^testing.T) {
    // 漢 (2 cells) alone is wider than width 1, but must not be dropped or loop.
    rows, err := wrap_text("漢", 1, context.allocator)
    testing.expect_value(t, err, mem.Allocator_Error.None)
    defer delete(rows, context.allocator)

    testing.expect_value(t, len(rows), 1)
    testing.expect_value(t, rows[0], "漢")
}

@(test)
test_wrap_text_empty_input_yields_one_empty_row :: proc(t: ^testing.T) {
    rows, err := wrap_text("", 5, context.allocator)
    testing.expect_value(t, err, mem.Allocator_Error.None)
    defer delete(rows, context.allocator)

    testing.expect_value(t, len(rows), 1)
    testing.expect_value(t, rows[0], "")
}
