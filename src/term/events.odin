package term

import "core:unicode/utf8"

// Modifier keys carried on a key event. `Shift`, `Alt`, `Ctrl` come from legacy
// and xterm sequences; `Super`, `Hyper`, `Meta` are Kitty-only and stay clear on
// legacy paths.
Modifier :: enum {
    Shift,
    Alt,
    Ctrl,
    Super,
    Hyper,
    Meta,
}

Modifiers :: bit_set[Modifier]

// Kitty reports press/repeat/release; legacy sequences are always `.Press`.
Key_Event :: enum {
    Press,
    Repeat,
    Release,
}

// Named key, or `.Char` when the event carries a literal codepoint in `Key.char`.
Key_Code :: enum {
    Char,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    Insert,
    Delete,
    Page_Up,
    Page_Down,
    Enter,
    Tab,
    Backspace,
    Esc,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
}

// A decoded key press. `char` is meaningful only when `code == .Char`.
Key :: struct {
    code:  Key_Code,
    char:  rune,
    mods:  Modifiers,
    event: Key_Event,
}

// X10 mouse action. `Move`/`Move_Rightclick` are drag reports; scroll wheel maps
// to `Scroll_Up`/`Scroll_Down`.
Mouse_Action :: enum {
    Left,
    Middle,
    Right,
    Release,
    Scroll_Up,
    Scroll_Down,
    Move,
    Move_Rightclick,
}

// A decoded mouse report. `x`/`y` are 0-based cell coordinates.
Mouse :: struct {
    action: Mouse_Action,
    x, y:   u16,
    shift:  bool,
    alt:    bool,
    ctrl:   bool,
}

// Zero-payload parser outcomes, kept as distinct types so they can be union arms.
Resize :: struct {}
Paste_Start :: struct {}
Paste_End :: struct {}
Invalid :: struct {}

// One completed parser outcome. A `nil` union value means "no event yet / need
// more bytes" (the reference's null); it is never used to signal `.none`.
Parse_Event :: union {
    Key,
    Mouse,
    Resize,
    Paste_Start,
    Paste_End,
    Invalid,
}

// Parser states of the VT/ANSI machine.
Parser_State :: enum {
    Ground,
    Escape,
    Csi,
    Ss3,
    Mouse,
    Utf8,
}

// Byte-at-a-time escape/CSI state machine. A single sequence's worth of state; a
// fresh `Parser{}` is walked per `parse` call.
Parser :: struct {
    state:            Parser_State,

    // CSI params: `;` separates groups, `:` marks a sub-param continuation of the
    // prior param's group (Kitty `key:… ; mods:event`). `subparam[i]` records that.
    params:           [16]u16,
    subparam:         [16]bool,
    param_count:      int,
    param_cur:        u16,
    param_digits:     bool,
    pending_subparam: bool, // param being accumulated followed a `:`
    private:          u8, // '<' '=' '>' '?' seen before params, else 0

    // UTF-8 assembly of a multi-byte lead sequence.
    utf8:             [4]u8,
    utf8_len:         int,
    utf8_need:        int,

    // X10 mouse: three payload bytes after `ESC [ M`.
    mouse:            [3]u8,
    mouse_len:        int,
}

// Feed one byte; a completed `Parse_Event`, or `nil` when more bytes are needed.
parser_step :: proc(p: ^Parser, b: u8) -> Parse_Event {
    switch p.state {
    case .Ground:
        return parser_ground(p, b)
    case .Escape:
        return parser_escape(p, b)
    case .Csi:
        return parser_csi(p, b)
    case .Ss3:
        return parser_finish_ss3(p, b)
    case .Mouse:
        return parser_step_mouse(p, b)
    case .Utf8:
        return parser_step_utf8(p, b)
    }

    return nil
}

// Reset to a fresh ground state.
parser_reset :: proc(p: ^Parser) {
    p^ = {}
}

// Ground state: C0 control, ESC, or a UTF-8 lead byte.
parser_ground :: proc(p: ^Parser, b: u8) -> Parse_Event {
    switch b {
    case 0x1b:
        p.state = .Escape
        return nil
    case 0x08, 0x7f:
        return make_key(.Backspace)
    case 0x09:
        return make_key(.Tab)
    case 0x0a, 0x0d:
        return make_key(.Enter)
    case 0x01 ..= 0x07, 0x0b ..= 0x0c, 0x0e ..= 0x1a:
        // Ctrl+A..Z (tab / enter / backspace peeled off above). No shift synthesis.
        return make_key_char(rune(b) + 'a' - 0x01, {.Ctrl})
    case:
        need, ok := utf8_seq_len(b)
        if !ok {
            return Invalid{}
        }

        if need == 1 {
            return emit_char(rune(b))
        }

        p.utf8[0] = b
        p.utf8_len = 1
        p.utf8_need = need
        p.state = .Utf8
        return nil
    }
}

