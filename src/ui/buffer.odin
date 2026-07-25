package ui

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"

// Cap on total cells (width * height). Bounds allocation at init/resize.
MAX_CELLS :: 1_000_000

// Terminal control byte-strings. Kept centralized here so the escape vocabulary lives in
// one place rather than scattered through the flush code. Formatted sequences (cursor
// positioning, SGR colors) are built inline where they are emitted.
//
// DEC private mode 2026: begin/end a synchronized update so a half-painted frame never shows.
SYNC_BEGIN :: "\x1b[?2026h"
SYNC_END :: "\x1b[?2026l"
// DEC private mode 25: hide/show the hardware cursor.
CURSOR_HIDE :: "\x1b[?25l"
CURSOR_SHOW :: "\x1b[?25h"
// SGR 0 (reset all attributes), and SGR 39/49 (default foreground/background).
SGR_RESET :: "\x1b[0m"
SGR_FG_DEFAULT :: "\x1b[39m"
SGR_BG_DEFAULT :: "\x1b[49m"

// Failure modes for the buffer's public API. `None` is success. Pool and writer failures
// are folded in: Grapheme_Too_Long covers oversized clusters, Out_Of_Memory covers pool
// exhaustion and allocation failure, Write_Failed covers any io.Writer error.
Buffer_Error :: enum {
    None,
    Grid_Too_Large,
    Grapheme_Too_Long,
    Invalid_Utf8,
    Expected_Single_Grapheme,
    Unsupported_Grapheme_Width,
    Out_Of_Memory,
    Write_Failed,
}

// Hardware cursor state for one frame.
Cursor_State :: struct {
    // Column, 0-based within the grid.
    x:       u16,

    // Row, 0-based within the grid.
    y:       u16,

    // Whether the cursor is shown this frame. Forced false when out of bounds.
    visible: bool,
}

// Double-buffered terminal grid: `cells` is the frame being drawn; `prev` is the last
// committed frame used for diffing. Both grids are flat row-major (idx = y*width + x).
// Free with buffer_destroy.
Buffer :: struct {
    // @private
    // Allocator backing both grids and both pools; supplied at init and reused on resize.
    allocator:    mem.Allocator,

    // Grid area in cells.
    area:         Rect,

    // @private
    // Current frame being drawn.
    cells:        []Cell,

    // @private
    // Last committed frame (read-only during a frame).
    prev:         []Cell,

    // @private
    // Grapheme pool for `cells`.
    pool:         Grapheme_Pool,

    // @private
    // Grapheme pool for `prev`, used by the diff to resolve the previous frame's clusters.
    prev_pool:    Grapheme_Pool,

    // Hardware cursor for the current frame.
    cursor:       Cursor_State,

    // @private
    // Hardware cursor from the last committed frame.
    prev_cursor:  Cursor_State,

    // @private
    // The next flush must repaint every cell. Starts true.
    force_redraw: bool,
}

// Allocate a width*height grid and force a full first paint. Rejects an oversized grid
// (> MAX_CELLS) BEFORE any allocation: the length is widened to int before multiplying,
// since u16*u16 overflows. Both grids are filled with EMPTY_CELL — never the Odin zero
// value, whose glyph is NUL rather than a space.
buffer_init :: proc(allocator: mem.Allocator, width, height: u16) -> (Buffer, Buffer_Error) {
    length := int(width) * int(height)
    if length > MAX_CELLS {
        return {}, .Grid_Too_Large
    }

    cells, cerr := make([]Cell, length, allocator)
    if cerr != nil {
        return {}, .Out_Of_Memory
    }

    prev, perr := make([]Cell, length, allocator)
    if perr != nil {
        delete(cells, allocator)
        return {}, .Out_Of_Memory
    }

    slice.fill(cells, EMPTY_CELL)
    slice.fill(prev, EMPTY_CELL)

    b := Buffer {
        allocator = allocator,
        area = {width = width, height = height},
        cells = cells,
        prev = prev,
        force_redraw = true,
    }
    pool_init(&b.pool, allocator)
    pool_init(&b.prev_pool, allocator)

    return b, .None
}

