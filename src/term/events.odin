package term

import "core:unicode"
import "core:unicode/utf8"

// Params one CSI sequence can carry across all `;` groups and `:` sub-params.
MAX_CSI_PARAMS :: 16

// Text codepoints one key event can carry: the param array less the key and modifier
// groups, which always precede a text group.
MAX_KEY_TEXT_RUNES :: MAX_CSI_PARAMS - 2

// Sized for the longest text the param array can deliver.
MAX_KEY_TEXT_BYTES :: MAX_KEY_TEXT_RUNES * utf8.UTF_MAX
#assert(MAX_KEY_TEXT_BYTES <= int(max(u8)))

// The Private Use Area block Kitty reserves for functional keys. Assignments currently
// stop at ISO_Level5_Shift (57454), but the whole block is spoken for, so an unrecognized
// codepoint inside it is a functional key this package has no name for, never text.
FUNCTIONAL_KEY_MIN :: rune(57344)
FUNCTIONAL_KEY_MAX :: rune(63743)

// Largest value any param can carry: a Unicode scalar. Accumulation sticks here instead
// of wrapping, so an overlong field stays out of range rather than folding onto a valid
// codepoint, mode number, or modifier mask.
PARAM_MAX :: u32(utf8.MAX_RUNE)

// Modifiers held, as the terminal reported them; never inferred from the character an
// event produced. `Super`, `Hyper`, `Meta` are Kitty-only.
Modifier :: enum {
    Shift,
    Alt,
    Ctrl,
    Super,
    Hyper,
    Meta,
}

Modifiers :: bit_set[Modifier]

// Lock states (Kitty only). Kept out of `Modifiers` so `mods == {.Ctrl}` still matches
// with Num Lock on.
Lock :: enum {
    Caps,
    Num,
}

Locks :: bit_set[Lock]

// Kitty reports press/repeat/release; legacy sequences are always `.Press`.
Key_Event :: enum {
    Press,
    Repeat,
    Release,
}