// Accumulate UTF-8 continuation bytes, then emit the codepoint.
parser_step_utf8 :: proc(p: ^Parser, b: u8) -> Parse_Event {
    p.utf8[p.utf8_len] = b
    p.utf8_len += 1
    if p.utf8_len < p.utf8_need {
        return nil
    }

    cp, size := utf8.decode_rune(p.utf8[:p.utf8_len])
    if size != p.utf8_len {
        parser_reset(p)
        return Invalid{}
    }

    parser_reset(p)
    return emit_char(cp)
}

// After ESC: CSI (`[`), SS3 (`O`), or an Alt / Ctrl+Alt char.
parser_escape :: proc(p: ^Parser, b: u8) -> Parse_Event {
    switch b {
    case '[':
        p.state = .Csi
        return nil
    case 'O':
        p.state = .Ss3
        return nil
    case 0x01 ..= 0x0c, 0x0e ..= 0x1a:
        // ESC + ctrl char = Ctrl+Alt (raw byte + 0x60). No shift synthesis.
        parser_reset(p)
        return make_key_char(rune(b) + 0x60, {.Ctrl, .Alt})
    case:
        // ESC + char = Alt. The raw byte is kept verbatim: unlike the ground path,
        // uppercase ASCII is NOT rewritten to shift+lowercase. This asymmetry is
        // deliberate legacy mibu parity.
        parser_reset(p)
        return make_key_char(rune(b), {.Alt})
    }
}

// CSI body: private marker, params, intermediates, then the final byte.
parser_csi :: proc(p: ^Parser, b: u8) -> Parse_Event {
    switch b {
    case '0' ..= '9':
        // u16 params accumulate with wrapping; Odin unsigned arithmetic wraps by
        // default, so an overlong numeric field folds modulo 2^16 as in the reference.
        p.param_cur = p.param_cur * 10 + u16(b - '0')
        p.param_digits = true
        return nil
    case ';':
        parser_push_param(p)
        p.pending_subparam = false
        return nil
    case ':':
        parser_push_param(p)
        p.pending_subparam = true
        return nil
    case '<', '=', '>', '?':
        p.private = b
        return nil
    case 0x20 ..= 0x2f:
        return nil // intermediate byte: ignored (pragmatic)
    case 'M':
        // Bare `ESC [ M` (no params, no private) is X10 mouse; three bytes follow.
        // With params it is SGR mouse etc. — unsupported for now.
        if p.private == 0 && p.param_count == 0 && !p.param_digits {
            p.state = .Mouse
            p.mouse_len = 0
            return nil
        }

        parser_reset(p)
        return Invalid{}
    case 0x40 ..= 0x4c, 0x4e ..= 0x7e:
        if p.param_digits || p.param_count > 0 {
            parser_push_param(p)
        }

        ev := parser_dispatch_csi(p, b)
        parser_reset(p)
        return ev
    case:
        parser_reset(p)
        return Invalid{}
    }
}

// X10 mouse: three bias-32 bytes -> a Mouse event.
parser_step_mouse :: proc(p: ^Parser, b: u8) -> Parse_Event {
    p.mouse[p.mouse_len] = b
    p.mouse_len += 1
    if p.mouse_len < 3 {
        return nil
    }

    m := parse_mouse_action(p.mouse[0])
    m.x = sat_sub_32(p.mouse[1])
    m.y = sat_sub_32(p.mouse[2])
    parser_reset(p)
    return m
}

// SS3 final byte -> F1-F4 / home / end.
parser_finish_ss3 :: proc(p: ^Parser, b: u8) -> Parse_Event {
    parser_reset(p)
    switch b {
    case 'P':
        return make_key(.F1)
    case 'Q':
        return make_key(.F2)
    case 'R':
        return make_key(.F3)
    case 'S':
        return make_key(.F4)
    case 'H':
        return make_key(.Home)
    case 'F':
        return make_key(.End)
    case:
        return Invalid{}
    }
}

// Commit the current numeric param (default 0), reset the accumulator.
parser_push_param :: proc(p: ^Parser) {
    if p.param_count < len(p.params) {
        p.params[p.param_count] = p.param_cur if p.param_digits else 0
        p.subparam[p.param_count] = p.pending_subparam
        p.param_count += 1
    }

    p.param_cur = 0
    p.param_digits = false
}

// Value of sub-param `si` in `;`-group `gi` (0-based), or `ok == false` if absent.
parser_group_sub :: proc(p: ^Parser, gi, si: int) -> (u16, bool) {
    g := 0
    s := 0
    for i in 0 ..< p.param_count {
        if i != 0 {
            if p.subparam[i] {
                s += 1
            } else {
                g += 1
                s = 0
            }
        }

        if g == gi && s == si {
            return p.params[i], true
        }
    }

    return 0, false
}