// Free both grids and both pools. Call once at teardown.
buffer_destroy :: proc(b: ^Buffer) {
    delete(b.cells, b.allocator)
    delete(b.prev, b.allocator)
    pool_destroy(&b.pool)
    pool_destroy(&b.prev_pool)
}

// Resize the grid and force a full repaint. No-op when unchanged. Allocates the fresh grids
// before freeing the old ones so a failed allocation leaves the buffer intact.
buffer_resize :: proc(b: ^Buffer, width, height: u16) -> Buffer_Error {
    if b.area.width == width && b.area.height == height {
        return .None
    }

    length := int(width) * int(height)
    if length > MAX_CELLS {
        return .Grid_Too_Large
    }

    cells, cerr := make([]Cell, length, b.allocator)
    if cerr != nil {
        return .Out_Of_Memory
    }

    prev, perr := make([]Cell, length, b.allocator)
    if perr != nil {
        delete(cells, b.allocator)
        return .Out_Of_Memory
    }

    slice.fill(cells, EMPTY_CELL)
    slice.fill(prev, EMPTY_CELL)

    delete(b.cells, b.allocator)
    delete(b.prev, b.allocator)
    pool_clear(&b.pool)
    pool_clear(&b.prev_pool)

    b.cells = cells
    b.prev = prev
    b.area = Rect {
        width  = width,
        height = height,
    }
    b.cursor = {}
    b.prev_cursor = {}
    b.force_redraw = true

    return .None
}

// Set the hardware cursor. `visible` is forced false when out of bounds.
buffer_set_cursor :: proc(b: ^Buffer, x, y: u16, visible: bool) {
    b.cursor = Cursor_State {
        x       = x,
        y       = y,
        visible = visible && x < b.area.width && y < b.area.height,
    }
}

// Start a fresh frame: clear cells, reset the pool and cursor. `prev`, `prev_cursor`, and
// `force_redraw` are untouched so a frame abandoned by a failed flush still forces a repaint.
buffer_begin_frame :: proc(b: ^Buffer) {
    slice.fill(b.cells, EMPTY_CELL)
    pool_clear(&b.pool)
    b.cursor = {}
}

// A pointer to the cell at (x,y), or nil when out of bounds. INVALIDATION: the returned
// pointer is borrowed from the current `cells` grid and is invalidated by buffer_resize,
// flush_diff (which swaps grids), and buffer_begin_frame. Do not retain it across those.
buffer_cell_at :: proc(b: ^Buffer, x, y: u16) -> ^Cell {
    idx, ok := buffer_index(b, x, y)
    if !ok {
        return nil
    }

    return &b.cells[idx]
}

// The cluster shown at (x,y); inline scalars are encoded into `buf`. "" for a continuation
// cell or out of bounds. A pooled result borrows the current pool (same invalidation as
// buffer_cell_at); an inline result borrows `buf`.
buffer_symbol_at :: proc(b: ^Buffer, x, y: u16, buf: ^[4]u8) -> string {
    idx, ok := buffer_index(b, x, y)
    if !ok {
        return ""
    }

    c := b.cells[idx]
    if cell_is_continuation(c) {
        return ""
    }

    if glyph_is_pooled(c.glyph) {
        return pool_str_of(&b.pool, c.glyph)
    }

    r, _ := glyph_scalar(c.glyph)
    bytes, n := utf8.encode_rune(r)
    buf^ = bytes

    return string(buf[:n])
}

// Write a grapheme cluster at (x,y), applying wide-glyph handling and repair. Out of bounds
// is a silent no-op. A width-2 glyph in the last column can't fit, so it is silently degraded
// to a plain space carrying the requested style (after repairs) rather than raising an error.
buffer_set :: proc(b: ^Buffer, x, y: u16, cluster: string, style: Style) -> Buffer_Error {
    idx, ok := buffer_index(b, x, y)
    if !ok {
        return .None
    }

    w := checked_grapheme_width(cluster) or_return

    if w == 2 && int(x) + 1 >= int(b.area.width) {
        repair_landing(b, idx)
        repair_overwritten(b, idx)
        set_one(b, idx, GLYPH_SPACE, style, {})
        return .None
    }

    glyph := glyph_for(b, cluster) or_return
    repair_landing(b, idx)
    repair_overwritten(b, idx)

    if w == 2 {
        // The continuation covers a cell that may have held its own wide head; repair it too.
        repair_overwritten(b, idx + 1)
        set_one(b, idx, glyph, style, {.Wide})
        set_one(b, idx + 1, GLYPH_SPACE, style, {.Cont})
    } else {
        set_one(b, idx, glyph, style, {})
    }

    return .None
}

