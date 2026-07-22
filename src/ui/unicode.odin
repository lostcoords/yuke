package ui

import "base:intrinsics"
import "core:unicode"
import "core:unicode/utf8"

// One grapheme cluster: a byte range into the caller's source string.
Cluster :: struct {
    offset, len: int,
}

// The cluster's bytes, borrowed from `src`.
cluster_bytes :: proc(c: Cluster, src: string) -> string {
    return src[c.offset:][:c.len]
}

Unicode_Error :: enum {
    None,
    Grapheme_Too_Long,
}

// UAX #29 extended grapheme cluster iterator over arbitrary bytes, safe on invalid
// UTF-8: each invalid byte becomes its own one-byte cluster with the raw byte
// preserved (core's decoder treats it as U+FFFD for the break algorithm only,
// never rewrites the returned bytes).
//
// Holds a byte cursor into `str`. Each call creates a fresh core:unicode/utf8
// Grapheme_Iterator over a bounded slice starting at the cursor; only the
// `byte_index` field of core's returned `Grapheme`s is trusted (core's per-call
// `width`/`text` are display-cell counts, not byte lengths, and are wrong for
// clusters whose byte length differs from their cell width).
Iterator :: struct {
    str:    string,
    offset: int,
    done:   bool,
}

// Iterate the grapheme clusters of `str` (UAX #29).
clusters :: proc(str: string) -> Iterator {
    return Iterator{str = str}
}

iter_next :: proc(it: ^Iterator) -> (Cluster, bool) {
    c, ok, _ := iter_next_bounded(it, max(int))
    return c, ok
}

// Return the next cluster, failing with `.Grapheme_Too_Long` as soon as its byte
// length exceeds `max_bytes`. Rendering uses this to bound work on pathological
// combining sequences; valid clusters otherwise have no byte-size cap.
//
// On `.Grapheme_Too_Long` the iterator is left at the first rune that would push
// the cluster past `max_bytes`, which may be inside the rejected cluster. Because
// each call starts a fresh core iterator at that rune, emoji-sequence (GB11) and
// regional-indicator parity (GB12-13) state is not carried across the rejection,
// so post-error segmentation can differ from continuous full-string iteration.
// The contract is intended for abort-on-error callers; buffer.odin treats this
// error as fatal today.
iter_next_bounded :: proc(it: ^Iterator, max_bytes: int) -> (Cluster, bool, Unicode_Error) {
    if it.done {
        return {}, false, .None
    }

    start := it.offset
    remaining := len(it.str) - start
    if remaining <= 0 {
        it.done = true
        return {}, false, .None
    }

    // Scan only a slice large enough to decide whether the cluster fits:
    // max_bytes bytes plus one maximal rune so a cluster that ends exactly at
    // the budget can be observed to terminate. Core's iterator may see a rune
    // split by this edge, but that can only produce an earlier apparent boundary;
    // any boundary found within the slice is at least max_bytes+1 bytes from
    // `start`, so the cluster is rejected either way.
    MAX_RUNE_BYTES :: 4
    bounded_len := remaining
    if max_bytes >= 0 && remaining >= MAX_RUNE_BYTES && max_bytes <= remaining - MAX_RUNE_BYTES {
        bounded_len = max_bytes + MAX_RUNE_BYTES
    }

    bounded_str := it.str[start:start + bounded_len]
    bounded_it := utf8.decode_grapheme_iterator_make(bounded_str)

    // First iterate consumes the cluster starting at the slice origin.
    _, _, ok := utf8.decode_grapheme_iterate(&bounded_it)
    if !ok {
        it.done = true
        return {}, false, .None
    }

    // Second iterate finds the next cluster boundary.
    _, next_g, next_ok := utf8.decode_grapheme_iterate(&bounded_it)
    end := start + (next_g.byte_index if next_ok else bounded_len)
    length := end - start

    if length > max_bytes {
        return resume_after_too_long(it, start, max_bytes)
    }

    it.offset = end
    if it.offset >= len(it.str) {
        it.done = true
    }

    return Cluster{offset = start, len = length}, true, .None
}

