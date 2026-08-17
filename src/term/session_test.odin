package term

import "core:strings"
import "core:testing"

@(test)
test_parse_mode_report_status_codes :: proc(t: ^testing.T) {
    // Each of the five DECRPM status codes maps to its Mode_Status.
    testing.expect_value(t, parse_mode_report(transmute([]u8)string("\x1b[?2048;1$y"), 2048), Mode_Status.Set)
    testing.expect_value(t, parse_mode_report(transmute([]u8)string("\x1b[?2026;2$y"), 2026), Mode_Status.Reset)
    testing.expect_value(
        t,
        parse_mode_report(transmute([]u8)string("\x1b[?2004;3$y"), 2004),
        Mode_Status.Permanently_Set,
    )
    testing.expect_value(
        t,
        parse_mode_report(transmute([]u8)string("\x1b[?2048;4$y"), 2048),
        Mode_Status.Permanently_Reset,
    )
    testing.expect_value(
        t,
        parse_mode_report(transmute([]u8)string("\x1b[?2048;0$y"), 2048),
        Mode_Status.Not_Recognized,
    )
}

@(test)
test_mode_status_supported :: proc(t: ^testing.T) {
    // Status 0 (not recognized) and 4 (permanently reset) are unusable; 1/2/3 are usable.
    testing.expect(t, !mode_status_supported(.Not_Recognized))
    testing.expect(t, mode_status_supported(.Set))
    testing.expect(t, mode_status_supported(.Reset))
    testing.expect(t, mode_status_supported(.Permanently_Set))
    testing.expect(t, !mode_status_supported(.Permanently_Reset))
}

@(test)
test_parse_mode_report_mismatch_and_offset :: proc(t: ^testing.T) {
    // A reply for a different mode is not a match.
    testing.expect_value(
        t,
        parse_mode_report(transmute([]u8)string("\x1b[?2026;1$y"), 2048),
        Mode_Status.Not_Recognized,
    )

    // Only a DA1 reply (terminal ignored DECRQM) is not a mode report.
    testing.expect_value(t, parse_mode_report(transmute([]u8)string("\x1b[?64;1c"), 2048), Mode_Status.Not_Recognized)

    // The report is found at a non-zero offset, after unrelated leading bytes.
    testing.expect_value(t, parse_mode_report(transmute([]u8)string("junk\x1b[?2026;1$y"), 2026), Mode_Status.Set)
}

@(test)
test_parse_mode_report_rejects_integer_overflow :: proc(t: ^testing.T) {
    // These values wrap to the requested mode/status under unchecked u32 arithmetic.
    mode_wrap := transmute([]u8)string("\x1b[?4294969344;1$y")
    status_wrap := transmute([]u8)string("\x1b[?2048;4294967297$y")
    testing.expect_value(t, parse_mode_report(mode_wrap, 2048), Mode_Status.Not_Recognized)
    testing.expect_value(t, parse_mode_report(status_wrap, 2048), Mode_Status.Not_Recognized)
}

@(test)
test_has_da_response :: proc(t: ^testing.T) {
    // A bare 'c' is not a CSI; a truncated CSI has no final byte.
    testing.expect(t, !has_da_response(transmute([]u8)string("c")))
    testing.expect(t, !has_da_response(transmute([]u8)string("\x1b[?64;1")))

    // A complete DA1 reply, even preceded by other bytes, is detected.
    testing.expect(t, has_da_response(transmute([]u8)string("key\x1b[?64;1c")))
    testing.expect(t, has_da_response(transmute([]u8)string("\x1b[c")))

    // A complete CSI ending in a non-'c' final is not a DA response.
    testing.expect(t, !has_da_response(transmute([]u8)string("\x1b[A")))
}

@(test)
test_csi_end :: proc(t: ^testing.T) {
    // Complete CSI: end index is one past the final byte.
    end, ok := csi_end(transmute([]u8)string("\x1b[?64;1c"), 0)
    testing.expect(t, ok)
    testing.expect_value(t, end, 8)

    // Not a CSI start.
    _, ok2 := csi_end(transmute([]u8)string("abc"), 0)
    testing.expect(t, !ok2)

    // Truncated: no final byte yet.
    _, ok3 := csi_end(transmute([]u8)string("\x1b[?64;1"), 0)
    testing.expect(t, !ok3)
}