// Write `text` from (x,y), clipped to the buffer width. Returns cells used.
buffer_put_str :: proc(b: ^Buffer, x, y: u16, text: string, style: Style) -> (u16, Buffer_Error) {
    remaining := intrinsics.saturating_sub(b.area.width, x)
    return buffer_set_string_n(b, x, y, text, remaining, style)
}

// Write at most `max_width` cells of `text` from (x,y). Returns cells used.
//
// Clusters are streamed through the bounded iterator; each is re-validated as UTF-8 (a
// mid-string invalid cluster errors, and cells already written STAY — there is no rollback).
// Zero-width clusters are silently skipped. The width-budget check happens BEFORE the next
// cluster is examined, so truncation returns a partial count with no error even if the
// unexamined remainder is malformed.
buffer_set_string_n :: proc(
    b: ^Buffer,
    x, y: u16,
    text: string,
    max_width: u16,
    style: Style,
) -> (
    used: u16,
    err: Buffer_Error,
) {
    if int(y) >= int(b.area.height) || int(x) >= int(b.area.width) || max_width == 0 {
        return 0, .None
    }

    col := x
    it := clusters(text)
    for {
        gc, ok, uerr := iter_next_bounded(&it, MAX_GRAPHEME_BYTES)
        if uerr != .None {
            return used, .Grapheme_Too_Long
        }
        if !ok {
            break
        }

        bytes := cluster_bytes(gc, text)
        if !is_valid_utf8(bytes) {
            return used, .Invalid_Utf8
        }

        cw := cluster_width(gc, text)
        if cw == 0 {
            continue
        }

        if cw > int(max_width) - int(used) || cw > int(b.area.width) - int(col) {
            break
        }

        if cw > 2 {
            return used, .Unsupported_Grapheme_Width
        }

        wv := u16(cw)
        buffer_set(b, col, y, bytes, style) or_return
        col += wv
        used += wv

        if used == max_width || col == b.area.width {
            break
        }
    }

    return used, .None
}

// Fill `area` with `cluster`. Each row steps by the cluster width; a final column that a wide
// cluster does not divide evenly is blanked to a space CARRYING THE FILL'S STYLE (not skipped,
// not reset to EMPTY_CELL).
buffer_fill :: proc(b: ^Buffer, area: Rect, cluster: string, style: Style) -> Buffer_Error {
    a := buffer_clamp(b, area)
    w := checked_grapheme_width(cluster) or_return

    row := a.y
    for row < rect_bottom(a) {
        col := a.x
        for col < rect_right(a) {
            if int(w) > int(rect_right(a)) - int(col) {
                break
            }

            buffer_set(b, col, row, cluster, style) or_return
            col += w
        }

        if col < rect_right(a) {
            idx := offset(b, col, row)
            repair_landing(b, idx)
            repair_overwritten(b, idx)
            set_one(b, idx, GLYPH_SPACE, style, {})
        }

        row += 1
    }

    return .None
}

// Clear `area`, or the whole grid when nil. Each cell is repaired and then fully reset to
// EMPTY_CELL — INCLUDING its style, unlike buffer_fill's styled blank.
buffer_clear :: proc(b: ^Buffer, area: Maybe(Rect)) {
    a := b.area
    if ar, ok := area.?; ok {
        a = buffer_clamp(b, ar)
    }

    y := a.y
    for y < rect_bottom(a) {
        x := a.x
        for x < rect_right(a) {
            if idx, ok := buffer_index(b, x, y); ok {
                repair_landing(b, idx)
                repair_overwritten(b, idx)
                b.cells[idx] = EMPTY_CELL
            }

            x += 1
        }

        y += 1
    }
}

