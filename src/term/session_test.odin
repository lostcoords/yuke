package term

import "core:strings"
import "core:testing"

// --- pure scanner tests: no tty required ---

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
test_kitty_supported :: proc(t: ^testing.T) {
    // Kitty reply then DA1 -> supported.
    testing.expect(t, kitty_supported(transmute([]u8)string("\x1b[?1u\x1b[?64;1c")))

    // DA1 only -> unsupported (the `?...c` is not a `?...u`).
    testing.expect(t, !kitty_supported(transmute([]u8)string("\x1b[?64;1c")))
    testing.expect(t, !kitty_supported(transmute([]u8)string("")))

    // DECRPM replies arrive before the Kitty reply on real terminals; they must not
    // poison detection.
    testing.expect(t, kitty_supported(transmute([]u8)string("\x1b[?25;2$y\x1b[?1u")))
    testing.expect(t, kitty_supported(transmute([]u8)string("\x1b[?25;2$y\x1b[?1049;2$y\x1b[?1u")))

    // A malformed Kitty-shaped block is skipped, and a later valid reply is accepted.
    testing.expect(t, kitty_supported(transmute([]u8)string("\x1b[?1;xu\x1b[?1u")))
    testing.expect(t, !kitty_supported(transmute([]u8)string("\x1b[?1;xu")))
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

    ev, nerr := reader_next(&input)
    testing.expect_value(t, nerr, Reader_Error.None)
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

    // The negative-timeout guard fires before the terminal is touched, so this dummy
    // handle is never read and nothing is written. Zero-valued so it is portable across
    // the per-OS `Tty_Handle` (a POSIX fd vs a Windows HANDLE).
    dummy: Tty_Handle
    _, err := session_enter(dummy, dummy, w, &input, opts)
    testing.expect_value(t, err, Session_Error.Invalid_Query_Timeout)
    testing.expect_value(t, len(strings.to_string(b)), 0)
}

// --- restore write-ordering (no tty required) ---
//
// A full `session_enter` needs a real tty for raw mode, so the disable ordering is
// exercised directly through `restore`, driven into a builder-backed writer.

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

// --- test helpers ---

// Assert the next reader event is a literal-char key with `char`.
expect_reader_char :: proc(t: ^testing.T, r: ^Reader, char: rune, loc := #caller_location) {
    ev, err := reader_next(r)
    testing.expect_value(t, err, Reader_Error.None, loc = loc)
    k, ok := ev.(Key)
    testing.expect(t, ok, "expected a key event", loc = loc)
    testing.expect_value(t, k.code, Key_Code.Char, loc = loc)
    testing.expect_value(t, k.char, char, loc = loc)
}

// Assert the next reader event is a named key with `code`.
expect_reader_code :: proc(t: ^testing.T, r: ^Reader, code: Key_Code, loc := #caller_location) {
    ev, err := reader_next(r)
    testing.expect_value(t, err, Reader_Error.None, loc = loc)
    k, ok := ev.(Key)
    testing.expect(t, ok, "expected a key event", loc = loc)
    testing.expect_value(t, k.code, code, loc = loc)
}