@(test)
test_kitty_query_reply :: proc(t: ^testing.T) {
    expect_kitty_reply :: proc(t: ^testing.T, s: string, flags: u8, loc := #caller_location) {
        got, ok := kitty_query_reply(transmute([]u8)s)
        testing.expect(t, ok, "expected a Kitty reply", loc = loc)
        testing.expect_value(t, got, flags, loc = loc)
    }

    expect_no_kitty_reply :: proc(t: ^testing.T, s: string, loc := #caller_location) {
        _, ok := kitty_query_reply(transmute([]u8)s)
        testing.expect(t, !ok, "expected no Kitty reply", loc = loc)
    }

    // Kitty reply then DA1 -> supported, and the flags come back with it.
    expect_kitty_reply(t, "\x1b[?1u\x1b[?64;1c", 1)

    // The flags we push, echoed by a terminal that honored all of them.
    expect_kitty_reply(t, "\x1b[?31u\x1b[?64;1c", KITTY_FLAGS_WANTED)

    // DA1 only -> unsupported (the `?...c` is not a `?...u`).
    expect_no_kitty_reply(t, "\x1b[?64;1c")
    expect_no_kitty_reply(t, "")

    // DECRPM replies arrive before the Kitty reply on real terminals; they must not
    // poison detection.
    expect_kitty_reply(t, "\x1b[?25;2$y\x1b[?1u", 1)
    expect_kitty_reply(t, "\x1b[?25;2$y\x1b[?1049;2$y\x1b[?31u", 31)

    // A malformed Kitty-shaped block is skipped, and a later valid reply is accepted.
    expect_kitty_reply(t, "\x1b[?1;xu\x1b[?1u", 1)
    expect_no_kitty_reply(t, "\x1b[?1;xu")
}

@(test)
test_kitty_flags_response :: proc(t: ^testing.T) {
    flags, ok := kitty_flags_response(transmute([]u8)string("\x1b[?1u"))
    testing.expect(t, ok)
    testing.expect_value(t, flags, u8(1))

    flags2, ok2 := kitty_flags_response(transmute([]u8)string("\x1b[?25u"))
    testing.expect(t, ok2)
    testing.expect_value(t, flags2, u8(25))

    // Missing 'u' terminator, and a non-private `[` reply, both fail.
    _, ok3 := kitty_flags_response(transmute([]u8)string("\x1b[?1"))
    testing.expect(t, !ok3)
    _, ok4 := kitty_flags_response(transmute([]u8)string("\x1b[1u"))
    testing.expect(t, !ok4)
}

@(test)
test_is_probe_response :: proc(t: ^testing.T) {
    // DA1, Kitty flags, and DECRPM are probe replies.
    testing.expect(t, is_probe_response(transmute([]u8)string("\x1b[?64;1c")))
    testing.expect(t, is_probe_response(transmute([]u8)string("\x1b[?1u")))
    testing.expect(t, is_probe_response(transmute([]u8)string("\x1b[?2026;1$y")))

    // A real arrow key and a Kitty keystroke (no `?`) are not probe replies.
    testing.expect(t, !is_probe_response(transmute([]u8)string("\x1b[A")))
    testing.expect(t, !is_probe_response(transmute([]u8)string("\x1b[97u")))
}

@(test)
test_unprobed_mode_needs_enable :: proc(t: ^testing.T) {
    // Pre-existing (or permanently fixed) modes are not re-enabled.
    testing.expect(t, !unprobed_mode_needs_enable(.Set))
    testing.expect(t, !unprobed_mode_needs_enable(.Permanently_Set))
    testing.expect(t, !unprobed_mode_needs_enable(.Permanently_Reset))

    // A mode that is off, or that could not be queried, is enabled best-effort.
    testing.expect(t, unprobed_mode_needs_enable(.Reset))
    testing.expect(t, unprobed_mode_needs_enable(.Not_Recognized))
}

@(test)
test_preserve_non_probe_input :: proc(t: ^testing.T) {
    input: Reader
    reader_init(&input, context.allocator)
    defer reader_destroy(&input)

    // Probe replies (DECRPM, Kitty, DA1) are excised; the interleaved keystrokes
    // 'a', <up>, 'b' survive in order.
    err := preserve_non_probe_input(&input, transmute([]u8)string("a\x1b[?2026;2$y\x1b[?1u\x1b[?64;1c\x1b[Ab"))
    testing.expect_value(t, err, Reader_Error.None)

    expect_reader_char(t, &input, 'a')
    expect_reader_code(t, &input, .Up)
    expect_reader_char(t, &input, 'b')

    ev := reader_next(&input)
    testing.expect(t, ev == nil, "expected no further events")
}

