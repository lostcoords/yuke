package ui

import "core:mem"
import "core:testing"
import ts "libs:testsupport"

@(test)
test_glyph_inline_scalar_vs_pooled :: proc(t: ^testing.T) {
    a := glyph_from_scalar('a')
    testing.expect(t, !glyph_is_pooled(a))
    r, ok := glyph_scalar(a)
    testing.expect(t, ok)
    testing.expect_value(t, r, 'a')

    // A 3-byte CJK scalar is still a single codepoint, so it packs inline too — only
    // multi-codepoint clusters need the pool.
    han := glyph_from_scalar('漢')
    testing.expect(t, !glyph_is_pooled(han))
    han_r, han_ok := glyph_scalar(han)
    testing.expect(t, han_ok)
    testing.expect_value(t, han_r, '漢')

    p := glyph_pooled(3)
    testing.expect(t, glyph_is_pooled(p))
    testing.expect_value(t, glyph_pool_index(p), 3)
    _, pooled_ok := glyph_scalar(p)
    testing.expect(t, !pooled_ok)
}

@(test)
test_glyph_pool_base_boundary :: proc(t: ^testing.T) {
    // The largest valid scalar packs inline; POOL_BASE itself is the first pool index.
    max_scalar := glyph_from_scalar(rune(0x10FFFF))
    testing.expect(t, !glyph_is_pooled(max_scalar))

    first_pooled := glyph_pooled(0)
    testing.expect(t, glyph_is_pooled(first_pooled))
    testing.expect_value(t, u32(first_pooled), u32(POOL_BASE))
}

@(test)
test_grapheme_pool_intern_dedups_str_of_resolves_clear_resets :: proc(t: ^testing.T) {
    pool: Grapheme_Pool
    pool_init(&pool, context.allocator)
    defer pool_destroy(&pool)

    g1, err1 := pool_intern(&pool, "é")
    g2, err2 := pool_intern(&pool, "é") // same content -> same index
    g3, err3 := pool_intern(&pool, "漢")
    testing.expect_value(t, err1, Pool_Error.None)
    testing.expect_value(t, err2, Pool_Error.None)
    testing.expect_value(t, err3, Pool_Error.None)
    testing.expect_value(t, g1, g2)
    testing.expect(t, g1 != g3)
    testing.expect_value(t, pool_str_of(&pool, g1), "é")
    testing.expect_value(t, pool_str_of(&pool, g3), "漢")

    // Distinct clusters get distinct ascending indices.
    testing.expect_value(t, glyph_pool_index(g1), 0)
    testing.expect_value(t, glyph_pool_index(g3), 1)

    pool_clear(&pool)
    testing.expect_value(t, len(pool.strings), 0)
    testing.expect_value(t, cap(pool.strings), 0)
    testing.expect_value(t, len(pool.by_str), 0)
    testing.expect_value(t, pool.bytes_len, 0)

    g4, err4 := pool_intern(&pool, "x") // indices restart after clear
    testing.expect_value(t, err4, Pool_Error.None)
    testing.expect_value(t, glyph_pool_index(g4), 0)
}

@(test)
test_grapheme_pool_rejects_oversized_cluster :: proc(t: ^testing.T) {
    pool: Grapheme_Pool
    pool_init(&pool, context.allocator)
    defer pool_destroy(&pool)

    cluster := make([]u8, MAX_GRAPHEME_BYTES + 1)
    defer delete(cluster)
    for i in 0 ..< len(cluster) {
        cluster[i] = 'a'
    }

    _, err := pool_intern(&pool, string(cluster))
    testing.expect_value(t, err, Pool_Error.Grapheme_Too_Long)
}

@(test)
test_grapheme_pool_generation_count_cap_boundary :: proc(t: ^testing.T) {
    pool: Grapheme_Pool
    pool_init(&pool, context.allocator)
    defer pool_destroy(&pool)

    // One slot left: interning succeeds and fills the generation.
    resize(&pool.strings, MAX_GRAPHEMES_PER_GENERATION - 1)
    g1, err1 := pool_intern(&pool, "x")
    testing.expect_value(t, err1, Pool_Error.None)
    testing.expect_value(t, glyph_pool_index(g1), MAX_GRAPHEMES_PER_GENERATION - 1)

    // At the cap: one more cluster is rejected.
    resize(&pool.strings, MAX_GRAPHEMES_PER_GENERATION)
    _, err2 := pool_intern(&pool, "y")
    testing.expect_value(t, err2, Pool_Error.Pool_Full)
}

