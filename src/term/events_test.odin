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

// Assert the text `k` produced. `key_text` borrows, so `k` must be addressable here.
expect_text :: proc(t: ^testing.T, k: Key, text: string, loc := #caller_location) {
    k := k
    testing.expect_value(t, key_text(&k), text, loc = loc)
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
test_machine_event_type_on_legacy_forms :: proc(t: ^testing.T) {
    // Keys with a legacy escape code keep it, so the event type rides along in the
    // modifier group here too.
    release := expect_key(t, feed("\x1b[1;5:3C"), .Right)
    testing.expect_value(t, release.event, Key_Event.Release)
    testing.expect(t, .Ctrl in release.mods)

    repeat := expect_key(t, feed("\x1b[3;1:2~"), .Delete)
    testing.expect_value(t, repeat.event, Key_Event.Repeat)

    // No event group at all is a press.
    testing.expect_value(t, expect_key(t, feed("\x1b[A"), .Up).event, Key_Event.Press)
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
    // Codes 16 and 22 are unassigned in the tilde table.
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

    // Shift stays forced, but the lock state and event type are still reported.
    modified := expect_key(t, feed("\x1b[1;65:3Z"), .Tab)
    testing.expect(t, .Shift in modified.mods)
    testing.expect(t, .Caps in modified.locks)
    testing.expect_value(t, modified.event, Key_Event.Release)
}

@(test)
test_machine_control_chars :: proc(t: ^testing.T) {
    c := expect_key(t, feed("\x01"), .Char)
    testing.expect(t, .Ctrl in c.mods)
    testing.expect_value(t, c.char, 'a')
    expect_text(t, c, "") // a control code is never text

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
    expect_text(t, a, "a")

    // é = U+00E9 = 0xC3 0xA9
    e := expect_key(t, feed("\xc3\xa9"), .Char)
    testing.expect_value(t, e.char, rune(0xE9))
    expect_text(t, e, "é")
}

@(test)
test_machine_uppercase_is_reported_as_typed :: proc(t: ^testing.T) {
    // The terminal resolved the character, so it is the text. `char` names the key, which
    // case-folds to match what Kitty reports for the same physical key — but no Shift is
    // invented from it, because Caps Lock produces the same byte.
    k := expect_key(t, feed("A"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, k.mods == {})
    testing.expect_value(t, k.shifted, rune(0))
    testing.expect_value(t, k.base_layout, rune(0))
    expect_text(t, k, "A")

    // Shift+1 is the same story: no modifier is recoverable from the character.
    bang := expect_key(t, feed("!"), .Char)
    testing.expect_value(t, bang.char, '!')
    testing.expect(t, bang.mods == {})
    expect_text(t, bang, "!")
}

@(test)
test_machine_alt_char_keeps_raw_byte_without_text :: proc(t: ^testing.T) {
    // Alt path (ESC + char) keeps the raw byte and produces no text.
    k := expect_key(t, feed("\x1bx"), .Char)
    testing.expect_value(t, k.char, 'x')
    testing.expect(t, .Alt in k.mods)
    testing.expect_value(t, k.shifted, rune(0))
    expect_text(t, k, "")

    // `char` names the key, so Alt+A answers to 'a'. Shift is not invented from the case,
    // but the character the terminal resolved survives in `shifted`.
    up := expect_key(t, feed("\x1bA"), .Char)
    testing.expect_value(t, up.char, 'a')
    testing.expect_value(t, up.shifted, 'A')
    testing.expect(t, .Alt in up.mods)
    testing.expect(t, .Shift not_in up.mods)
    expect_text(t, up, "")
}

@(test)
test_machine_alt_non_ascii_assembles_the_whole_codepoint :: proc(t: ^testing.T) {
    // Alt+é arrives as ESC plus a two-byte sequence. Consuming only the lead byte would
    // report 'Ã' and leave the continuation to fail as a stray byte.
    e := expect_key(t, feed("\x1b\xc3\xa9"), .Char)
    testing.expect_value(t, e.char, rune(0xE9))
    testing.expect(t, e.mods == {.Alt})
    expect_text(t, e, "")

    // Four-byte lead, and the fold leaves a non-ASCII key alone.
    emoji := expect_key(t, feed("\x1b\xf0\x9f\x98\x80"), .Char)
    testing.expect_value(t, emoji.char, rune(0x1F600))
    testing.expect_value(t, emoji.shifted, rune(0))

    // Three-byte lead.
    cjk := expect_key(t, feed("\x1b\xe6\x97\xa5"), .Char)
    testing.expect_value(t, cjk.char, rune(0x65E5))

    // A truncated sequence is incomplete, not a key.
    _, _, incomplete := parse(transmute([]u8)string("\x1b\xc3"))
    testing.expect(t, incomplete)

    // A bad continuation byte is rejected rather than mangled.
    _, bad := feed("\x1b\xc3z").(Invalid)
    testing.expect(t, bad)

    // A continuation byte with no lead is not a key either; it used to be reported as
    // Alt + that byte.
    _, stray := feed("\x1b\x80").(Invalid)
    testing.expect(t, stray)
    _, never := feed("\x1b\xff").(Invalid)
    testing.expect(t, never)
}

@(test)
test_machine_ctrl_alt_char :: proc(t: ^testing.T) {
    // ESC + ctrl char = ctrl+alt, char = raw + 0x60.
    k := expect_key(t, feed("\x1b\x01"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Ctrl in k.mods)
    testing.expect(t, .Alt in k.mods)
    expect_text(t, k, "")
}

@(test)
test_machine_named_keys_carry_no_text :: proc(t: ^testing.T) {
    expect_text(t, expect_key(t, feed("\r"), .Enter), "")
    expect_text(t, expect_key(t, feed("\t"), .Tab), "")
    expect_text(t, expect_key(t, feed("\x7f"), .Backspace), "")
    expect_text(t, expect_key(t, feed("\x1b[A"), .Up), "")
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
    // ESC [ M <button+32> <x+32> <y+32>. Coordinates are 1-based on the wire, so bytes
    // 0x21/0x22 are columns 1/2 and decode to 0-based cells 0/1.
    m, ok := feed("\x1b[M\x20\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.event, Mouse_Event.Press)
    testing.expect_value(t, m.button, Mouse_Button.Left)
    testing.expect_value(t, m.x, u16(0))
    testing.expect_value(t, m.y, u16(1))
    testing.expect(t, m.mods == {})
}

@(test)
test_machine_x10_mouse_saturates_coords :: proc(t: ^testing.T) {
    // Payload bytes below the bias saturate to 0 rather than wrapping. 0x20 is the
    // out-of-range column 0.
    m, ok := feed("\x1b[M\x20\x00\x20").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.x, u16(0))
    testing.expect_value(t, m.y, u16(0))
}

@(test)
test_machine_x10_mouse_shift_only :: proc(t: ^testing.T) {
    // Shift bit is 4. Button 0 + shift = 0x04; +32 bias = 0x24.
    m, ok := feed("\x1b[M\x24\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.button, Mouse_Button.Left)
    testing.expect(t, m.mods == {.Shift})
}

@(test)
test_machine_x10_mouse_alt_only :: proc(t: ^testing.T) {
    // Alt/meta bit is 8. Button 0 + alt = 0x08; +32 bias = 0x28. Distinguishable from
    // a shift-only event, which uses bit 4.
    m, ok := feed("\x1b[M\x28\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.button, Mouse_Button.Left)
    testing.expect(t, m.mods == {.Alt})
}

@(test)
test_machine_x10_mouse_ctrl_only :: proc(t: ^testing.T) {
    // Ctrl bit is 16. Button 0 + ctrl = 0x10; +32 bias = 0x30.
    m, ok := feed("\x1b[M\x30\x21\x22").(Mouse)
    testing.expect(t, ok)
    testing.expect(t, m.mods == {.Ctrl})
}

@(test)
test_machine_x10_mouse_buttons :: proc(t: ^testing.T) {
    middle, _ := feed("\x1b[M\x21\x21\x22").(Mouse)
    testing.expect_value(t, middle.event, Mouse_Event.Press)
    testing.expect_value(t, middle.button, Mouse_Button.Middle)

    right, _ := feed("\x1b[M\x22\x21\x22").(Mouse)
    testing.expect_value(t, right.button, Mouse_Button.Right)

    // X10 reports every release with the generic button id 3, so the button that came
    // up is unknowable here; only SGR names it.
    release, _ := feed("\x1b[M\x23\x21\x22").(Mouse)
    testing.expect_value(t, release.event, Mouse_Event.Release)
    testing.expect_value(t, release.button, Mouse_Button.None)
}

@(test)
test_machine_x10_mouse_wheel :: proc(t: ^testing.T) {
    // Bit 6 (0x40) selects buttons 4-7; +32 bias = 0x60 base. A notch is always a press.
    up, _ := feed("\x1b[M\x60\x21\x22").(Mouse)
    testing.expect_value(t, up.event, Mouse_Event.Press)
    testing.expect_value(t, up.button, Mouse_Button.Wheel_Up)

    down, _ := feed("\x1b[M\x61\x21\x22").(Mouse)
    testing.expect_value(t, down.button, Mouse_Button.Wheel_Down)

    // 0x62/0x63 are horizontal wheel, not motion: bit 5 is what marks motion.
    left, _ := feed("\x1b[M\x62\x21\x22").(Mouse)
    testing.expect_value(t, left.button, Mouse_Button.Wheel_Left)

    right, _ := feed("\x1b[M\x63\x21\x22").(Mouse)
    testing.expect_value(t, right.button, Mouse_Button.Wheel_Right)
}

@(test)
test_machine_x10_mouse_motion :: proc(t: ^testing.T) {
    // Bit 5 (0x20) marks motion; +32 bias = 0x40 base. Ignoring it made a drag read as a
    // fresh press and a bare move read as a release.
    drag_left, _ := feed("\x1b[M\x40\x21\x22").(Mouse)
    testing.expect_value(t, drag_left.event, Mouse_Event.Move)
    testing.expect_value(t, drag_left.button, Mouse_Button.Left)

    drag_right, _ := feed("\x1b[M\x42\x21\x22").(Mouse)
    testing.expect_value(t, drag_right.event, Mouse_Event.Move)
    testing.expect_value(t, drag_right.button, Mouse_Button.Right)

    // Motion with button id 3 is a bare move under mode 1003, not a release.
    bare, _ := feed("\x1b[M\x43\x21\x22").(Mouse)
    testing.expect_value(t, bare.event, Mouse_Event.Move)
    testing.expect_value(t, bare.button, Mouse_Button.None)
}

@(test)
test_machine_sgr_mouse :: proc(t: ^testing.T) {
    // `CSI < Cb ; Cx ; Cy M` is press/motion; coordinates are 1-based decimal.
    press, ok := feed("\x1b[<0;1;2M").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, press.event, Mouse_Event.Press)
    testing.expect_value(t, press.button, Mouse_Button.Left)
    testing.expect_value(t, press.x, u16(0))
    testing.expect_value(t, press.y, u16(1))

    // The `m` final is release, and unlike X10 the low bits still name the button.
    release, rok := feed("\x1b[<2;1;2m").(Mouse)
    testing.expect(t, rok)
    testing.expect_value(t, release.event, Mouse_Event.Release)
    testing.expect_value(t, release.button, Mouse_Button.Right)

    // Modifiers and the motion bit ride the same Cb layout as X10.
    drag, dok := feed("\x1b[<36;1;1M").(Mouse)
    testing.expect(t, dok)
    testing.expect_value(t, drag.event, Mouse_Event.Move)
    testing.expect_value(t, drag.button, Mouse_Button.Left)
    testing.expect(t, drag.mods == {.Shift})
}

@(test)
test_machine_sgr_mouse_past_x10_ceiling :: proc(t: ^testing.T) {
    // The whole point of SGR: bias-32 bytes cannot address past cell 223.
    m, ok := feed("\x1b[<0;500;300M").(Mouse)
    testing.expect(t, ok)
    testing.expect_value(t, m.x, u16(499))
    testing.expect_value(t, m.y, u16(299))
}

@(test)
test_machine_sgr_mouse_rejects_malformed :: proc(t: ^testing.T) {
    // Wrong parameter count is not a mouse report.
    _, short := feed("\x1b[<0;1M").(Invalid)
    testing.expect(t, short)

    _, long := feed("\x1b[<0;1;2;3M").(Invalid)
    testing.expect(t, long)

    // Cb is a byte; a wider value is not a control byte we can decode.
    _, wide := feed("\x1b[<300;1;2M").(Invalid)
    testing.expect(t, wide)
}

@(test)
test_kitty_plain_codepoint :: proc(t: ^testing.T) {
    k := expect_key(t, feed("\x1b[97u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, k.mods == {})
    testing.expect_value(t, k.event, Key_Event.Press)

    // No text group: nothing is invented for a terminal that does not report text.
    expect_text(t, k, "")
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
    // The navigation and function keys keep their legacy encodings under Kitty; the PUA
    // block is not where they live. 57352/57364 are Kitty's *internal* key numbers and
    // never reach the wire, so they must not be mistaken for Up/F1.
    expect_key(t, feed("\x1b[A"), .Up)
    expect_key(t, feed("\x1b[H"), .Home)
    expect_key(t, feed("\x1b[1P"), .F1)
    expect_key(t, feed("\x1b[24~"), .F12)
    expect_key(t, feed("\x1b[13u"), .Enter)
    expect_key(t, feed("\x1b[27u"), .Esc)
    expect_key(t, feed("\x1b[127u"), .Backspace)

    // The one PUA block that does name keys: the keypad twins, folded back onto the
    // main-cluster names, plus Menu.
    expect_key(t, feed("\x1b[57414u"), .Enter)
    expect_key(t, feed("\x1b[57419u"), .Up)
    expect_key(t, feed("\x1b[57423u"), .Home)
    expect_key(t, feed("\x1b[57426u"), .Delete)
    expect_key(t, feed("\x1b[57363u"), .Menu)
}

@(test)
test_legacy_home_end_numeric_forms :: proc(t: ^testing.T) {
    // xterm, rxvt and the Linux console send the numeric forms rather than `CSI H`/`CSI F`.
    expect_key(t, feed("\x1b[7~"), .Home)
    expect_key(t, feed("\x1b[8~"), .End)
    expect_key(t, feed("\x1b[29~"), .Menu)

    ctrl_end := expect_key(t, feed("\x1b[8;5~"), .End)
    testing.expect(t, ctrl_end.mods == {.Ctrl})
}

@(test)
test_ss3_cursor_key_mode_arrows :: proc(t: ^testing.T) {
    // A terminal left in cursor-key mode (DECCKM) by a previous program sends SS3 arrows.
    expect_key(t, feed("\x1bOA"), .Up)
    expect_key(t, feed("\x1bOB"), .Down)
    expect_key(t, feed("\x1bOC"), .Right)
    expect_key(t, feed("\x1bOD"), .Left)
    expect_key(t, feed("\x1bOP"), .F1)
    expect_key(t, feed("\x1bOH"), .Home)
}

@(test)
test_kitty_unnamed_functional_keys :: proc(t: ^testing.T) {
    // 57358 (Caps Lock), 57399 (keypad 0) and 57441 (left Shift) are unnamed functional
    // keys: they keep their codepoint but must never look like typed characters.
    caps := expect_key(t, feed("\x1b[57358u"), .Unknown)
    testing.expect_value(t, caps.char, rune(57358))
    expect_text(t, caps, "")

    expect_key(t, feed("\x1b[57399u"), .Unknown)
    expect_key(t, feed("\x1b[57441u"), .Unknown)

    // F13-F35 have no name here either, but they are still functional keys.
    expect_key(t, feed("\x1b[57376u"), .Unknown)
    expect_key(t, feed("\x1b[57398u"), .Unknown)

    // Past the last assignment but still inside the reserved block: a functional key this
    // package has never heard of, not a printable private-use character.
    expect_key(t, feed("\x1b[57455u"), .Unknown)
    expect_key(t, feed("\x1b[63743u"), .Unknown)

    // One past the reserved block is ordinary private-use text again.
    beyond := expect_key(t, feed("\x1b[63744u"), .Char)
    testing.expect_value(t, beyond.char, rune(63744))
}

@(test)
test_kitty_keypad_key_still_reports_its_text :: proc(t: ^testing.T) {
    // The keypad is unnamed, but its text still types "1".
    k := expect_key(t, feed("\x1b[57400;;49u"), .Unknown)
    expect_text(t, k, "1")
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
test_kitty_shift_keeps_unshifted_codepoint :: proc(t: ^testing.T) {
    // The key code is always the unshifted key; Shift is reported, never derived.
    k := expect_key(t, feed("\x1b[97;2u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Shift in k.mods)
}

@(test)
test_kitty_uppercase_codepoint_is_folded :: proc(t: ^testing.T) {
    // Kitty is specified to send the unshifted key, so codepoint 65 is out of spec. Fold
    // it anyway: `char` names a key, and the same key must not answer to two values
    // depending on which terminal sent it. No Shift is invented from the case.
    k := expect_key(t, feed("\x1b[65u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, .Shift not_in k.mods)
}

@(test)
test_kitty_alternate_keys :: proc(t: ^testing.T) {
    // Shift+a fully reported: unshifted key, both alternates, the modifier, the text.
    k := expect_key(t, feed("\x1b[97:65:97;2;65u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect_value(t, k.shifted, 'A')
    testing.expect_value(t, k.base_layout, 'a')
    testing.expect(t, .Shift in k.mods)
    expect_text(t, k, "A")
}

@(test)
test_kitty_base_layout_without_shifted :: proc(t: ^testing.T) {
    // An empty shifted sub-param still positions the base-layout key: on Dvorak the
    // 'q' position types apostrophe.
    k := expect_key(t, feed("\x1b[39::113;5u"), .Char)
    testing.expect_value(t, k.char, '\'')
    testing.expect_value(t, k.shifted, rune(0))
    testing.expect_value(t, k.base_layout, 'q')
    testing.expect(t, .Ctrl in k.mods)
}

@(test)
test_kitty_named_key_drops_alternates :: proc(t: ^testing.T) {
    // Enter has no shifted or base-layout form to speak of.
    k := expect_key(t, feed("\x1b[13:65;2u"), .Enter)
    testing.expect_value(t, k.char, rune(0))
    testing.expect_value(t, k.shifted, rune(0))
    testing.expect_value(t, k.base_layout, rune(0))
    testing.expect(t, .Shift in k.mods)
}

@(test)
test_kitty_text_group :: proc(t: ^testing.T) {
    // Unmodified press with the modifier group left empty.
    k := expect_key(t, feed("\x1b[97;;97u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, k.mods == {})
    expect_text(t, k, "a")

    // Multi-codepoint text: a dead key producing 'a' + U+0301, kept decomposed.
    composed := expect_key(t, feed("\x1b[97;;97:769u"), .Char)
    expect_text(t, composed, "a\u0301")
}

@(test)
test_kitty_caps_lock_is_reported_not_shift :: proc(t: ^testing.T) {
    // Caps Lock is modifier bit 64 (param 65): a lock, not Shift, though the resolved
    // character is identical either way.
    k := expect_key(t, feed("\x1b[97;65;65u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect(t, k.mods == {})
    testing.expect(t, .Caps in k.locks)
    testing.expect(t, .Num not_in k.locks)
    expect_text(t, k, "A")

    // Num Lock is bit 128 (param 129), and locks combine with real modifiers.
    both := expect_key(t, feed("\x1b[97;134u"), .Char)
    testing.expect(t, both.mods == {.Shift, .Ctrl})
    testing.expect(t, both.locks == {.Num})
}

@(test)
test_kitty_astral_codepoint_survives_params :: proc(t: ^testing.T) {
    // U+1F600 does not fit a 16-bit param; truncation would report U+F600 instead.
    k := expect_key(t, feed("\x1b[128512;;128512u"), .Char)
    testing.expect_value(t, k.char, rune(0x1F600))
    expect_text(t, k, "😀")
}

@(test)
test_kitty_text_rejects_control_codes :: proc(t: ^testing.T) {
    // The protocol forbids control codes in associated text.
    k := expect_key(t, feed("\x1b[97;;27:97:10u"), .Char)
    expect_text(t, k, "a")
}

@(test)
test_kitty_text_fills_the_derived_buffer :: proc(t: ^testing.T) {
    // Sized for the worst case: fourteen 4-byte codepoints must fit exactly.
    k := expect_key(
        t,
        feed(
            "\x1b[97;;128512:128512:128512:128512:128512:128512:128512:128512:128512:128512:128512:128512:128512:128512u",
        ),
        .Char,
    )
    testing.expect_value(t, int(k.text_len), MAX_KEY_TEXT_BYTES)

    // A fifteenth codepoint exceeds the param array and is dropped there.
    over := expect_key(t, feed("\x1b[97;;97:97:97:97:97:97:97:97:97:97:97:97:97:97:97u"), .Char)
    testing.expect_value(t, over.char, 'a')
    expect_text(t, over, "aaaaaaaaaaaaaa")
}

@(test)
test_kitty_rejects_impossible_codepoints :: proc(t: ^testing.T) {
    // Past the last Unicode scalar.
    _, over := feed("\x1b[1114112u").(Invalid)
    testing.expect(t, over)

    // A surrogate half is not a scalar.
    _, surrogate := feed("\x1b[55296u").(Invalid)
    testing.expect(t, surrogate)

    // An empty key group (`CSI ; 5 u`) leaves no key to report.
    _, empty := feed("\x1b[;5u").(Invalid)
    testing.expect(t, empty)
}

@(test)
test_csi_params_saturate_instead_of_wrapping :: proc(t: ^testing.T) {
    // 2^32 + 97 would fold back onto 'a' if the accumulator wrapped. It saturates, so the
    // field stays out of range and the sequence is rejected.
    _, folds_to_a := feed("\x1b[4294967393u").(Invalid)
    testing.expect(t, folds_to_a)

    // 2^32 + 48 would fold onto the in-band resize param and drive a real size re-query.
    _, folds_to_resize := feed("\x1b[4294967344t").(Invalid)
    testing.expect(t, folds_to_resize)

    // Digits past the saturation point cannot bring a field back into range.
    _, ridiculous := feed("\x1b[999999999999999999999u").(Invalid)
    testing.expect(t, ridiculous)

    // The largest scalar still parses: saturation must not clip a legitimate codepoint.
    k := expect_key(t, feed("\x1b[1114111u"), .Char)
    testing.expect_value(t, k.char, rune(0x10FFFF))
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

@(test)
test_kitty_text_only_event :: proc(t: ^testing.T) {
    // Key 0 is the protocol's "no key is identifiable with this text". The spec's own
    // example is Option+a on macOS, where the OS consumed the modifier.
    k := expect_key(t, feed("\x1b[0;;229u"), .Text)
    testing.expect_value(t, k.char, rune(0))
    testing.expect(t, k.mods == {})
    expect_text(t, k, "å")

    // Multi-codepoint text keeps every codepoint, in order.
    multi := expect_key(t, feed("\x1b[0;;229:230:231u"), .Text)
    expect_text(t, multi, "åæç")

    // A text event with no text identifies nothing and is not a keystroke.
    _, no_text := feed("\x1b[0;;u").(Invalid)
    testing.expect(t, no_text)
    _, bare := feed("\x1b[0u").(Invalid)
    testing.expect(t, bare)

    // Key 0 has no key, so it never carries alternates even when the group is present.
    alternates := expect_key(t, feed("\x1b[0::98;;229u"), .Text)
    testing.expect_value(t, alternates.shifted, rune(0))
    testing.expect_value(t, alternates.base_layout, rune(0))
}

@(test)
test_kitty_text_event_is_distinct_from_an_unnamed_key :: proc(t: ^testing.T) {
    // Both were `.Unknown` once, and only `char` told them apart. An unnamed functional
    // key can carry text too, so "has text" never discriminated them either.
    text_only := expect_key(t, feed("\x1b[0;;229u"), .Text)
    testing.expect_value(t, text_only.char, rune(0))

    keypad := expect_key(t, feed("\x1b[57400;;49u"), .Unknown)
    testing.expect_value(t, keypad.char, rune(57400))
    expect_text(t, keypad, "1")
}

@(test)
test_kitty_rejects_unnamed_control_codes_as_keys :: proc(t: ^testing.T) {
    // A control code names a key only where the protocol says so (9, 13, 27, 8, 127).
    // Anything else is neither a key nor text — notably an echo of our own `CSI > 31 u`.
    _, unit_separator := feed("\x1b[31u").(Invalid)
    testing.expect(t, unit_separator)
    _, echoed_push := feed("\x1b[>31u").(Invalid)
    testing.expect(t, echoed_push)
    _, c1 := feed("\x1b[155u").(Invalid)
    testing.expect(t, c1)
}

@(test)
test_kitty_empty_sub_params :: proc(t: ^testing.T) {
    // Consecutive separators mean "absent", not zero: an empty shifted field must not
    // shift the base-layout field out of position.
    k := expect_key(t, feed("\x1b[97::65;;u"), .Char)
    testing.expect_value(t, k.char, 'a')
    testing.expect_value(t, k.shifted, rune(0))
    testing.expect_value(t, k.base_layout, 'A')
    testing.expect(t, k.mods == {})
    testing.expect(t, k.locks == {})
    expect_text(t, k, "")
}

@(test)
test_kitty_modified_key_reports_the_text_it_was_sent :: proc(t: ^testing.T) {
    // Ctrl+c: the terminal decides whether a modified key produced text. Kitty sends none,
    // and the parser does not invent any.
    ctrl := expect_key(t, feed("\x1b[99;5u"), .Char)
    testing.expect_value(t, ctrl.char, 'c')
    testing.expect(t, ctrl.mods == {.Ctrl})
    expect_text(t, ctrl, "")

    // If a terminal does report text alongside a modifier, it is passed through rather
    // than second-guessed — `mods` is what shortcuts match on.
    reported := expect_key(t, feed("\x1b[99;5;99u"), .Char)
    testing.expect(t, reported.mods == {.Ctrl})
    expect_text(t, reported, "c")
}

@(test)
test_kitty_release_carries_its_text :: proc(t: ^testing.T) {
    // Text is reported per event, not per press; a release that carries text keeps it, so
    // a caller that ignores releases must check `event` rather than `text`.
    k := expect_key(t, feed("\x1b[97;1:3;97u"), .Char)
    testing.expect_value(t, k.event, Key_Event.Release)
    expect_text(t, k, "a")
}

@(test)
test_legacy_tilde_carries_modifiers_and_event_type :: proc(t: ^testing.T) {
    ctrl := expect_key(t, feed("\x1b[3;5~"), .Delete)
    testing.expect(t, ctrl.mods == {.Ctrl})
    testing.expect_value(t, ctrl.event, Key_Event.Press)

    release := expect_key(t, feed("\x1b[3;5:3~"), .Delete)
    testing.expect(t, release.mods == {.Ctrl})
    testing.expect_value(t, release.event, Key_Event.Release)

    // A named key never carries text, however it was encoded.
    expect_text(t, ctrl, "")
    expect_text(t, release, "")
}

@(test)
test_key_text_append_stops_at_the_buffer :: proc(t: ^testing.T) {
    // The parser cannot reach this branch: group 2 tops out at `MAX_KEY_TEXT_RUNES`
    // sub-params, which is exactly the buffer. Exercise the bound directly.
    full: Key
    for _ in 0 ..< MAX_KEY_TEXT_RUNES {
        key_text_append(&full, '\U0010FFFF')
    }

    testing.expect_value(t, int(full.text_len), MAX_KEY_TEXT_BYTES)

    key_text_append(&full, 'a')
    testing.expect_value(t, int(full.text_len), MAX_KEY_TEXT_BYTES)

    // A rune that does not fit is dropped whole, never truncated into invalid UTF-8.
    partial: Key
    for _ in 0 ..< MAX_KEY_TEXT_RUNES - 1 {
        key_text_append(&partial, '\U0010FFFF')
    }

    key_text_append(&partial, 'a')
    testing.expect_value(t, int(partial.text_len), MAX_KEY_TEXT_BYTES - 3)

    key_text_append(&partial, '\U0010FFFF')
    testing.expect_value(t, int(partial.text_len), MAX_KEY_TEXT_BYTES - 3)
}

// Assert `k` matches `cp` + `mods`, and that it does not.
expect_match :: proc(t: ^testing.T, k: Key, cp: rune, mods: Modifiers = {}, loc := #caller_location) {
    k := k
    testing.expect(t, key_matches(&k, cp, mods), "expected a match", loc = loc)
}

expect_no_match :: proc(t: ^testing.T, k: Key, cp: rune, mods: Modifiers = {}, loc := #caller_location) {
    k := k
    testing.expect(t, !key_matches(&k, cp, mods), "expected no match", loc = loc)
}

@(test)
test_key_matches_the_same_keystroke_across_terminals :: proc(t: ^testing.T) {
    // Shift+semicolon types a colon. A legacy terminal resolves it to ':' with no
    // modifier; Kitty reports the ';' key under Shift with ':' as the alternate. Both
    // spellings must match either encoding, which no single field can do.
    legacy := expect_key(t, feed(":"), .Char)
    kitty := expect_key(t, feed("\x1b[59:58;2;58u"), .Char)

    expect_match(t, legacy, ':')
    expect_match(t, kitty, ':')

    // The unshifted spelling needs to know that `;` shifts to `:`, which is layout
    // knowledge only the terminal has. Kitty names the key, so it matches; the legacy
    // stream delivered a bare ':' and cannot.
    expect_match(t, kitty, ';', {.Shift})
    expect_no_match(t, legacy, ';', {.Shift})

    // Without text reporting the shifted alternate is the only channel left.
    no_text := expect_key(t, feed("\x1b[59:58;2u"), .Char)
    testing.expect_value(t, no_text.char, ';')
    expect_text(t, no_text, "")
    expect_match(t, no_text, ':')
}

@(test)
test_key_matches_uppercase_from_either_channel :: proc(t: ^testing.T) {
    // Legacy carries the case only in `text`; Kitty carries it in `mods` and `shifted`.
    legacy := expect_key(t, feed("A"), .Char)
    testing.expect(t, legacy.mods == {})

    kitty := expect_key(t, feed("\x1b[97:65;2;65u"), .Char)
    testing.expect(t, kitty.mods == {.Shift})

    for k in ([]Key{legacy, kitty}) {
        expect_match(t, k, 'A')
        expect_match(t, k, 'a', {.Shift})
    }

    // Alt suppresses the text, so `shifted` is what carries it on the legacy path.
    alt := expect_key(t, feed("\x1bA"), .Char)
    expect_match(t, alt, 'A', {.Alt})
    expect_no_match(t, alt, 'A')
}

@(test)
test_key_matches_keeps_real_modifiers_apart :: proc(t: ^testing.T) {
    ctrl_c := expect_key(t, feed("\x03"), .Char)
    expect_match(t, ctrl_c, 'c', {.Ctrl})
    expect_no_match(t, ctrl_c, 'c')
    expect_no_match(t, ctrl_c, 'c', {.Ctrl, .Alt})

    // Ctrl+Shift+C is not Ctrl+C, but it answers to the shifted spelling.
    ctrl_shift := expect_key(t, feed("\x1b[99:67;6u"), .Char)
    expect_no_match(t, ctrl_shift, 'c', {.Ctrl})
    expect_match(t, ctrl_shift, 'C', {.Ctrl})

    // A named key has no character to match, and 0 matches nothing.
    expect_no_match(t, expect_key(t, feed("\x1b[A"), .Up), 0)
    expect_no_match(t, expect_key(t, feed("\r"), .Enter), 0)
}

@(test)
test_key_matches_locks_do_not_block_a_match :: proc(t: ^testing.T) {
    // Caps Lock rides in `locks`, not `mods`, so it never has to be stripped.
    caps := expect_key(t, feed("\x1b[97;65;65u"), .Char)
    testing.expect(t, .Caps in caps.locks)
    expect_match(t, caps, 'A')
    expect_match(t, caps, 'a')

    // A text event answers for the text it carried.
    composed := expect_key(t, feed("\x1b[0;;229u"), .Text)
    expect_match(t, composed, 'å')
    expect_no_match(t, composed, 'a')
}