@(test)
test_restore_presentation_writes :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)
    w := strings.to_writer(&b)

    // cursor .Set -> show, synchronized_output .Reset -> end.
    restore_presentation(w, .Set, .Reset)
    out := strings.to_string(b)
    testing.expect(t, strings.contains(out, SYNC_UPDATE_END))
    testing.expect(t, strings.contains(out, CURSOR_SHOW))

    // A not-recognized cursor falls back to showing; not-recognized sync writes nothing.
    strings.builder_reset(&b)
    restore_presentation(w, .Not_Recognized, .Not_Recognized)
    out2 := strings.to_string(b)
    testing.expect(t, strings.contains(out2, CURSOR_SHOW))
    testing.expect(t, !strings.contains(out2, SYNC_UPDATE_BEGIN))
    testing.expect(t, !strings.contains(out2, SYNC_UPDATE_END))
}

@(test)
test_invalid_query_timeout :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)
    w := strings.to_writer(&b)

    input: Reader
    reader_init(&input, context.allocator)
    defer reader_destroy(&input)

    opts := DEFAULT_OPTIONS
    opts.query_timeout_ms = -1

    // The negative-timeout guard fires before the terminal is touched, so this handle is
    // never read. Zero-valued to stay portable across the per-OS `Tty_Handle`.
    dummy: Tty_Handle
    _, err := session_enter(dummy, dummy, w, &input, opts)
    testing.expect_value(t, err, Session_Error.Invalid_Query_Timeout)
    testing.expect_value(t, len(strings.to_string(b)), 0)
}

@(test)
test_negotiate_balances_temporary_kitty_push :: proc(t: ^testing.T) {
    src_r, src_w, ok := inject_open()
    testing.expect(t, ok, "probe pipe")
    defer {
        inject_close(src_r)
        inject_close(src_w)
    }
    testing.expect(t, inject_write(src_w, "\x1b[?31u\x1b[?64;1c"), "probe replies")

    input: Reader
    reader_init(&input, context.allocator)
    defer reader_destroy(&input)

    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    negotiated, err := negotiate(src_r, strings.to_writer(&b), &input, 100, true)
    testing.expect_value(t, err, Session_Error.None)
    testing.expect(t, negotiated.kitty_keyboard)
    testing.expect_value(t, negotiated.kitty_flags, KITTY_FLAGS_WANTED)

    out := strings.to_string(b)
    push_i := strings.index(out, KITTY_PUSH_FLAGS)
    query_i := strings.index(out, KITTY_QUERY)
    da_i := strings.index(out, DA1_REQUEST)
    pop_i := strings.index(out, KITTY_POP)
    testing.expect(t, push_i >= 0 && query_i >= 0 && da_i >= 0 && pop_i >= 0)
    testing.expect(
        t,
        push_i < query_i && query_i < da_i && da_i < pop_i,
        "probe push must be balanced before mode setup",
    )
}

// A full `session_enter` needs a real tty for raw mode, so the disable ordering is
// exercised through `restore` into a builder-backed writer.
@(test)
test_restore_disables_in_reverse :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)
    w := strings.to_writer(&b)

    // Everything enabled: `restore` must emit the disables in reverse of enable order,
    // Kitty first and alt-screen last.
    all := Enabled {
        alternate_screen = true,
        bracketed_paste  = true,
        in_band_resize   = true,
        mouse            = true,
        mouse_sgr        = true,
        kitty_keyboard   = true,
    }
    restore(w, all)

    out := strings.to_string(b)
    ki := strings.index(out, KITTY_POP)
    mi := strings.index(out, MOUSE_TRACKING_DISABLE)
    ri := strings.index(out, IN_BAND_RESIZE_DISABLE)
    pi := strings.index(out, BRACKETED_PASTE_DISABLE)
    ai := strings.index(out, ALT_SCREEN_EXIT)

    testing.expect(t, ki >= 0 && mi >= 0 && ri >= 0 && pi >= 0 && ai >= 0)
    testing.expect(t, ki < mi && mi < ri && ri < pi && pi < ai, "disables must be in reverse order")
}