// Write the cells changed since the last frame and advance the double buffer. When
// `synchronized`, wrap the frame in DEC mode 2026 so a half-painted frame never shows. The
// frame advances only after the writer itself flushes successfully.
//
// FAILURE DISCIPLINE (mirrors Zig's errdefer): any error forces a full repaint next time
// (force_redraw = true on exit). If a synchronized block was opened, the error path makes a
// best-effort attempt to close mode 2026 and flush, swallowing those secondary errors while
// the original error propagates. `committed` gates the cleanup: once the real flush succeeds
// and the frame advances, none of it runs.
flush_diff :: proc(b: ^Buffer, w: io.Writer, synchronized: bool) -> Buffer_Error {
    committed := false
    sync_open := false
    defer if !committed {
        b.force_redraw = true
        if sync_open {
            io.write_string(w, SYNC_END)
            io.flush(w)
        }
    }

    if synchronized {
        write_str(w, SYNC_BEGIN) or_return
        sync_open = true
    }

    // Hide the cursor proactively whenever painting could move it.
    if b.force_redraw || b.prev_cursor.visible || b.cursor.visible {
        write_str(w, CURSOR_HIDE) or_return
    }

    full := b.force_redraw
    y: u16 = 0
    for y < b.area.height {
        x: u16 = 0
        for x < b.area.width {
            idx := offset(b, x, y)
            c := b.cells[idx]

            // Continuation cells are skipped before any comparison: never diffed, never painted.
            if cell_is_continuation(c) {
                x += 1
                continue
            }

            if full || !cell_eq(b, idx) {
                write_goto(w, x, y) or_return
                queue_style(w, cell_style_of(c)) or_return
                write_glyph(b, w, idx) or_return
            }

            x += 2 if cell_is_wide(c) else 1
        }

        y += 1
    }

    // Unconditionally settle the terminal to a known default, even on zero repaints.
    write_str(w, SGR_RESET) or_return
    write_str(w, SGR_FG_DEFAULT) or_return
    write_str(w, SGR_BG_DEFAULT) or_return

    if b.cursor.visible {
        write_goto(w, b.cursor.x, b.cursor.y) or_return
        write_str(w, CURSOR_SHOW) or_return
    }

    if synchronized {
        write_str(w, SYNC_END) or_return
    }

    // The frame advances ONLY after the writer flushes successfully. A failed flush leaves
    // committed = false, so finish_frame never runs and the next flush re-sends everything.
    if io.flush(w) != .None {
        return .Write_Failed
    }

    finish_frame(b)
    committed = true

    return .None
}

// Advance the double buffer: shallow O(1) swap of the current/prev slice headers and pool
// struct values, then reset the (post-swap) current grid and pool for the next frame.
finish_frame :: proc(b: ^Buffer) {
    b.cells, b.prev = b.prev, b.cells
    b.pool, b.prev_pool = b.prev_pool, b.pool

    slice.fill(b.cells, EMPTY_CELL)
    pool_clear(&b.pool)
    b.prev_cursor = b.cursor
    b.cursor = {}
    b.force_redraw = false
}

// Validate the invariant encoded by Cell.flags: exactly one valid grapheme occupying one or
// two terminal cells. Width 0 (e.g. "\n") and width 3 (e.g. U+2E3B, the three-em dash) are
// both rejected because the Cell wide-bit can only express 1 versus 2 cells.
checked_grapheme_width :: proc(cluster: string) -> (u16, Buffer_Error) {
    if len(cluster) > MAX_GRAPHEME_BYTES {
        return 0, .Grapheme_Too_Long
    }

    if !is_valid_utf8(cluster) {
        return 0, .Invalid_Utf8
    }

    it := clusters(cluster)
    c, ok := iter_next(&it)
    if !ok || c.offset != 0 || c.len != len(cluster) {
        return 0, .Expected_Single_Grapheme
    }

    width := cluster_width(c, cluster)
    if width == 0 || width > 2 {
        return 0, .Unsupported_Grapheme_Width
    }

    return u16(width), .None
}

// Resolve a cluster to an inline glyph (exactly one codepoint) or a pooled glyph. The caller
// has already validated `cluster` as a single grapheme via checked_grapheme_width.
glyph_for :: proc(b: ^Buffer, cluster: string) -> (Glyph, Buffer_Error) {
    r, size := utf8.decode_rune(cluster)
    if size == len(cluster) {
        return glyph_from_scalar(r), .None
    }

    g, perr := pool_intern(&b.pool, cluster)
    return g, pool_error_to_buffer(perr)
}

