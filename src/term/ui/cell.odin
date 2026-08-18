package ui

import "core:mem"
import "core:strings"

// One cluster may be visually one cell while containing arbitrarily many combining code
// points. Bounds the bytes copied into a frame generation.
MAX_GRAPHEME_BYTES :: 4096

// Max interned clusters per generation.
MAX_GRAPHEMES_PER_GENERATION :: 1_000_000

// Max total interned bytes per generation.
MAX_GRAPHEME_BYTES_PER_GENERATION :: 16 * 1024 * 1024

// A cell glyph: an inline scalar (val < POOL_BASE) or a pool index (val >= POOL_BASE).
Glyph :: distinct u32

// One past the largest Unicode scalar; pool indices start here.
POOL_BASE :: 0x11_0000

// A space glyph — the default cell content.
GLYPH_SPACE :: Glyph(' ')

// A glyph holding one Unicode scalar. Whether a cluster is eligible to be inline (exactly
// one scalar, by codepoint count, not byte length) is decided by the buffer stage; this
// only packs the value.
glyph_from_scalar :: proc(r: rune) -> Glyph {
    return Glyph(u32(r))
}

// A glyph referencing pool entry `index`.
glyph_pooled :: proc(index: u32) -> Glyph {
    return Glyph(POOL_BASE + index)
}

// True if `g` is a pool index (not an inline scalar).
glyph_is_pooled :: proc(g: Glyph) -> bool {
    return u32(g) >= POOL_BASE
}

// The pool index for a pooled glyph. Caller must check glyph_is_pooled first.
glyph_pool_index :: proc(g: Glyph) -> int {
    return int(u32(g) - POOL_BASE)
}

// The inline scalar, or false if `g` is pooled.
glyph_scalar :: proc(g: Glyph) -> (rune, bool) {
    if glyph_is_pooled(g) do return 0, false

    return rune(u32(g)), true
}

// Interns multi-scalar grapheme clusters for one buffer generation, deduped by content.
//
// OWNERSHIP: the pool owns every interned string (duped into `allocator`). `by_str`'s keys
// alias the same owned copies stored in `strings` — never the caller's `cluster` slice —
// because Odin's map[string] hashes a key by content but stores the key slice as-is; keying
// on a caller-owned slice would leave a dangling key the moment the caller frees or reuses
// it. `pool_clear` drops everything to start a fresh generation; `pool_destroy` frees for
// good.
Grapheme_Pool :: struct {
    allocator: mem.Allocator,
    strings:   [dynamic]string,
    by_str:    map[string]u32,
    bytes_len: int,
}

// Failure modes for pool_intern. `None` is success.
Pool_Error :: enum {
    None,
    Grapheme_Too_Long,
    Pool_Full,
}

pool_init :: proc(pool: ^Grapheme_Pool, allocator: mem.Allocator) {
    pool^ = {}
    pool.allocator = allocator
    pool.strings = make([dynamic]string, 0, allocator)
    pool.by_str = make(map[string]u32, allocator)
}

// Free all storage. Call once at teardown.
pool_destroy :: proc(pool: ^Grapheme_Pool) {
    for s in pool.strings {
        delete(s, pool.allocator)
    }
    delete(pool.strings)
    delete(pool.by_str)
}

// Intern `cluster`, returning its pooled glyph (deduped by content).
pool_intern :: proc(pool: ^Grapheme_Pool, cluster: string) -> (Glyph, Pool_Error) {
    if len(cluster) > MAX_GRAPHEME_BYTES do return {}, .Grapheme_Too_Long

    if index, ok := pool.by_str[cluster]; ok do return glyph_pooled(index), .None

    if len(pool.strings) >= MAX_GRAPHEMES_PER_GENERATION do return {}, .Pool_Full

    if len(cluster) > MAX_GRAPHEME_BYTES_PER_GENERATION - pool.bytes_len do return {}, .Pool_Full

    owned := strings.clone(cluster, pool.allocator)

    index := u32(len(pool.strings))
    append(&pool.strings, owned)
    map_insert(&pool.by_str, owned, index)
    pool.bytes_len += len(owned)

    return glyph_pooled(index), .None
}

// The cluster string for a pooled glyph. `glyph` must be a pooled glyph returned by this
// same pool's current generation; resolving one against the wrong pool, or against a
// generation `pool_clear` already dropped, is a caller bug.
pool_str_of :: proc(pool: ^Grapheme_Pool, glyph: Glyph) -> string {
    return pool.strings[glyph_pool_index(glyph)]
}

// Drop all interned clusters and start a fresh generation; indices restart at 0.
pool_clear :: proc(pool: ^Grapheme_Pool) {
    for s in pool.strings {
        delete(s, pool.allocator)
    }
    delete(pool.strings)
    delete(pool.by_str)

    pool.strings = make([dynamic]string, 0, pool.allocator)
    pool.by_str = make(map[string]u32, pool.allocator)
    pool.bytes_len = 0
}

// Wide-head and continuation flags for a Cell. A width-2 glyph occupies two cells: the head
// cell carries the real glyph plus .Wide, and the cell to its right carries GLYPH_SPACE
// plus .Cont — never a copy of the glyph's bytes.
Cell_Flag :: enum u8 {
    Wide,
    Cont,
}

Cell_Flags :: bit_set[Cell_Flag;u8]

// A terminal grid cell. The Odin zero value is NOT a valid empty cell — glyph 0 is NUL, not
// a space — so every clear/reset path must use EMPTY_CELL, never {}.
Cell :: struct {
    glyph:  Glyph,
    // Foreground / background; nil = inherit/unset (see Style).
    fg, bg: Color,
    mods:   Modifiers,
    flags:  Cell_Flags,
}

// The default cell: a space glyph, inherited style, no flags.
EMPTY_CELL :: Cell {
    glyph = GLYPH_SPACE,
}

// This cell's current style.
cell_style_of :: proc(cell: Cell) -> Style {
    return {fg = cell.fg, bg = cell.bg, mods = cell.mods}
}

// Patch the cell's style with the set fields of `s`, written back onto the cell. Write-only-
// adds: modifiers are unioned in and never cleared (see style_patch).
cell_set_style :: proc(cell: ^Cell, s: Style) {
    patched := style_patch(cell_style_of(cell^), s)
    cell.fg = patched.fg
    cell.bg = patched.bg
    cell.mods = patched.mods
}

cell_is_wide :: proc(cell: Cell) -> bool {
    return .Wide in cell.flags
}

cell_is_continuation :: proc(cell: Cell) -> bool {
    return .Cont in cell.flags
}