@(test)
test_enable_modes_pushes_kitty_after_screen_transition :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    options := DEFAULT_OPTIONS
    options.mouse = true
    negotiated := Negotiated {
        alternate_screen = .Reset,
        bracketed_paste  = .Reset,
        in_band_resize   = .Reset,
        mouse            = .Reset,
        mouse_sgr        = .Reset,
        kitty_keyboard   = true,
    }

    enabled, err := enable_modes(strings.to_writer(&b), options, negotiated)
    testing.expect_value(t, err, Session_Error.None)
    testing.expect(t, enabled.alternate_screen && enabled.kitty_keyboard)

    out := strings.to_string(b)
    alternate := strings.index(out, ALT_SCREEN_ENTER)
    paste := strings.index(out, BRACKETED_PASTE_ENABLE)
    resize := strings.index(out, IN_BAND_RESIZE_ENABLE)
    mouse := strings.index(out, MOUSE_TRACKING_ENABLE)
    mouse_sgr := strings.index(out, MOUSE_SGR_ENABLE)
    kitty := strings.index(out, KITTY_PUSH_FLAGS)

    testing.expect(t, alternate >= 0 && paste >= 0 && resize >= 0 && mouse >= 0 && mouse_sgr >= 0 && kitty >= 0)
    testing.expect(
        t,
        alternate < paste && paste < resize && resize < mouse && mouse < mouse_sgr && mouse_sgr < kitty,
        "Kitty must be pushed on the selected screen",
    )
}

@(test)
test_session_leave_zero_session_is_idempotent :: proc(t: ^testing.T) {
    session: Session
    session_leave(&session)
    session_leave(&session)
    testing.expect(t, !session.active)
}

@(test)
test_restore_only_enabled_modes :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)
    w := strings.to_writer(&b)

    // A cleared Enabled (the state after `session_leave` resets it) writes nothing, so a
    // second leave is a no-op for the modes.
    restore(w, {})
    testing.expect_value(t, len(strings.to_string(b)), 0)

    // Only the recorded modes are disabled.
    restore(w, {bracketed_paste = true})
    out := strings.to_string(b)
    testing.expect(t, strings.contains(out, BRACKETED_PASTE_DISABLE))
    testing.expect(t, !strings.contains(out, ALT_SCREEN_EXIT))
    testing.expect(t, !strings.contains(out, KITTY_POP))
}

// Assert the next reader event is a literal-char key with `char`.
expect_reader_char :: proc(t: ^testing.T, r: ^Reader, char: rune, loc := #caller_location) {
    ev := reader_next(r)
    k, ok := ev.(Key)
    testing.expect(t, ok, "expected a key event", loc = loc)
    testing.expect_value(t, k.code, Key_Code.Char, loc = loc)
    testing.expect_value(t, k.char, char, loc = loc)
}

// Assert the next reader event is a named key with `code`.
expect_reader_code :: proc(t: ^testing.T, r: ^Reader, code: Key_Code, loc := #caller_location) {
    ev := reader_next(r)
    k, ok := ev.(Key)
    testing.expect(t, ok, "expected a key event", loc = loc)
    testing.expect_value(t, k.code, code, loc = loc)
}

@(test)
test_kitty_text_capability_tracks_the_reported_flags :: proc(t: ^testing.T) {
    // Flag 8 routes every key through `CSI u`, which makes flag 16 the only source of
    // associated text. A terminal that keeps 8 and drops 16 must not look like it reports
    // text, so the capability comes from the reply rather than from what was pushed.
    honored := negotiated_capabilities(Negotiated{kitty_keyboard = true, kitty_flags = 31})
    testing.expect(t, honored.kitty_keyboard)
    testing.expect(t, honored.kitty_text)

    partial := negotiated_capabilities(Negotiated{kitty_keyboard = true, kitty_flags = 15})
    testing.expect(t, partial.kitty_keyboard)
    testing.expect(t, !partial.kitty_text)

    // No Kitty reply at all: neither the protocol nor its text channel.
    none := negotiated_capabilities(Negotiated{})
    testing.expect(t, !none.kitty_keyboard)
    testing.expect(t, !none.kitty_text)
}

@(test)
test_kitty_flags_response_rejects_oversized_values :: proc(t: ^testing.T) {
    // The flag field is five bits wide; a value past max(u8) is malformed, not truncated.
    // Accumulating into a narrow integer would have folded 256 back to 0 and reported it
    // as a valid "no flags" reply.
    _, ok := kitty_flags_response(transmute([]u8)string("\x1b[?256u"))
    testing.expect(t, !ok)

    _, huge := kitty_flags_response(transmute([]u8)string("\x1b[?99999999999u"))
    testing.expect(t, !huge)

    max_flags, max_ok := kitty_flags_response(transmute([]u8)string("\x1b[?255u"))
    testing.expect(t, max_ok)
    testing.expect_value(t, max_flags, u8(255))
}
