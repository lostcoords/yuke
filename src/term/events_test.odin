package term

import "core:testing"

// Drive a fresh parser byte-by-byte; return the first completed event (or nil).
feed :: proc(s: string) -> Parse_Event {
    p: Parser
    for i in 0 ..< len(s) {
        ev := parser_step(&p, s[i])
        if ev != nil {
            return ev
        }
    }

    return nil
}

// Assert `ev` is a Key with the given code and return it for further checks.
expect_key :: proc(t: ^testing.T, ev: Parse_Event, code: Key_Code, loc := #caller_location) -> Key {
    k, ok := ev.(Key)
    testing.expect(t, ok, "expected a key event", loc = loc)
    testing.expect_value(t, k.code, code, loc = loc)

    return k
}

@(test)
test_machine_arrow_keys :: proc(t: ^testing.T) {
    expect_key(t, feed("\x1b[A"), .Up)
    expect_key(t, feed("\x1b[B"), .Down)
    expect_key(t, feed("\x1b[C"), .Right)
    expect_key(t, feed("\x1b[D"), .Left)
}

@(test)
test_machine_ctrl_right_modified_arrow :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[1;5C"), .Right)
    testing.expect(t, .Ctrl in k.mods)
    testing.expect(t, .Shift not_in k.mods)
    testing.expect(t, .Alt not_in k.mods)
}

@(test)
test_machine_shift_alt_up :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[1;4A"), .Up)
    testing.expect(t, .Shift in k.mods)
    testing.expect(t, .Alt in k.mods)
    testing.expect(t, .Ctrl not_in k.mods)
}

@(test)
test_machine_tilde_keys :: proc(t: ^testing.T) {
    expect_key(t, feed("\x1b[2~"), .Insert)
    expect_key(t, feed("\x1b[3~"), .Delete)
    expect_key(t, feed("\x1b[5~"), .Page_Up)
    expect_key(t, feed("\x1b[15~"), .F5)
    expect_key(t, feed("\x1b[24~"), .F12)
}

@(test)
test_machine_tilde_gaps_are_invalid :: proc(t: ^testing.T) {
    // Codes 16 and 22 are deliberate gaps in the tilde table.
    _, ok16 := feed("\x1b[16~").(Invalid)
    testing.expect(t, ok16)
    _, ok22 := feed("\x1b[22~").(Invalid)
    testing.expect(t, ok22)
}

@(test)
test_machine_bracketed_paste_markers :: proc(t: ^testing.T) {
    _, ps := feed("\x1b[200~").(Paste_Start)
    testing.expect(t, ps)
    _, pe := feed("\x1b[201~").(Paste_End)
    testing.expect(t, pe)
}

@(test)
test_machine_in_band_resize_report :: proc(t: ^testing.T) {
    _, ok := feed("\x1b[48;24;80;600;800t").(Resize)
    testing.expect(t, ok)

    // A CSI ... t not led by 48 is not a resize.
    _, bad := feed("\x1b[8;24;80t").(Invalid)
    testing.expect(t, bad)
}

@(test)
test_machine_ss3_function_keys :: proc(t: ^testing.T) {
    expect_key(t, feed("\x1bOP"), .F1)
    expect_key(t, feed("\x1bOQ"), .F2)
    expect_key(t, feed("\x1bOR"), .F3)
    expect_key(t, feed("\x1bOS"), .F4)
    expect_key(t, feed("\x1bOH"), .Home)
    expect_key(t, feed("\x1bOF"), .End)

    _, bad := feed("\x1bOX").(Invalid)
    testing.expect(t, bad)
}

@(test)
test_machine_shift_tab :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[Z"), .Tab)
    testing.expect(t, .Shift in k.mods)
}

@(test)
test_machine_control_chars :: proc(t: ^testing.T) {
    c := expect_key(t, feed("\x01"), .Char)
    testing.expect(t, .Ctrl in c.mods)
    testing.expect_value(t, c.char, 'a')

    expect_key(t, feed("\r"), .Enter)
    expect_key(t, feed("\n"), .Enter)
    expect_key(t, feed("\t"), .Tab)
    expect_key(t, feed("\x08"), .Backspace)
    expect_key(t, feed("\x7f"), .Backspace)
}

@(test)
test_machine_ascii_and_utf8 :: proc(t: ^testing.T) {
    a := expect_key(t, feed("a"), .Char)
    testing.expect_value(t, a.char, 'a')
    testing.expect(t, a.mods == {})

    // é = U+00E9 = 0xC3 0xA9
    e := expect_key(t, feed("\xc3\xa9"), .Char)
    testing.expect_value(t, e.char, rune(0xE9))
}