@(test)
test_grapheme_pool_generation_bytes_cap_boundary :: proc(t: ^testing.T) {
    pool: Grapheme_Pool
    pool_init(&pool, context.allocator)
    defer pool_destroy(&pool)

    // Exactly one byte of budget left.
    pool.bytes_len = MAX_GRAPHEME_BYTES_PER_GENERATION - 1
    _, err1 := pool_intern(&pool, "x")
    testing.expect_value(t, err1, Pool_Error.None)
    testing.expect_value(t, pool.bytes_len, MAX_GRAPHEME_BYTES_PER_GENERATION)

    // At the cap: one more byte is rejected.
    pool.bytes_len = MAX_GRAPHEME_BYTES_PER_GENERATION
    _, err2 := pool_intern(&pool, "y")
    testing.expect_value(t, err2, Pool_Error.Pool_Full)

    // Underflow-risk side: bytes_len past the cap must not wrap or crash.
    pool.bytes_len = MAX_GRAPHEME_BYTES_PER_GENERATION + 1
    _, err3 := pool_intern(&pool, "z")
    testing.expect_value(t, err3, Pool_Error.Pool_Full)
}

@(test)
test_cell_style_round_trip_and_flags :: proc(t: ^testing.T) {
    c := EMPTY_CELL
    testing.expect(t, !cell_is_wide(c))
    testing.expect(t, !cell_is_continuation(c))
    testing.expect_value(t, c.glyph, GLYPH_SPACE)

    c.flags = {.Wide}
    testing.expect(t, cell_is_wide(c))
    testing.expect(t, !cell_is_continuation(c))

    cell_set_style(&c, {fg = Ansi_Color.Red, mods = {.Bold}})
    s := cell_style_of(c)
    testing.expect(t, s.fg != nil)
    testing.expect_value(t, s.fg.(Ansi_Color), Ansi_Color.Red)
    testing.expect(t, .Bold in s.mods)

    // setStyle patches onto the CURRENT style and never clears prior modifiers.
    cell_set_style(&c, {mods = {.Italic}})
    s2 := cell_style_of(c)
    testing.expect(t, s2.fg != nil)
    testing.expect_value(t, s2.fg.(Ansi_Color), Ansi_Color.Red)
    testing.expect(t, .Bold in s2.mods)
    testing.expect(t, .Italic in s2.mods)
}

@(test)
test_cell_zero_value_glyph_is_not_a_space :: proc(t: ^testing.T) {
    // The Odin zero value is a divergence from Zig's default; only EMPTY_CELL is a real
    // empty cell.
    zero := Cell{}
    testing.expect(t, zero.glyph != GLYPH_SPACE)
    testing.expect_value(t, u32(zero.glyph), u32(0))
}

// Exercise a small intern scenario against `pool`, mirroring the Zig
// exerciseGraphemePoolAllocations helper.
exercise_grapheme_pool :: proc(pool: ^Grapheme_Pool) -> Pool_Error {
    _, err1 := pool_intern(pool, "é")
    if err1 != .None do return err1

    _, err2 := pool_intern(pool, "👨‍🌾")
    if err2 != .None do return err2

    return .None
}

@(test)
test_grapheme_pool_allocation_failures_leave_it_valid :: proc(t: ^testing.T) {
    fail_at := 0

    for {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        backing := mem.tracking_allocator(&track)

        fa := ts.Failing_Allocator{}
        ts.failing_allocator_init(&fa, backing, fail_at)
        alloc := ts.failing_allocator(&fa)

        pool: Grapheme_Pool
        pool_init(&pool, alloc)
        err := exercise_grapheme_pool(&pool)
        pool_destroy(&pool)

        // Regardless of where (or whether) the injected failure landed, teardown must
        // leave nothing allocated and no bad frees.
        testing.expect_value(t, len(track.allocation_map), 0)
        testing.expect_value(t, len(track.bad_free_array), 0)

        completed := err == .None
        mem.tracking_allocator_destroy(&track)

        if completed do break

        fail_at += 1
        testing.expect(t, fail_at < 10_000) // safety bound; a real bug must not hang the suite
        if fail_at >= 10_000 do break
    }
}