@(private = "file")
pool_error_to_buffer :: proc(e: Pool_Error) -> Buffer_Error {
    switch e {
    case .None:
        return .None
    case .Grapheme_Too_Long:
        return .Grapheme_Too_Long
    case .Pool_Full, .Out_Of_Memory:
        return .Out_Of_Memory
    }

    return .None
}

// Write a glyph at `idx`, patching `style` over the current cell's existing style so a
// background wash survives a text write.
set_one :: proc(b: ^Buffer, idx: int, glyph: Glyph, style: Style, flags: Cell_Flags) {
    patched := style_patch(cell_style_of(b.cells[idx]), style)
    b.cells[idx] = Cell {
        glyph = glyph,
        fg    = patched.fg,
        bg    = patched.bg,
        mods  = patched.mods,
        flags = flags,
    }
}

// Blank a wide head when writing into its continuation. Guards width != 0 before any
// `idx % width` (a 0-width grid is representable), and that idx-1 stays on this row.
repair_landing :: proc(b: ^Buffer, idx: int) {
    if cell_is_continuation(b.cells[idx]) && idx > 0 && b.area.width != 0 && idx % int(b.area.width) != 0 {
        b.cells[idx - 1] = EMPTY_CELL
    }
}

// Blank a stale continuation when overwriting a wide head. Same 0-width and row-boundary
// guards as repair_landing.
repair_overwritten :: proc(b: ^Buffer, idx: int) {
    if cell_is_wide(b.cells[idx]) &&
       idx + 1 < len(b.cells) &&
       b.area.width != 0 &&
       (idx + 1) % int(b.area.width) != 0 {
        b.cells[idx + 1] = EMPTY_CELL
    }
}

// Whether the current and previous cells at `idx` are visually equal.
cell_eq :: proc(b: ^Buffer, idx: int) -> bool {
    a := b.cells[idx]
    p := b.prev[idx]
    return a.fg == p.fg && a.bg == p.bg && a.mods == p.mods && a.flags == p.flags && glyph_eq(b, a.glyph, p.glyph)
}

// Glyph equality for the diff. Pooled glyphs are compared by RESOLVED string, each side
// against its OWN generation's pool: `a` from `pool`, `b` from `prev_pool`. The two pools are
// never crossed and never collapsed into one — a's index only means something in this
// generation, b's only in the previous one. Inline glyphs compare raw; a mixed pair is unequal.
glyph_eq :: proc(b: ^Buffer, a, other: Glyph) -> bool {
    a_pooled := glyph_is_pooled(a)
    b_pooled := glyph_is_pooled(other)

    if a_pooled && b_pooled {
        return pool_str_of(&b.pool, a) == pool_str_of(&b.prev_pool, other)
    }

    if !a_pooled && !b_pooled {
        return u32(a) == u32(other)
    }

    return false
}

// Emit the glyph bytes for the cell at `idx`: a pooled cluster resolves against the CURRENT
// pool; an inline scalar is UTF-8 encoded into a stack buffer (space as a last-resort fallback).
write_glyph :: proc(b: ^Buffer, w: io.Writer, idx: int) -> Buffer_Error {
    glyph := b.cells[idx].glyph
    if glyph_is_pooled(glyph) {
        return write_str(w, pool_str_of(&b.pool, glyph))
    }

    r, ok := glyph_scalar(glyph)
    if !ok {
        return write_str(w, " ")
    }

    bytes, n := utf8.encode_rune(r)
    return write_str(w, string(bytes[:n]))
}

// Emit a full style reset then this cell's colors and modifiers. There is deliberately NO
// cross-cell SGR state tracking: every repainted cell re-sends its whole style, so the output
// is byte-exact and independent of neighbors. The leading SGR 0 clears prior attributes, so
// modifiers are only ever added (no off-codes).
queue_style :: proc(w: io.Writer, style: Style) -> Buffer_Error {
    write_str(w, SGR_RESET) or_return
    emit_fg(w, style.fg) or_return
    emit_bg(w, style.bg) or_return

    if .Bold in style.mods {
        write_str(w, "\x1b[1m") or_return
    }
    if .Dim in style.mods {
        write_str(w, "\x1b[2m") or_return
    }
    if .Italic in style.mods {
        write_str(w, "\x1b[3m") or_return
    }
    if .Underlined in style.mods {
        write_str(w, "\x1b[4m") or_return
    }
    if .Reversed in style.mods {
        write_str(w, "\x1b[7m") or_return
    }
    if .Crossed_Out in style.mods {
        write_str(w, "\x1b[9m") or_return
    }

    return .None
}

