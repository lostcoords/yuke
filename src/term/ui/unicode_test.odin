package ui

import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_str_width_ascii_wide_emoji_combining :: proc(t: ^testing.T) {
    testing.expect_value(t, str_width("Hello"), 5)
    testing.expect_value(t, str_width("漢"), 2) // wide CJK
    testing.expect_value(t, str_width("\U0001F60A"), 2) // emoji
    testing.expect_value(t, str_width("H" + "e" + "́"), 2) // H + e + combining acute = 2 cells
}

@(test)
test_str_utf16_len :: proc(t: ^testing.T) {
    testing.expect_value(t, str_utf16_len(""), 0)
    testing.expect_value(t, str_utf16_len("Hello"), 5) // ASCII: one unit each
    testing.expect_value(t, str_utf16_len("漢"), 1) // BMP: one unit though three UTF-8 bytes
    testing.expect_value(t, str_utf16_len("\U0001F60A"), 2) // astral: a surrogate pair
    testing.expect_value(t, str_utf16_len("a\U0001F60Ab"), 4) // 1 + 2 + 1
    testing.expect_value(t, str_utf16_len("H" + "e" + "́"), 3) // counts code units, not clusters
}

@(test)
test_str_width_zwj_family_and_flag_pair :: proc(t: ^testing.T) {
    // man ZWJ woman ZWJ girl ZWJ girl: one grapheme cluster via GB11.
    family := "\U0001F468" + "‍" + "\U0001F469" + "‍" + "\U0001F467" + "‍" + "\U0001F467"
    testing.expect_value(t, str_width(family), 2)
    testing.expect_value(t, str_width("\U0001F1EF" + "\U0001F1F5"), 2) // regional indicator pair (JP flag)
}

@(test)
test_str_width_skin_tone_and_variation_selectors :: proc(t: ^testing.T) {
    testing.expect_value(t, str_width("\U0001F44D" + "\U0001F3FD"), 2) // thumbs up + medium skin tone
    testing.expect_value(t, str_width("☂" + "️"), 2) // umbrella + VS16 (emoji presentation)
    testing.expect_value(t, str_width("\U0001F60A" + "︎"), 1) // smiling face + VS15 (text presentation)
}

@(test)
test_cluster_width_controls_and_dashes :: proc(t: ^testing.T) {
    // BS/DEL report negative width in zg; cluster_width clamps to 0.
    bs_it := clusters("\x08")
    bs_cluster, bs_ok := iter_next(&bs_it)
    testing.expect(t, bs_ok)
    testing.expect_value(t, cluster_width(bs_cluster, "\x08"), 0)

    del_it := clusters("\x7f")
    del_cluster, del_ok := iter_next(&del_it)
    testing.expect(t, del_ok)
    testing.expect_value(t, cluster_width(del_cluster, "\x7f"), 0)

    // Generic C0 control.
    esc_it := clusters("\x1b")
    esc_cluster, esc_ok := iter_next(&esc_it)
    testing.expect(t, esc_ok)
    testing.expect_value(t, cluster_width(esc_cluster, "\x1b"), 0)

    testing.expect_value(t, str_width("⸻"), 3) // three-em dash
}

@(test)
test_clusters_keeps_combining_marks_and_cjk_whole :: proc(t: ^testing.T) {
    str := "a" + "漢" + "e" + "́" // a | 漢 | e + combining acute
    it := clusters(str)

    c0, ok0 := iter_next(&it)
    testing.expect(t, ok0)
    testing.expect_value(t, cluster_bytes(c0, str), "a")

    c1, ok1 := iter_next(&it)
    testing.expect(t, ok1)
    testing.expect_value(t, cluster_bytes(c1, str), "漢")

    c2, ok2 := iter_next(&it)
    testing.expect(t, ok2)
    testing.expect_value(t, cluster_bytes(c2, str), "e" + "́")

    _, ok3 := iter_next(&it)
    testing.expect(t, !ok3)
}

@(test)
test_malformed_utf8_is_safe_to_segment :: proc(t: ^testing.T) {
    str := "\xffa"
    it := clusters(str)

    c0, ok0 := iter_next(&it)
    testing.expect(t, ok0)
    testing.expect_value(t, cluster_bytes(c0, str), "\xff")

    c1, ok1 := iter_next(&it)
    testing.expect(t, ok1)
    testing.expect_value(t, cluster_bytes(c1, str), "a")

    _, ok2 := iter_next(&it)
    testing.expect(t, !ok2)

    testing.expect(t, !is_valid_utf8(str))
}

