package ui

import "base:intrinsics"
import "core:mem"

// The longest prefix of `text` that fits in `width` cells (grapheme-aware). A wide
// cluster that would overflow is dropped whole, never split. Borrowed.
clip_cells :: proc(text: string, width: int) -> string {
    used := 0
    end := 0

    it := clusters(text)
    for {
        c, ok := iter_next(&it)
        if !ok {
            break
        }

        w := cluster_width(c, text)
        if w > intrinsics.saturating_sub(width, used) {
            break
        }

        used = intrinsics.saturating_add(used, w)
        end = c.offset + c.len
    }

    return text[:end]
}

// The cell width of `text` (grapheme-aware).
cell_width :: proc(text: string) -> int {
    return str_width(text)
}

// The sub-slice of `text` covering cells [start, start+width) (grapheme-aware). A
// cluster straddling either boundary is excluded entirely. A zero-width cluster
// aligned exactly with `start` is included (deliberate divergence from the Zig
// reference's `next <= start`, which dropped it). Borrowed; out-of-range returns "".
slice_cells :: proc(text: string, start, width: int) -> string {
    end_cell := intrinsics.saturating_add(start, width)
    used := 0
    byte_start := 0
    byte_end := 0
    started := false

    it := clusters(text)
    for {
        c, ok := iter_next(&it)
        if !ok {
            break
        }

        w := cluster_width(c, text)
        next := intrinsics.saturating_add(used, w)
        if used < start {
            used = next
            continue
        }

        if used >= end_cell || next > end_cell {
            break
        }

        if !started {
            byte_start = c.offset
            started = true
        }

        byte_end = c.offset + c.len
        used = next
    }

    if !started {
        return ""
    }

    return text[byte_start:byte_end]
}

// Greedily soft-wrap `text` to `width` cells (grapheme-aware; width floored to a
// minimum of 1). A cluster that would overflow the current row starts a new row,
// unless the current row is still empty, in which case an overlong cluster gets
// its own row rather than being dropped or looping forever.
//
// OWNERSHIP: returned rows are borrowed sub-slices of `text`; only the outer
// []string is allocated, from `allocator`. The caller deletes it (`delete(rows,
// allocator)`) — row contents are not separately owned and must not outlive `text`.
wrap_text :: proc(text: string, width: int, allocator: mem.Allocator) -> ([]string, mem.Allocator_Error) {
    w := max(width, 1)

    rows, err := make([dynamic]string, 0, allocator)
    if err != nil {
        return nil, err
    }

    row_start := 0
    row_end := 0
    row_w := 0

    it := clusters(text)
    for {
        c, ok := iter_next(&it)
        if !ok {
            break
        }

        gw := cluster_width(c, text)
        if gw > intrinsics.saturating_sub(w, row_w) && row_end > row_start {
            if _, aerr := append(&rows, text[row_start:row_end]); aerr != nil {
                delete(rows)
                return nil, aerr
            }

            row_start = c.offset
            row_w = 0
        }

        row_w = intrinsics.saturating_add(row_w, gw)
        row_end = c.offset + c.len
    }

    if _, aerr := append(&rows, text[row_start:row_end]); aerr != nil {
        delete(rows)
        return nil, aerr
    }

    return rows[:], .None
}