// Named key, `.Char` for a literal codepoint, `.Unknown` for an unnamed functional key
// (codepoint in `Key.char`), or `.Text` for a Kitty text-only event with no key at all.
Key_Code :: enum {
    Char,
    Unknown,
    Text,
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
    Menu,
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

// A decoded key event. `code`/`char` say which key; `text` says what it produced.
Key :: struct {
    code:        Key_Code,

    // The key itself, case-folded so the same physical key reports the same value on
    // every terminal. 0 for a named key and for a text-only event.
    char:        rune,

    // Alternates, 0 when unreported. `shifted` is the resolved character when it differs
    // from the key, not a Shift signal — Caps Lock produces it too on the legacy path.
    shifted:     rune,
    base_layout: rune,

    // UTF-8 of the text produced, never a control code. Empty for a named or Alt-modified
    // key; a terminal that reports text alongside a modifier is taken at its word.
    text:        [MAX_KEY_TEXT_BYTES]u8,
    text_len:    u8,
    mods:        Modifiers,
    locks:       Locks,
    event:       Key_Event,
}

// The text `k` produced. Borrows `k`.
key_text :: proc(k: ^Key) -> string {
    assert(int(k.text_len) <= len(k.text), "key text length exceeds its buffer")

    return string(k.text[:k.text_len])
}

// Append `cp` to `k`'s text. A control code is not text; text past the buffer is dropped
// rather than costing the keystroke.
key_text_append :: proc(k: ^Key, cp: rune) {
    assert(int(k.text_len) <= len(k.text), "key text length exceeds its buffer")

    if !is_text_rune(cp) {
        return
    }

    encoded, n := utf8.encode_rune(cp)
    if n > len(k.text) - int(k.text_len) {
        return
    }

    copy(k.text[k.text_len:], encoded[:n])
    k.text_len += u8(n)
}

// Whether `k` is the keystroke `cp` held with `mods`. The key, the text it produced, and
// the shifted alternate are all tried, since which one a terminal fills in varies; Shift
// need not agree, having been spent producing `cp`. Spelling a punctuation key unshifted
// (`Shift+;` for `:`) needs the alternate, which a legacy terminal does not report.
key_matches :: proc(k: ^Key, cp: rune, mods: Modifiers = {}) -> bool {
    assert(int(k.text_len) <= len(k.text), "key text length exceeds its buffer")

    // A named key has no character, and `shifted` is 0 when unreported.
    if cp == 0 {
        return false
    }

    if k.char == cp && k.mods == mods {
        return true
    }

    rest := k.mods - {.Shift} == mods - {.Shift}
    if rest && k.text_len != 0 {
        want := ascii_upper(cp) if .Shift in mods else cp
        encoded, n := utf8.encode_rune(want)
        if key_text(k) == string(encoded[:n]) {
            return true
        }
    }

    return rest && k.shifted == cp
}

// Whether `cp` can stand for a character: as text, a key, or an alternate. A control code
// names a key, never a character; `utf8.valid_rune` rejects surrogates and codepoints
// past `MAX_RUNE`.
is_text_rune :: proc(cp: rune) -> bool {
    return !unicode.is_control(cp) && utf8.valid_rune(cp)
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
// more bytes"; it is never used to signal that nothing happened.
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

    // CSI params: `;` separates groups, `:` marks a sub-param continuation of the prior
    // param's group (Kitty `key:… ; mods:event`); `subparam[i]` records that. 32-bit
    // because a Kitty key or text codepoint is a full Unicode scalar.
    params:           [MAX_CSI_PARAMS]u32,
    subparam:         [MAX_CSI_PARAMS]bool,
    param_count:      int,
    param_cur:        u32,
    param_digits:     bool,
    pending_subparam: bool, // param being accumulated followed a `:`
    private:          u8, // '<' '=' '>' '?' seen before params, else 0

    // UTF-8 assembly of a multi-byte lead sequence. `utf8_alt` marks an ESC-prefixed lead.
    utf8:             [4]u8,
    utf8_len:         int,
    utf8_need:        int,
    utf8_alt:         bool,

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
    case 0x00:
        // Ctrl+Space / Ctrl+@. Reported as the space key so it matches the `CSI 32;5u` a
        // Kitty terminal sends; left as-is it would be a `.Char` with no codepoint.
        return Key{code = .Char, char = ' ', mods = {.Ctrl}}
    case 0x08, 0x7f:
        return Key{code = .Backspace}
    case 0x09:
        return Key{code = .Tab}
    case 0x0a, 0x0d:
        return Key{code = .Enter}
    case 0x1c ..= 0x1f:
        // Ctrl+\ ] ^ _ — the C0 codes above the letter range, recovered as byte + 0x40 to
        // match the `CSI 92;5u` … `CSI 95;5u` a Kitty terminal sends.
        return Key{code = .Char, char = rune(b) + 0x40, mods = {.Ctrl}}
    case 0x01 ..= 0x07, 0x0b ..= 0x0c, 0x0e ..= 0x1a:
        // Ctrl+A..Z (tab / enter / backspace peeled off above), the legacy Ctrl
        // encoding. A control code is never text.
        return Key{code = .Char, char = rune(b) + 'a' - 0x01, mods = {.Ctrl}}
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
    assert(p.utf8_len < len(p.utf8), "utf8 assembly ran past its buffer")
    assert(p.utf8_need > 1 && p.utf8_need <= len(p.utf8), "utf8 sequence length out of range")

    p.utf8[p.utf8_len] = b
    p.utf8_len += 1
    if p.utf8_len < p.utf8_need {
        return nil
    }

    cp, size := utf8.decode_rune(p.utf8[:p.utf8_len])
    alt, need := p.utf8_alt, p.utf8_len
    parser_reset(p)
    if size != need {
        return Invalid{}
    }

    return emit_alt_char(cp) if alt else emit_char(cp)
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
        // ESC + ctrl char = Ctrl+Alt (raw byte + 0x60).
        parser_reset(p)
        return Key{code = .Char, char = rune(b) + 0x60, mods = {.Ctrl, .Alt}}
    case:
        // ESC + char = Alt. A lead byte enters the ground path's UTF-8 assembly so a
        // non-ASCII Alt key is not cut off after one byte.
        need, ok := utf8_seq_len(b)
        if !ok {
            parser_reset(p)
            return Invalid{}
        }

        if need == 1 {
            parser_reset(p)
            return emit_alt_char(rune(b))
        }

        p.utf8[0] = b
        p.utf8_len = 1
        p.utf8_need = need
        p.utf8_alt = true
        p.state = .Utf8

        return nil
    }
}