@(test)
test_grapheme_length_is_not_limited_to_255_bytes :: proc(t: ^testing.T) {
    sb: strings.Builder
    strings.builder_init(&sb, context.temp_allocator)
    strings.write_string(&sb, "a")
    for _ in 0 ..< 160 {
        strings.write_string(&sb, "́")
    }
    str := strings.to_string(sb)

    it := clusters(str)
    c0, ok0 := iter_next(&it)
    testing.expect(t, ok0)
    testing.expect_value(t, c0.len, len(str))

    _, ok1 := iter_next(&it)
    testing.expect(t, !ok1)

    bounded_it := clusters(str)
    _, _, err := iter_next_bounded(&bounded_it, 255)
    testing.expect_value(t, err, Unicode_Error.Grapheme_Too_Long)
}

@(test)
test_iter_next_bounded_rejects_pathological_cluster_fast :: proc(t: ^testing.T) {
    // ~1 MiB of combining marks; the bounded path must error without scanning
    // the whole cluster.
    combining_count := 524_288
    buf := make([]u8, 1 + 2 * combining_count, context.temp_allocator)
    buf[0] = 'a'
    for i in 0 ..< combining_count {
        buf[1 + 2 * i] = 0xCC
        buf[1 + 2 * i + 1] = 0x81
    }
    str := string(buf)

    it := clusters(str)
    _, _, err := iter_next_bounded(&it, 4096)
    testing.expect_value(t, err, Unicode_Error.Grapheme_Too_Long)
}

@(test)
test_iter_next_bounded_leaves_cursor_at_crossing :: proc(t: ^testing.T) {
    // a | ́ | ́ | b; the full cluster would be 5 bytes, exceeding max_bytes=4.
    str := "a" + "́" + "́" + "b"
    it := clusters(str)

    _, _, err := iter_next_bounded(&it, 4)
    testing.expect_value(t, err, Unicode_Error.Grapheme_Too_Long)

    // The cursor stops at byte 3 (the second combining acute). A subsequent
    // call resumes from there, not from the cluster start.
    c1, ok1 := iter_next(&it)
    testing.expect(t, ok1)
    testing.expect_value(t, cluster_bytes(c1, str), "́")

    c2, ok2 := iter_next(&it)
    testing.expect(t, ok2)
    testing.expect_value(t, cluster_bytes(c2, str), "b")

    _, ok3 := iter_next(&it)
    testing.expect(t, !ok3)
}

@(test)
test_iter_next_bounded_exact_byte_boundary :: proc(t: ^testing.T) {
    cluster := "a" + "́" // 3 bytes

    it_ok := clusters(cluster)
    c, ok, err := iter_next_bounded(&it_ok, 3)
    testing.expect(t, ok)
    testing.expect_value(t, err, Unicode_Error.None)
    testing.expect_value(t, cluster_bytes(c, cluster), cluster)

    it_over := clusters(cluster)
    _, _, err_over := iter_next_bounded(&it_over, 2)
    testing.expect_value(t, err_over, Unicode_Error.Grapheme_Too_Long)
}

@(test)
test_codepoint_width_pinned_special_cases :: proc(t: ^testing.T) {
    testing.expect_value(t, str_width("\u00AD"), 1) // soft hyphen
    testing.expect_value(t, str_width("\u00B1"), 1) // ambiguous width

    c0_it := clusters("\u0003")
    c0_cluster, c0_ok := iter_next(&c0_it)
    testing.expect(t, c0_ok)
    testing.expect_value(t, cluster_width(c0_cluster, "\u0003"), 0)

    esc_it := clusters("\u001B")
    esc_cluster, esc_ok := iter_next(&esc_it)
    testing.expect(t, esc_ok)
    testing.expect_value(t, cluster_width(esc_cluster, "\u001B"), 0)
}