// Map a completed CSI sequence (params + final byte) to a key/mouse/resize event.
parser_dispatch_csi :: proc(p: ^Parser, final: u8) -> Parse_Event {
    mods := mods_from_param(p.params[1]) if p.param_count >= 2 else {}
    switch final {
    case 'A':
        return make_key(.Up, mods)
    case 'B':
        return make_key(.Down, mods)
    case 'C':
        return make_key(.Right, mods)
    case 'D':
        return make_key(.Left, mods)
    case 'H':
        return make_key(.Home, mods)
    case 'F':
        return make_key(.End, mods)
    case 'Z':
        // Shift-tab forces Shift, ignoring any computed modifiers.
        return make_key(.Tab, {.Shift})
    case '~':
        n := p.params[0] if p.param_count >= 1 else 0
        if n == 200 {
            return Paste_Start{}
        }

        if n == 201 {
            return Paste_End{}
        }

        code, ok := tilde_code(n)
        if !ok {
            return Invalid{}
        }

        return make_key(code, mods)
    case 'u':
        return parser_dispatch_kitty(p)
    case 't':
        // In-band resize report `CSI 48 … t` (DEC mode 2048). The reported
        // dimensions are discarded; the caller re-queries via get_size.
        if p.param_count >= 1 && p.params[0] == 48 {
            return Resize{}
        }

        return Invalid{}
    case:
        return Invalid{}
    }
}

// Kitty `CSI key:… ; mods:event ; text u`.
parser_dispatch_kitty :: proc(p: ^Parser) -> Parse_Event {
    // A `?`-private payload is a Kitty query response, never a keystroke; guard it
    // so query replies can never be materialized as fake key events.
    if p.private == '?' {
        return Invalid{}
    }

    cp, ok := parser_group_sub(p, 0, 0)
    if !ok {
        return Invalid{}
    }

    code, char := kitty_key_code(rune(cp))
    mods := Modifiers{}
    if m, has := parser_group_sub(p, 1, 0); has {
        mods = mods_from_param(m)
    }

    kind := Key_Event.Press
    if k, has := parser_group_sub(p, 1, 1); has {
        switch k {
        case 2:
            kind = .Repeat
        case 3:
            kind = .Release
        case:
            kind = .Press
        }
    }

    return Key{code = code, char = char, mods = mods, event = kind}
}

// Key event, no modifiers.
make_key :: proc(code: Key_Code, mods: Modifiers = {}) -> Key {
    return Key{code = code, mods = mods}
}

// Literal-codepoint key event.
make_key_char :: proc(cp: rune, mods: Modifiers = {}) -> Key {
    return Key{code = .Char, char = cp, mods = mods}
}

// Uppercase ASCII is reported as Shift + lowercase (legacy mibu behavior). This
// synthesis is confined to the ground/UTF-8 path on purpose: the Alt path keeps
// its raw byte and Kitty `u` codepoints are kept verbatim.
emit_char :: proc(cp: rune) -> Key {
    if cp >= 'A' && cp <= 'Z' {
        return make_key_char(cp + 32, {.Shift})
    }

    return make_key_char(cp)
}

// xterm modifier encoding: 1 + bitmask. Kitty adds 8/16/32 (super/hyper/meta);
// 64/128 (caps/num-lock) are ignored.
mods_from_param :: proc(v: u16) -> Modifiers {
    m := v - 1 if v > 0 else 0
    mods: Modifiers
    if m & 1 != 0 {
        mods += {.Shift}
    }

    if m & 2 != 0 {
        mods += {.Alt}
    }

    if m & 4 != 0 {
        mods += {.Ctrl}
    }

    if m & 8 != 0 {
        mods += {.Super}
    }

    if m & 16 != 0 {
        mods += {.Hyper}
    }

    if m & 32 != 0 {
        mods += {.Meta}
    }

    return mods
}

// Kitty `CSI codepoint u` -> key code. C0-legacy keys keep their ASCII codes;
// functional keys live in the Unicode PUA; anything else is a literal codepoint.
kitty_key_code :: proc(cp: rune) -> (code: Key_Code, char: rune) {
    switch cp {
    case 13:
        return .Enter, 0
    case 9:
        return .Tab, 0
    case 27:
        return .Esc, 0
    case 8, 127:
        return .Backspace, 0
    }

    if fk, is_fk := functional_key(cp); is_fk {
        return fk, 0
    }

    return .Char, cp
}