// CSI body: private marker, params, intermediates, then the final byte.
parser_csi :: proc(p: ^Parser, b: u8) -> Parse_Event {
    switch b {
    case '0' ..= '9':
        // Saturate rather than wrap: once a field passes `PARAM_MAX` it stops
        // accumulating and stays out of range, so no length of digits can land it back on
        // a meaningful value.
        if p.param_cur <= PARAM_MAX {
            p.param_cur = p.param_cur * 10 + u32(b - '0')
        }

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
        return nil // intermediate byte: ignored
    case 'M':
        // Bare `ESC [ M` (no params, no private) is X10 mouse; three bytes follow.
        // With params it is SGR mouse etc., which this parser does not decode.
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

// SS3 final byte -> arrows / F1-F4 / home / end. Emitted in cursor-key mode (DECCKM) and
// only without modifiers, so there is no envelope to read. Nothing here resets DECCKM, so
// the arrows matter: a terminal left in cursor-key mode by a previous program sends them.
parser_finish_ss3 :: proc(p: ^Parser, b: u8) -> Parse_Event {
    parser_reset(p)
    switch b {
    case 'A':
        return Key{code = .Up}
    case 'B':
        return Key{code = .Down}
    case 'C':
        return Key{code = .Right}
    case 'D':
        return Key{code = .Left}
    case 'P':
        return Key{code = .F1}
    case 'Q':
        return Key{code = .F2}
    case 'R':
        return Key{code = .F3}
    case 'S':
        return Key{code = .F4}
    case 'H':
        return Key{code = .Home}
    case 'F':
        return Key{code = .End}
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
parser_group_sub :: proc(p: ^Parser, gi, si: int) -> (u32, bool) {
    assert(gi >= 0 && si >= 0, "group and sub-param indices are 0-based")

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
    // Kitty's own form shares the modifier group but assembles a different key.
    if final == 'u' {
        return parser_dispatch_kitty(p)
    }

    key := parser_key_envelope(p)

    switch final {
    case 'A':
        key.code = .Up
    case 'B':
        key.code = .Down
    case 'C':
        key.code = .Right
    case 'D':
        key.code = .Left
    case 'H':
        key.code = .Home
    case 'F':
        key.code = .End
    case 'P':
        key.code = .F1
    case 'Q':
        key.code = .F2
    case 'R':
        key.code = .F3
    case 'S':
        key.code = .F4
    case 'Z':
        // Shift-tab forces Shift, ignoring any computed modifiers.
        key.code = .Tab
        key.mods = {.Shift}
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

        key.code = code
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

    return key
}

// Kitty `CSI key:shifted:base-layout ; mods:event ; text u`. Every group past the key is
// optional, and each is taken only as reported.
parser_dispatch_kitty :: proc(p: ^Parser) -> Parse_Event {
    // A `?`-private payload is a Kitty query reply, never a keystroke.
    if p.private == '?' {
        return Invalid{}
    }

    raw, ok := parser_group_sub(p, 0, 0)
    if !ok {
        return Invalid{}
    }

    key := parser_key_envelope(p)

    if raw == 0 {
        // Key 0 is the protocol's "no key is identifiable with this text" — a dead key or
        // an OS-composed character. It carries text and nothing else.
        key.code = .Text
    } else {
        code, char, valid := kitty_key_code(rune(raw))
        if !valid {
            return Invalid{}
        }

        key.code, key.char = code, char

        // Alternates describe a character key; a named key has none.
        if key.code == .Char {
            key.shifted = kitty_alternate(p, 1)
            key.base_layout = kitty_alternate(p, 2)
        }
    }

    // Third group: the produced text, one decimal codepoint per sub-param.
    for si in 0 ..< MAX_CSI_PARAMS {
        t, has := parser_group_sub(p, 2, si)
        if !has {
            break
        }

        key_text_append(&key, rune(t))
    }

    // Nothing identifies a text event but its text, so an empty one reports no keystroke.
    // An omitted key group (`CSI ; 5 u`) lands here too.
    if key.code == .Text && key.text_len == 0 {
        return Invalid{}
    }

    assert(key.code != .Text || key.char == 0, "a text event identifies no key")
    assert(
        key.code != .Unknown || (key.char >= FUNCTIONAL_KEY_MIN && key.char <= FUNCTIONAL_KEY_MAX),
        "an unnamed key keeps its functional-key codepoint",
    )

    return key
}

// The `mods:event-type` group both CSI forms share. Read by group, since sub-params of
// the key group shift the positions.
parser_key_envelope :: proc(p: ^Parser) -> Key {
    key: Key
    if m, has := parser_group_sub(p, 1, 0); has {
        key.mods, key.locks = mods_from_param(m)
    }

    key.event = parser_event_type(p)

    return key
}

// Sub-param 1 of the modifier group; absent or unrecognized is a press.
parser_event_type :: proc(p: ^Parser) -> Key_Event {
    v, has := parser_group_sub(p, 1, 1)
    if !has {
        return .Press
    }

    switch v {
    case 2:
        return .Repeat
    case 3:
        return .Release
    case:
        return .Press
    }
}

// Sub-param `si` of the key group, or 0 when absent, empty, or not a usable codepoint.
kitty_alternate :: proc(p: ^Parser, si: int) -> rune {
    assert(si > 0, "sub-param 0 of the key group is the key itself")

    v, ok := parser_group_sub(p, 0, si)
    if !ok {
        return 0
    }

    cp := rune(v)
    if !is_text_rune(cp) {
        return 0
    }

    return cp
}

// A literal codepoint from the legacy byte stream: the terminal already resolved the
// character, so that is the text. `char` case-folds it to match what Kitty would report
// for the same key. No modifier is inferred — Shift and Caps Lock produce the same byte.
emit_char :: proc(cp: rune) -> Key {
    key := Key {
        code = .Char,
        char = ascii_lower(cp),
    }
    key_text_append(&key, cp)

    return key
}

// The same key under Alt, which produces no text. The resolved character survives in
// `shifted` when the fold changed it — the only record the legacy stream keeps of it.
emit_alt_char :: proc(cp: rune) -> Key {
    key := Key {
        code = .Char,
        char = ascii_lower(cp),
        mods = {.Alt},
    }
    if key.char != cp {
        key.shifted = cp
    }

    return key
}

// Case-fold a key's codepoint. ASCII only: it is the one case mapping that holds under
// every keyboard layout.
ascii_lower :: proc(cp: rune) -> rune {
    return cp + 'a' - 'A' if cp >= 'A' && cp <= 'Z' else cp
}

// Inverse of `ascii_lower`, for resolving a Shift-modified match against reported text.
ascii_upper :: proc(cp: rune) -> rune {
    return cp - 'a' + 'A' if cp >= 'a' && cp <= 'z' else cp
}

// xterm modifier encoding: 1 + bitmask. Kitty adds 8/16/32 (super/hyper/meta) and the
// locks 64/128.
mods_from_param :: proc(v: u32) -> (Modifiers, Locks) {
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

    locks: Locks
    if m & 64 != 0 {
        locks += {.Caps}
    }

    if m & 128 != 0 {
        locks += {.Num}
    }

    return mods, locks
}

// Kitty `CSI codepoint u` -> key code. `ok` is false when the codepoint names no key at
// all. Legacy keys keep their ASCII codes; functional keys live in the reserved PUA
// block; anything else is a literal character.
kitty_key_code :: proc(cp: rune) -> (code: Key_Code, char: rune, ok: bool) {
    switch cp {
    case 13:
        return .Enter, 0, true
    case 9:
        return .Tab, 0, true
    case 27:
        return .Esc, 0, true
    case 8, 127:
        return .Backspace, 0, true
    }

    if cp >= FUNCTIONAL_KEY_MIN && cp <= FUNCTIONAL_KEY_MAX {
        if fk, named := functional_key(cp); named {
            return fk, 0, true
        }

        // A functional key with no name here keeps its codepoint, so a caller can still
        // tell one from another; it is never `.Char`.
        return .Unknown, cp, true
    }

    // Every other control code is a key we cannot name, not a character.
    if !is_text_rune(cp) {
        return {}, 0, false
    }

    // Kitty is specified to send the unshifted key, but folding here costs nothing and
    // keeps `char` case-independent even from a terminal that sends the shifted one.
    return .Char, ascii_lower(cp), true
}

// Reserved-PUA keys this package names: the keypad twins (unfolded by the disambiguate
// flag) plus Menu, folded onto the same codes as their legacy-encoded primary-cluster
// counterparts. Everything else in the PUA block reaches the caller as `.Unknown`.
functional_key :: proc(cp: rune) -> (Key_Code, bool) {
    switch cp {
    case 57363:
        return .Menu, true
    case 57414:
        return .Enter, true
    case 57417:
        return .Left, true
    case 57418:
        return .Right, true
    case 57419:
        return .Up, true
    case 57420:
        return .Down, true
    case 57421:
        return .Page_Up, true
    case 57422:
        return .Page_Down, true
    case 57423:
        return .Home, true
    case 57424:
        return .End, true
    case 57425:
        return .Insert, true
    case 57426:
        return .Delete, true
    case:
        return .Char, false
    }
}

// First param of a `~`-terminated CSI -> named key. Home and End have two encodings each
// (`CSI H`/`CSI 7~`, `CSI F`/`CSI 8~`): Kitty sends the letter forms, xterm/rxvt/Linux
// console the numeric ones. Codes 16 and 22 are unassigned and fall through to invalid.
tilde_code :: proc(n: u32) -> (Key_Code, bool) {
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
    case 7:
        return .Home, true
    case 8:
        return .End, true
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
    case 29:
        return .Menu, true
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

    // The xterm-documented modifier bits: shift=4, meta/alt=8, ctrl=16.
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

// Parse one event from the front of `bytes` by walking a fresh parser. `incomplete` false
// means `consumed` counts `event`'s bytes; `incomplete` true means `bytes` is a prefix of
// a longer sequence — feed more and re-parse. A lone/trailing ESC resolves via `flush`.
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
        return Key{code = .Esc}
    }

    event, _, incomplete := parse(bytes)
    if incomplete {
        return Invalid{}
    }

    return event
}