@(test)
test_machine_uppercase_synthesizes_shift :: proc(t: ^testing.T) {
    // Ground path: uppercase ASCII becomes shift + lowercase.
    k := expect_key(t, feed("A"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Shift in k.mods)
}

@(test)
test_machine_alt_char_keeps_raw_byte :: proc(t: ^testing.T) {
    // Alt path (ESC + char) keeps the raw byte: no shift synthesis on uppercase.
    k := expect_key(t, feed("\x1bx"), .Char)
    testing.expect_value(t, k.char, 'x')
    testing.expect(t, .Alt in k.mods)

    up := expect_key(t, feed("\x1bA"), .Char)
    testing.expect_value(t, up.char, 'A')
    testing.expect(t, .Alt in up.mods)
    testing.expect(t, .Shift not_in up.mods)
}

@(test)
test_machine_ctrl_alt_char :: proc(t: ^testing.T) {
    // ESC + ctrl char = ctrl+alt, char = raw + 0x60.
    k := expect_key(t, feed("\x1b\x01"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Ctrl in k.mods)
    testing.expect(t, .Alt in k.mods)
}

@(test)
test_machine_invalid_utf8_lead :: proc(t: ^testing.T) {
    // A bare continuation byte is not a valid lead byte.
    _, ok := feed("\xa9").(Invalid)
    testing.expect(t, ok)
}

@(test)
test_machine_partial_sequences_yield_no_event :: proc(t: ^testing.T) {
    testing.expect(t, feed("\x1b[") == nil)
    testing.expect(t, feed("\x1b[1;5") == nil)
    testing.expect(t, feed("\xc3") == nil)
}

@(test)
test_machine_x10_mouse :: proc(t: ^testing.T) {
    // ESC [ M <button+32> <x+32> <y+32>; left press, x=1, y=2
    m, ok := feed("\x1b[M\x20\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.action, Mouse_Action.Left)
    testing.expect_value(t, m.x, u16(1))
    testing.expect_value(t, m.y, u16(2))
    testing.expect(t, !m.shift && !m.alt && !m.ctrl)
}

@(test)
test_machine_x10_mouse_saturates_coords :: proc(t: ^testing.T) {
    // Payload bytes below the 32 bias saturate to 0.
    m, ok := feed("\x1b[M\x20\x00\x1f").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.x, u16(0))
    testing.expect_value(t, m.y, u16(0))
}

@(test)
test_machine_x10_mouse_shift_only :: proc(t: ^testing.T) {
    // Mask fix: shift bit is 4. Button 0 + shift = 0x04; +32 bias = 0x24.
    m, ok := feed("\x1b[M\x24\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.action, Mouse_Action.Left)
    testing.expect(t, m.shift)
    testing.expect(t, !m.alt)
    testing.expect(t, !m.ctrl)
}

@(test)
test_machine_x10_mouse_alt_only :: proc(t: ^testing.T) {
    // Alt/meta bit is 8. Button 0 + alt = 0x08; +32 bias = 0x28. Distinguishable from
    // a shift-only event, which uses bit 4.
    m, ok := feed("\x1b[M\x28\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.action, Mouse_Action.Left)
    testing.expect(t, m.alt)
    testing.expect(t, !m.shift)
    testing.expect(t, !m.ctrl)
}

@(test)
test_machine_x10_mouse_ctrl_only :: proc(t: ^testing.T) {
    // Ctrl bit is 16. Button 0 + ctrl = 0x10; +32 bias = 0x30.
    m, ok := feed("\x1b[M\x30\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect(t, m.ctrl)
    testing.expect(t, !m.shift)
    testing.expect(t, !m.alt)
}

@(test)
test_machine_x10_mouse_actions :: proc(t: ^testing.T) {
    middle, _ := feed("\x1b[M\x21\x21\x22").(Mouse)
    testing.expect_value(t, middle.action, Mouse_Action.Middle)
    right, _ := feed("\x1b[M\x22\x21\x22").(Mouse)
    testing.expect_value(t, right.action, Mouse_Action.Right)
    release, _ := feed("\x1b[M\x23\x21\x22").(Mouse)
    testing.expect_value(t, release.action, Mouse_Action.Release)

    // Bit 6 (0x40) marks scroll/drag; +32 bias = 0x60 base.
    scroll_up, _ := feed("\x1b[M\x60\x21\x22").(Mouse)
    testing.expect_value(t, scroll_up.action, Mouse_Action.Scroll_Up)
    scroll_down, _ := feed("\x1b[M\x61\x21\x22").(Mouse)
    testing.expect_value(t, scroll_down.action, Mouse_Action.Scroll_Down)
    move_rc, _ := feed("\x1b[M\x62\x21\x22").(Mouse)
    testing.expect_value(t, move_rc.action, Mouse_Action.Move_Rightclick)
    move, _ := feed("\x1b[M\x63\x21\x22").(Mouse)
    testing.expect_value(t, move.action, Mouse_Action.Move)
}

@(test)
test_machine_sgr_mouse_unsupported :: proc(t: ^testing.T) {
    // SGR mouse (`ESC [ < ... M`) is not X10 and stays unsupported.
    _, ok := feed("\x1b[<0;1;2M").(Invalid)
    testing.expect(t, ok)
}

@(test)
test_kitty_plain_codepoint :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[97u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, k.mods == {})
    testing.expect_value(t, k.event, Key_Event.Press)
}

@(test)
test_kitty_ctrl_a_via_modifier_group :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[97;5u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Ctrl in k.mods)
    testing.expect(t, .Shift not_in k.mods)
    testing.expect(t, .Alt not_in k.mods)
}

@(test)
test_kitty_super_modifier :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[97;9u"), .Char)
    testing.expect(t, .Super in k.mods)
    testing.expect(t, .Ctrl not_in k.mods)
}

@(test)
test_kitty_functional_keys :: proc(t: ^testing.T) {
    expect_key(t, feed("\x1b[57352u"), .Up)
    expect_key(t, feed("\x1b[57356u"), .Home)
    expect_key(t, feed("\x1b[57364u"), .F1)
    expect_key(t, feed("\x1b[57375u"), .F12)
}

@(test)
test_kitty_functional_key_gap :: proc(t: ^testing.T) {
    // 57358 sits in the deliberate gap: it is treated as a literal codepoint.
    k := expect_key(t, feed("\x1b[57358u"), .Char)
    testing.expect_value(t, k.char, rune(57358))
}

@(test)
test_kitty_legacy_c0_keys :: proc(t: ^testing.T) {
    expect_key(t, feed("\x1b[13u"), .Enter)
    expect_key(t, feed("\x1b[9u"), .Tab)
    expect_key(t, feed("\x1b[27u"), .Esc)
    expect_key(t, feed("\x1b[8u"), .Backspace)
    expect_key(t, feed("\x1b[127u"), .Backspace)
}

@(test)
test_kitty_event_type_from_second_sub_param :: proc(t: ^testing.T) {
    testing.expect_value(t, expect_key(t, feed("\x1b[97;1:1u"), .Char).event, Key_Event.Press)
    testing.expect_value(t, expect_key(t, feed("\x1b[97;1:2u"), .Char).event, Key_Event.Repeat)
    testing.expect_value(t, expect_key(t, feed("\x1b[97;1:3u"), .Char).event, Key_Event.Release)
}

@(test)
test_kitty_shift_keeps_lowercase_codepoint :: proc(t: ^testing.T) {
    // Unlike the ground path, Kitty keeps the codepoint verbatim under shift.
    k := expect_key(t, feed("\x1b[97;2u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Shift in k.mods)
}

@(test)
test_kitty_uppercase_codepoint_verbatim :: proc(t: ^testing.T) {
    // Codepoint 65 ('A') is kept verbatim; no shift synthesis on the Kitty path.
    k := expect_key(t, feed("\x1b[65u"), .Char)
    testing.expect_value(t, k.char, 'A')
    testing.expect(t, .Shift not_in k.mods)
}

@(test)
test_kitty_query_response_is_not_a_key :: proc(t: ^testing.T) {
    // `?`-private payload is a query reply and must never become a keystroke.
    _, ok := feed("\x1b[?1u").(Invalid)
    testing.expect(t, ok)
}

@(test)
test_parse_single_char_one_byte_consumed :: proc(t: ^testing.T) {
    event, consumed, incomplete := parse(transmute([]u8)string("a"))
    testing.expect(t, !incomplete)
    testing.expect_value(t, consumed, 1)
    k, ok := event.(Key)
    testing.expect(t, ok)
    testing.expect_value(t, k.char, 'a')
}

@(test)
test_parse_arrow_up_three_bytes_consumed :: proc(t: ^testing.T) {
    event, consumed, incomplete := parse(transmute([]u8)string("\x1b[A"))
    testing.expect(t, !incomplete)
    testing.expect_value(t, consumed, 3)
    expect_key(t, event, .Up)
}

@(test)
test_parse_consumes_only_the_events_bytes :: proc(t: ^testing.T) {
    // Trailing 'x' is left for the next parse.
    _, consumed, incomplete := parse(transmute([]u8)string("\x1b[Ax"))
    testing.expect(t, !incomplete)
    testing.expect_value(t, consumed, 3)
}

@(test)
test_parse_incomplete_on_partial_or_empty :: proc(t: ^testing.T) {
    _, _, i1 := parse(transmute([]u8)string("\x1b["))
    testing.expect(t, i1)
    _, _, i2 := parse(transmute([]u8)string("\x1b"))
    testing.expect(t, i2)
    _, _, i3 := parse(transmute([]u8)string(""))
    testing.expect(t, i3)
}

@(test)
test_flush_lone_esc_and_empty :: proc(t: ^testing.T) {
    expect_key(t, flush(transmute([]u8)string("\x1b")), .Esc)
    testing.expect(t, flush(transmute([]u8)string("")) == nil)
}

@(test)
test_flush_truncated_invalid_complete_parses :: proc(t: ^testing.T) {
    _, ok := flush(transmute([]u8)string("\x1b[")).(Invalid)
    testing.expect(t, ok)
    expect_key(t, flush(transmute([]u8)string("\x1b[A")), .Up)
}