// Kitty functional-key codepoints (PUA 57344+). The gaps (57358..57363 and
// 57376+) are intentional: those codepoints have no mapping in the reference.
functional_key :: proc(cp: rune) -> (Key_Code, bool) {
    switch cp {
    case 57344:
        return .Esc, true
    case 57345:
        return .Enter, true
    case 57346:
        return .Tab, true
    case 57347:
        return .Backspace, true
    case 57348:
        return .Insert, true
    case 57349:
        return .Delete, true
    case 57350:
        return .Left, true
    case 57351:
        return .Right, true
    case 57352:
        return .Up, true
    case 57353:
        return .Down, true
    case 57354:
        return .Page_Up, true
    case 57355:
        return .Page_Down, true
    case 57356:
        return .Home, true
    case 57357:
        return .End, true
    case 57364:
        return .F1, true
    case 57365:
        return .F2, true
    case 57366:
        return .F3, true
    case 57367:
        return .F4, true
    case 57368:
        return .F5, true
    case 57369:
        return .F6, true
    case 57370:
        return .F7, true
    case 57371:
        return .F8, true
    case 57372:
        return .F9, true
    case 57373:
        return .F10, true
    case 57374:
        return .F11, true
    case 57375:
        return .F12, true
    case:
        return .Char, false
    }
}

// First param of a `~`-terminated CSI -> named key. Codes 16 and 22 are
// deliberate gaps (they fall through to invalid), matching the reference.
tilde_code :: proc(n: u16) -> (Key_Code, bool) {
    switch n {
    case 1:
        return .Home, true
    case 2:
        return .Insert, true
    case 3:
        return .Delete, true
    case 4:
        return .End, true
    case 5:
        return .Page_Up, true
    case 6:
        return .Page_Down, true
    case 11:
        return .F1, true
    case 12:
        return .F2, true
    case 13:
        return .F3, true
    case 14:
        return .F4, true
    case 15:
        return .F5, true
    case 17:
        return .F6, true
    case 18:
        return .F7, true
    case 19:
        return .F8, true
    case 20:
        return .F9, true
    case 21:
        return .F10, true
    case 23:
        return .F11, true
    case 24:
        return .F12, true
    case:
        return .Char, false
    }
}

// UTF-8 sequence length from a lead byte; `ok == false` for an invalid lead byte
// (continuation byte or an out-of-range prefix).
utf8_seq_len :: proc(b: u8) -> (int, bool) {
    switch {
    case b < 0x80:
        return 1, true
    case b & 0xe0 == 0xc0:
        return 2, true
    case b & 0xf0 == 0xe0:
        return 3, true
    case b & 0xf8 == 0xf0:
        return 4, true
    case:
        return 0, false
    }
}

// Saturating `byte - 32` widened to u16 (X10 mouse coordinates are bias-32).
sat_sub_32 :: proc(b: u8) -> u16 {
    return u16(b) - 32 if b >= 32 else 0
}

// Decode an X10 mouse control byte into a Mouse (modifiers + action).
parse_mouse_action :: proc(cb: u8) -> Mouse {
    m: Mouse

    // Diverges from the mibu reference, whose shift mask duplicates meta (both 8);
    // these are the xterm-documented bits: shift=4, meta/alt=8, ctrl=16.
    m.shift = cb & 4 != 0
    m.alt = cb & 8 != 0
    m.ctrl = cb & 16 != 0

    // Bit 6 marks scroll-wheel and drag reports; low two bits pick within the set.
    if cb & 64 != 0 {
        switch cb & 3 {
        case 0:
            m.action = .Scroll_Up
        case 1:
            m.action = .Scroll_Down
        case 2:
            m.action = .Move_Rightclick
        case:
            m.action = .Move
        }

        return m
    }

    switch cb & 3 {
    case 0:
        m.action = .Left
    case 1:
        m.action = .Middle
    case 2:
        m.action = .Right
    case:
        m.action = .Release
    }

    return m
}

// Parse one event from the front of `bytes` by walking a fresh parser. On success
// `incomplete` is false and `consumed` counts the bytes making up `event`; when
// `incomplete` is true `bytes` is a prefix of a longer sequence (feed more, then
// re-parse). A lone/trailing ESC is incomplete — resolve it with `flush`.
parse :: proc(bytes: []u8) -> (event: Parse_Event, consumed: int, incomplete: bool) {
    p: Parser
    for b, i in bytes {
        ev := parser_step(&p, b)
        if ev != nil {
            return ev, i + 1, false
        }
    }

    return nil, 0, true
}

// Resolve a buffer that will get no more bytes (ESC-timeout / EOF): a lone ESC
// becomes the Escape key, empty input becomes `nil` (none), and any other
// unterminated partial becomes `Invalid`.
flush :: proc(bytes: []u8) -> Parse_Event {
    if len(bytes) == 0 {
        return nil
    }

    if len(bytes) == 1 && bytes[0] == 0x1b {
        return make_key(.Esc)
    }

    event, _, incomplete := parse(bytes)
    if incomplete {
        return Invalid{}
    }

    return event
}