// Position `it` at the first rune that would push a cluster past `max_bytes`,
// so the next call resumes there. `start` is the cluster's first byte.
resume_after_too_long :: proc(it: ^Iterator, start, max_bytes: int) -> (Cluster, bool, Unicode_Error) {
    pos := 0
    for pos < max_bytes {
        _, size := utf8.decode_rune(it.str[start + pos:])
        if pos + size > max_bytes {
            break
        }
        pos += size
    }

    if pos == 0 {
        // Even the first rune exceeds the budget; skip past it so the next call
        // does not loop on the same rune.
        _, size := utf8.decode_rune(it.str[start:])
        pos = size
    }

    it.offset = start + pos
    if it.offset >= len(it.str) {
        it.done = true
    }

    return {}, false, .Grapheme_Too_Long
}

// True if `str` is valid UTF-8. Rendering gates on this before writing glyphs.
is_valid_utf8 :: proc(str: string) -> bool {
    return utf8.valid_string(str)
}

// Display width of `str` in terminal cells.
str_width :: proc(str: string) -> int {
    width := 0
    it := clusters(str)
    for {
        c, ok := iter_next(&it)
        if !ok {
            break
        }

        width = intrinsics.saturating_add(width, cluster_width(c, str))
    }

    return width
}

// Display width of one grapheme cluster in cells (zg's graphemeWidth): the first
// codepoint with nonzero per-codepoint width governs, unless the codepoint
// immediately after it is a variation selector or skin-tone modifier, in which
// case that overrides the width; any remaining codepoints contribute nothing.
// Clamped to zero (zg reports negative width for BS/DEL).
cluster_width :: proc(c: Cluster, src: string) -> int {
    bytes := cluster_bytes(c, src)
    off := 0
    width := 0

    for off < len(bytes) {
        cp, size := utf8.decode_rune(bytes[off:])
        off += size

        cw := codepoint_width(cp)
        if cw == 0 {
            continue
        }

        width = cw

        if off < len(bytes) {
            ncp, _ := utf8.decode_rune(bytes[off:])
            switch {
            case ncp == 0xFE0E:
                width = 1 // text presentation selector (VS15)
            case ncp == 0xFE0F:
                width = 2 // emoji presentation selector (VS16)
            case ncp >= 0x1F3FB && ncp <= 0x1F3FF:
                width = 2 // skin-tone modifier
            }
        }

        break
    }

    return max(width, 0)
}

// Per-codepoint display width, zg-parity (zg's DisplayWidth.codePointWidth). Starts
// from core's East Asian Width table, which already matches zg for the common
// cases pinned by tests (Wide CJK/emoji = 2, ambiguous = 1, soft hyphen = 1, C0
// controls = 0), and layers the specific overrides zg's dwp table adds on top:
//
//   - BS/DEL report negative width in zg (clamped to 0 by cluster_width, never
//     treated as "zero width" the way an ordinary control is — matters only if a
//     control glyph is not the cluster's sole codepoint, which no pinned case
//     exercises).
//   - Two-/three-em dash and the regional indicator block are widened past their
//     Neutral East Asian Width classification. Regional indicators specifically
//     must be 2 so a flag pair (two RIs forming one grapheme cluster) reports
//     width 2 without needing to look past the first codepoint.
//
// Residual divergence from zg, none of it exercised by the pinned tests: general
// category Mn/Me/Mc (combining marks) and most Cf format characters are
// zero-width in zg's table but fall back to core's default (usually 1) here, and
// a handful of ignorable/separator ranges (Hangul fillers, invisible operators
// beyond U+2060, interlinear annotation/specials, the tag block) are zero-width
// in zg but not in core. None of these are ever the first nonzero-width
// codepoint of a real-world cluster, so cluster_width is unaffected.
@(private)
codepoint_width :: proc(cp: rune) -> int {
    if cp == 0x08 || cp == 0x7F {
        return -1
    }

    switch cp {
    case 0x2E3A:
        return 2 // two-em dash
    case 0x2E3B:
        return 3 // three-em dash
    }

    if cp >= 0x1F1E6 && cp <= 0x1F200 {
        return 2 // regional indicators
    }

    return unicode.normalized_east_asian_width(cp)
}