@(test)
test_iter_next_bounded_no_stale_state_across_many_clusters :: proc(t: ^testing.T) {
    // Regression pin: bounded accept must advance the iterator so later fast-path
    // calls do not read stale state.
    str := "0123456789abcdefghij"
    it := clusters(str)

    for i in 0 ..< len(str) {
        c, ok, err := iter_next_bounded(&it, 8)
        testing.expect(t, ok)
        testing.expect_value(t, err, Unicode_Error.None)
        testing.expect_value(t, c.offset, i)
        testing.expect_value(t, c.len, 1)
        testing.expect_value(t, cluster_bytes(c, str), str[i:i + 1])
    }

    _, ok, err := iter_next_bounded(&it, 8)
    testing.expect(t, !ok)
    testing.expect_value(t, err, Unicode_Error.None)
}

@(test)
test_iter_next_bounded_fresh_iterator_equivalent_to_unbounded :: proc(t: ^testing.T) {
    // UAX #29 break rules are local to a cluster boundary: starting core's
    // iterator at a true boundary must segment the rest of the string the same
    // way continuous iteration does.
    str :=
        "abc" +
        "\U0001F1EF\U0001F1F5" +
        "de" +
        "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F467" +
        "#\uFE0F\u200D\u20E3" +
        "\U0001F44D\U0001F3FD" +
        "漢xyz"

    bounded := collect_clusters(str, 64, context.temp_allocator)
    unbounded := collect_clusters(str, max(int), context.temp_allocator)

    testing.expect_value(t, len(bounded), len(unbounded))
    if len(bounded) == len(unbounded) {
        for i in 0 ..< len(bounded) {
            testing.expect_value(t, bounded[i], unbounded[i])
        }
    }
}

@(test)
test_iter_next_bounded_resumes_after_oversized_cluster :: proc(t: ^testing.T) {
    // Short clusters, then an oversized 4-byte cluster, then more short clusters.
    str := "xyz" + "\U0001F60A" + "123"

    it := clusters(str)

    next :: proc(it: ^Iterator, src: string, expected: string, t: ^testing.T) {
        c, ok, err := iter_next_bounded(it, 3)
        testing.expect(t, ok)
        testing.expect_value(t, err, Unicode_Error.None)
        testing.expect_value(t, cluster_bytes(c, src), expected)
    }

    next(&it, str, "x", t)
    next(&it, str, "y", t)
    next(&it, str, "z", t)

    _, _, err := iter_next_bounded(&it, 3)
    testing.expect_value(t, err, Unicode_Error.Grapheme_Too_Long)

    // Resume after the oversized cluster: the next cluster is the trailing ASCII.
    next(&it, str, "1", t)
    next(&it, str, "2", t)
    next(&it, str, "3", t)

    _, ok, final_err := iter_next_bounded(&it, 3)
    testing.expect(t, !ok)
    testing.expect_value(t, final_err, Unicode_Error.None)
}

@(test)
test_iter_next_bounded_post_error_diverges_from_continuous_iteration :: proc(t: ^testing.T) {
    // GB11 state is not carried across a rejection: resuming inside a ZWJ emoji
    // sequence yields standalone ZWJ clusters plus the final emoji, not the
    // original continuous-iteration clusters. This pins the deliberate behavior.
    family := "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F467"
    it := clusters(family)

    step :: proc(
        it: ^Iterator,
        src: string,
        expected_ok: bool,
        expected_err: Unicode_Error,
        expected: string,
        t: ^testing.T,
    ) {
        c, ok, err := iter_next_bounded(it, 4)
        testing.expect_value(t, ok, expected_ok)
        testing.expect_value(t, err, expected_err)
        if expected_ok do testing.expect_value(t, cluster_bytes(c, src), expected)
    }

    step(&it, family, false, .Grapheme_Too_Long, "", t)
    step(&it, family, true, .None, "\u200D", t) // ZWJ at offset 4
    step(&it, family, false, .Grapheme_Too_Long, "", t)
    step(&it, family, true, .None, "\u200D", t) // ZWJ at offset 11
    step(&it, family, false, .Grapheme_Too_Long, "", t)
    step(&it, family, true, .None, "\u200D", t) // ZWJ at offset 18
    step(&it, family, true, .None, "\U0001F467", t) // final emoji at offset 21
    step(&it, family, false, .None, "", t)
}

collect_clusters :: proc(str: string, max_bytes: int, allocator: mem.Allocator) -> []string {
    result := make([dynamic]string, 0, allocator)
    it := clusters(str)
    context.allocator = allocator
    for {
        c, ok, _ := iter_next_bounded(&it, max_bytes)
        if !ok do break
        append(&result, cluster_bytes(c, str))
    }
    return result[:]
}