// Resolve `color` to a foreground SGR escape and emit it. nil and Reset both select the
// terminal default (SGR 39).
emit_fg :: proc(w: io.Writer, color: Color) -> Buffer_Error {
    if color == nil {
        return write_str(w, SGR_FG_DEFAULT)
    }

    switch v in color {
    case Ansi_Color:
        if v == .Reset {
            return write_str(w, SGR_FG_DEFAULT)
        }

        return write_fmt(w, "\x1b[38;5;%dm", palette_index(v))
    case Indexed:
        return write_fmt(w, "\x1b[38;5;%dm", u8(v))
    case Rgb:
        return write_fmt(w, "\x1b[38;2;%d;%d;%dm", v.r, v.g, v.b)
    }

    return .None
}

// Resolve `color` to a background SGR escape and emit it. nil and Reset both select the
// terminal default (SGR 49).
emit_bg :: proc(w: io.Writer, color: Color) -> Buffer_Error {
    if color == nil {
        return write_str(w, SGR_BG_DEFAULT)
    }

    switch v in color {
    case Ansi_Color:
        if v == .Reset {
            return write_str(w, SGR_BG_DEFAULT)
        }

        return write_fmt(w, "\x1b[48;5;%dm", palette_index(v))
    case Indexed:
        return write_fmt(w, "\x1b[48;5;%dm", u8(v))
    case Rgb:
        return write_fmt(w, "\x1b[48;2;%d;%d;%dm", v.r, v.g, v.b)
    }

    return .None
}

// The 256-palette index for a named color: Black=0 .. White=15, following the Ansi_Color
// declaration order after Reset (which occupies enum value 0, hence the -1).
palette_index :: proc(c: Ansi_Color) -> u8 {
    return u8(int(c) - 1)
}

// Cursor positioning: `\x1b[{row};{col}H`, 1-indexed, ROW then COL — the y coordinate is
// emitted first. (mibu's reference goTo names its params x,y but prints y;x; matching that
// ordering here is load-bearing.)
write_goto :: proc(w: io.Writer, x, y: u16) -> Buffer_Error {
    return write_fmt(w, "\x1b[%d;%dH", int(y) + 1, int(x) + 1)
}

// Format an escape into a stack buffer and write it in a single write call. The buffer is
// sized for the longest sequence produced here (an RGB SGR or a two-coordinate goto).
write_fmt :: proc(w: io.Writer, format: string, args: ..any) -> Buffer_Error {
    buf: [32]u8
    return write_str(w, fmt.bprintf(buf[:], format, ..args))
}

// Write a string, mapping any io.Writer error to .Write_Failed.
write_str :: proc(w: io.Writer, s: string) -> Buffer_Error {
    _, err := io.write_string(w, s)
    if err != .None {
        return .Write_Failed
    }

    return .None
}

// The clamped intersection of `area` with the grid. Clamps x/y into bounds first, then width/
// height to the remaining space, so the result is always self-consistent.
buffer_clamp :: proc(b: ^Buffer, area: Rect) -> Rect {
    x := min(area.x, b.area.width)
    y := min(area.y, b.area.height)
    return {x = x, y = y, width = min(area.width, b.area.width - x), height = min(area.height, b.area.height - y)}
}

// Cell index for (x,y), or ok=false when out of bounds.
buffer_index :: proc(b: ^Buffer, x, y: u16) -> (int, bool) {
    if x < b.area.width && y < b.area.height {
        return offset(b, x, y), true
    }

    return 0, false
}

// Flat row-major index of (x,y). Widened to int to avoid u16 overflow.
offset :: proc(b: ^Buffer, x, y: u16) -> int {
    return int(y) * int(b.area.width) + int(x)
}
