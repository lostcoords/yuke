//! Terminal bytes to [`Event`]s, a port of the libvaxis parser. It reads legacy keys, the kitty keyboard protocol,
//! xterm modifyOtherKeys, SGR mouse reports, bracketed paste, focus, and the probe answers.

use crate::event::{Button, Code, Event, Key, Modifiers, Mouse, MouseKind, Rgb};

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
const PASTE_END: &[u8] = b"\x1b[201~";

/// Turns the bytes of the terminal into events. A sequence that a read cuts waits for the next read.
#[derive(Debug, Default)]
pub(crate) struct Parser {
    pending: Vec<u8>,
    /// The bytes of the open bracketed paste.
    paste: Option<Vec<u8>>,
}

impl Parser {
    /// A parser with no kept bytes.
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Read the events and answers in the kept bytes and `bytes`. A lone escape byte at the end is the escape key.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Vec<Parsed> {
        self.pending.extend_from_slice(bytes);
        let mut events = Vec::new();
        let mut at = 0;
        while at < self.pending.len() {
            let rest = &self.pending[at..];
            if let Some(paste) = &mut self.paste {
                // Only the end marker ends a paste, so the pasted bytes never read as keys.
                if let Some(end) = find(rest, PASTE_END) {
                    paste.extend_from_slice(&rest[..end]);
                    at += end + PASTE_END.len();
                    events.push(Parsed::Event(Event::Paste(clean_paste(paste))));
                    self.paste = None;
                    continue;
                }
                // The last bytes can be the start of the end marker.
                let take = rest.len() - rest.len().min(PASTE_END.len() - 1);
                paste.extend_from_slice(&rest[..take]);
                at += take;
                break;
            }
            match parse(rest) {
                Step::Incomplete => break,
                Step::Skip(n) => at += n,
                Step::Event(event, n) => {
                    events.push(Parsed::Event(event));
                    at += n;
                }
                Step::Answer(answer, n) => {
                    events.push(Parsed::Answer(answer));
                    at += n;
                }
                Step::PasteStart(n) => {
                    self.paste = Some(Vec::new());
                    at += n;
                }
            }
        }
        self.pending.drain(..at);
        events
    }
}

/// One result of [`Parser::feed`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Parsed {
    Event(Event),
    Answer(Answer),
}

/// An answer to the probe of [`Terminal`](crate::Terminal). Only the terminal reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Answer {
    /// The kitty keyboard flags that are on: the answer to `CSI ? u`.
    KittyKeyboard(u8),
    /// The primary device attributes. A terminal answers the queries in order, so this answer ends a probe.
    DeviceAttributes,
}

/// The result of one parse at the start of the input.
#[derive(Debug)]
enum Step {
    /// The input ends inside a sequence.
    Incomplete,
    /// The first bytes are no event, such as an unknown sequence.
    Skip(usize),
    /// The first bytes are an event.
    Event(Event, usize),
    /// The first bytes are a probe answer.
    Answer(Answer, usize),
    /// The first bytes open a bracketed paste.
    PasteStart(usize),
}

fn parse(input: &[u8]) -> Step {
    if input[0] != ESC {
        return parse_ground(input);
    }
    let Some(&next) = input.get(1) else {
        return Step::Event(Event::Key(Key::new(Code::Escape)), 1);
    };
    match next {
        b'O' => parse_ss3(input),
        b'[' => parse_csi(input),
        // OSC, DCS, SOS, PM, and APC.
        b']' | b'P' | b'X' | b'^' | b'_' => parse_string(input),
        ESC => Step::Event(Event::Key(with_alt(Key::new(Code::Escape))), 2),
        _ => match parse_ground(&input[1..]) {
            Step::Event(Event::Key(key), n) => Step::Event(Event::Key(with_alt(key)), n + 1),
            Step::Incomplete => Step::Incomplete,
            _ => Step::Skip(1),
        },
    }
}

/// A key that comes after an escape byte. Alt+key types no text.
fn with_alt(mut key: Key) -> Key {
    key.modifiers = key.modifiers | Modifiers::ALT;
    key.text.clear();
    key
}

fn parse_ground(input: &[u8]) -> Step {
    let byte = input[0];
    let key = match byte {
        // Ctrl+space and ctrl+@ send the same byte.
        0x00 => ctrl(' '),
        0x08 | 0x7f => Key::new(Code::Backspace),
        0x09 => Key::new(Code::Tab),
        0x0d => Key::new(Code::Enter),
        0x01..=0x1a => ctrl(char::from(byte + 0x60)),
        ESC => Key::new(Code::Escape),
        0x1c..=0x1f => ctrl(char::from(byte + 0x40)),
        _ => return parse_text(input),
    };
    Step::Event(Event::Key(key), 1)
}

fn ctrl(character: char) -> Key {
    let mut key = Key::new(Code::Char(character));
    key.modifiers = Modifiers::CTRL;
    key
}

/// One typed code point. A code point that the end of the input cuts waits for the next read.
fn parse_text(input: &[u8]) -> Step {
    // A code point has at most 4 bytes. A cut one at the end of the input waits, and an invalid byte skips it.
    let head = &input[..input.len().min(4)];
    let text = match std::str::from_utf8(head) {
        Ok(text) => text,
        Err(error) if error.valid_up_to() > 0 => std::str::from_utf8(&head[..error.valid_up_to()]).unwrap_or_default(),
        Err(error) => return error.error_len().map_or(Step::Incomplete, Step::Skip),
    };
    let Some(character) = text.chars().next() else {
        return Step::Skip(1);
    };
    let mut key = Key::new(Code::Char(character));
    key.text.push(character);
    Step::Event(Event::Key(key), character.len_utf8())
}

fn parse_ss3(input: &[u8]) -> Step {
    let Some(&byte) = input.get(2) else {
        return Step::Incomplete;
    };
    match byte {
        ESC => Step::Skip(2),
        _ => letter_code(byte).map_or(Step::Skip(3), |code| Step::Event(Event::Key(Key::new(code)), 3)),
    }
}

/// The key of the last byte of an SS3 key or a legacy CSI key.
fn letter_code(byte: u8) -> Option<Code> {
    Some(match byte {
        b'A' => Code::Up,
        b'B' => Code::Down,
        b'C' => Code::Right,
        b'D' => Code::Left,
        b'F' => Code::End,
        b'H' => Code::Home,
        b'P' => Code::F(1),
        b'Q' => Code::F(2),
        b'R' => Code::F(3),
        b'S' => Code::F(4),
        _ => return None,
    })
}

/// A string sequence ends at ST, and an OSC also at BEL. Only an OSC 11 answer gives an event.
fn parse_string(input: &[u8]) -> Step {
    let osc = input[1] == b']';
    let mut at = 2;
    let (payload_end, end) = loop {
        let Some(&byte) = input.get(at) else {
            return Step::Incomplete;
        };
        match byte {
            BEL if osc => break (at, at + 1),
            ESC => match input.get(at + 1) {
                None => return Step::Incomplete,
                Some(b'\\') => break (at, at + 2),
                // An escape that starts no ST begins a new sequence, so the broken string ends before it.
                Some(_) => return Step::Skip(at),
            },
            _ => at += 1,
        }
    };
    if !osc {
        return Step::Skip(end);
    }
    match input[2..payload_end].strip_prefix(b"11;").and_then(parse_color) {
        Some(color) => Step::Event(Event::Background(color), end),
        None => Step::Skip(end),
    }
}

/// Parse an X11 color spec `rgb:R/G/B` or `rgba:R/G/B/A`, with one to four hex digits for each channel.
fn parse_color(spec: &[u8]) -> Option<Rgb> {
    let (channels, body) = if let Some(body) = spec.strip_prefix(b"rgb:") {
        (3, body)
    } else {
        (4, spec.strip_prefix(b"rgba:")?)
    };
    let mut parts = body.split(|&byte| byte == b'/');
    let mut rgb = [0; 3];
    for index in 0..channels {
        let digits = parts.next()?;
        if digits.is_empty() || digits.len() > 4 {
            return None;
        }
        let mut value: u32 = 0;
        for &digit in digits {
            value = value * 16 + char::from(digit).to_digit(16)?;
        }
        if let Some(channel) = rgb.get_mut(index) {
            let full = (1 << (4 * digits.len())) - 1;
            *channel = u8::try_from(value * 255 / full).ok()?;
        }
    }
    if parts.next().is_some() {
        return None;
    }
    let [red, green, blue] = rgb;
    Some(Rgb { red, green, blue })
}

fn parse_csi(input: &[u8]) -> Step {
    let mut at = 2;
    let last = loop {
        let Some(&byte) = input.get(at) else {
            return Step::Incomplete;
        };
        match byte {
            0x40..=0x7e => break at,
            0x20..=0x3f => at += 1,
            // A control byte inside the sequence breaks it, and it can start the next sequence.
            _ => return Step::Skip(at),
        }
    };
    let n = last + 1;
    let params = &input[2..last];
    if let Some(code) = letter_code(input[last]) {
        return legacy_key(code, params, n);
    }
    match input[last] {
        b'M' if params.is_empty() => parse_x10_mouse(input),
        b'Z' => {
            let mut key = Key::new(Code::Tab);
            key.modifiers = Modifiers::SHIFT;
            Step::Event(Event::Key(key), n)
        }
        b'~' => tilde_key(params, n),
        b'I' => Step::Event(Event::Focus(true), n),
        b'O' => Step::Event(Event::Focus(false), n),
        b'M' | b'm' => match params.strip_prefix(b"<") {
            Some(body) => sgr_mouse(body, input[last] == b'm', n),
            None => Step::Skip(n),
        },
        b'c' if params.starts_with(b"?") => Step::Answer(Answer::DeviceAttributes, n),
        b'n' => match params {
            b"?997;1" | b"?997;2" => Step::Event(Event::SchemeChanged, n),
            _ => Step::Skip(n),
        },
        b'u' if params.starts_with(b"?") => match number(&params[1..]).and_then(|flags| u8::try_from(flags).ok()) {
            Some(flags) => Step::Answer(Answer::KittyKeyboard(flags), n),
            None => Step::Skip(n),
        },
        b'u' => kitty_key(params, n),
        _ => Step::Skip(n),
    }
}

/// `CSI 1 ; modifiers[:event] {ABCDEFHPQRS}`.
fn legacy_key(code: Code, params: &[u8], n: usize) -> Step {
    let mut fields = fields(params);
    fields.next();
    finish_key(Key::new(code), fields, n)
}

/// `CSI number ; modifiers[:event] ~`.
fn tilde_key(params: &[u8], n: usize) -> Step {
    let mut fields = fields(params);
    let Some(first) = fields.next().and_then(number) else {
        return Step::Skip(n);
    };
    let code = match first {
        1 | 7 => Code::Home,
        2 => Code::Insert,
        3 => Code::Delete,
        4 | 8 => Code::End,
        5 => Code::PageUp,
        6 => Code::PageDown,
        11..=15 => Code::F(to_u8(first - 10)),
        17..=21 => Code::F(to_u8(first - 11)),
        23..=26 => Code::F(to_u8(first - 12)),
        27 => return modify_other_keys(fields, n),
        200 => return Step::PasteStart(n),
        _ => return Step::Skip(n),
    };
    finish_key(Key::new(code), fields, n)
}

/// xterm modifyOtherKeys: `CSI 27 ; modifiers ; code ~`, with a code as in the kitty protocol.
fn modify_other_keys<'a>(mut fields: impl Iterator<Item = &'a [u8]>, n: usize) -> Step {
    let (Some(Some(modifiers)), Some(Some(code))) = (
        fields.next().map(parse_modifiers),
        fields.next().and_then(number).map(kitty_code),
    ) else {
        return Step::Skip(n);
    };
    let mut key = Key::new(code);
    key.modifiers = modifiers;
    typed_text(&mut key);
    Step::Event(Event::Key(key), n)
}

/// `CSI code[:shifted[:base]] ; modifiers[:event] u`, the kitty keyboard protocol. yuke asks for no text field.
fn kitty_key(params: &[u8], n: usize) -> Step {
    let mut fields = fields(params);
    let mut codes = fields.next().unwrap_or_default().split(|&byte| byte == b':');
    let Some(Some(code)) = codes.next().and_then(number).map(kitty_code) else {
        return Step::Skip(n);
    };
    let mut key = Key::new(code);
    key.shifted = codes.next().and_then(number).and_then(char::from_u32);
    key.base_layout = codes.next().and_then(number).and_then(char::from_u32);
    match finish_key(key, fields, n) {
        Step::Event(Event::Key(mut key), n) => {
            typed_text(&mut key);
            Step::Event(Event::Key(key), n)
        }
        step => step,
    }
}

/// Read the modifier field of a key. A release gives no event.
fn finish_key<'a>(mut key: Key, mut fields: impl Iterator<Item = &'a [u8]>, n: usize) -> Step {
    if let Some(field) = fields.next() {
        match parse_modifiers(field) {
            Some(modifiers) => key.modifiers = modifiers,
            None => return Step::Skip(n),
        }
    }
    Step::Event(Event::Key(key), n)
}

/// A key with no modifier, such as a keypad digit, types its character. A key with shift alone, such as shift+space as
/// `CSI 32 ; 2 u`, types its shifted character.
fn typed_text(key: &mut Key) {
    let locks = Modifiers::CAPS_LOCK | Modifiers::NUM_LOCK;
    let Code::Char(character) = key.code else {
        return;
    };
    if !key.text.is_empty() || !(character.is_ascii_graphic() || character == ' ') {
        return;
    }
    match key.modifiers.without(locks) {
        Modifiers::NONE => key.text.push(character),
        Modifiers::SHIFT => {
            let upper = character.to_ascii_uppercase();
            key.text.push(upper);
            key.shifted.get_or_insert(upper);
        }
        _ => {}
    }
}

/// `modifiers[:event]`: the bits are the field minus one. Event 1 is a press and 2 a repeat. A release (3) or another
/// event gives `None`.
fn parse_modifiers(field: &[u8]) -> Option<Modifiers> {
    let mut parts = field.split(|&byte| byte == b':');
    let mask = match parts.next() {
        Some([]) | None => 1,
        Some(digits) => number(digits)?,
    };
    let bits = u8::try_from(mask.saturating_sub(1)).ok()?;
    match parts.next() {
        None | Some(b"1" | b"2") => Some(Modifiers(bits)),
        Some(_) => None,
    }
}

/// The key of a kitty key number. A keypad key is the key that it types. A key with no name in JavaScript, such as
/// a lock key, a media key, or the middle key of the keypad, gives `None`.
fn kitty_code(number: u32) -> Option<Code> {
    Some(match number {
        // Code 0 is text with no key, and yuke asks for no text reports. Modifier keys alone come only with flag 8.
        0 | 57358..=57362 | 57427..=57454 => return None,
        8 | 127 => Code::Backspace,
        9 => Code::Tab,
        // The second number of each pair is the key on the keypad.
        13 | 57414 => Code::Enter,
        27 => Code::Escape,
        57348 | 57425 => Code::Insert,
        57349 | 57426 => Code::Delete,
        57350 | 57417 => Code::Left,
        57351 | 57418 => Code::Right,
        57352 | 57419 => Code::Up,
        57353 | 57420 => Code::Down,
        57354 | 57421 => Code::PageUp,
        57355 | 57422 => Code::PageDown,
        57356 | 57423 => Code::Home,
        57357 | 57424 => Code::End,
        57363 => Code::Menu,
        57364..=57398 => Code::F(to_u8(number - 57363)),
        57399..=57408 => Code::Char(char::from_digit(number - 57399, 10)?),
        57409 => Code::Char('.'),
        57410 => Code::Char('/'),
        57411 => Code::Char('*'),
        57412 => Code::Char('-'),
        57413 => Code::Char('+'),
        57415 => Code::Char('='),
        57416 => Code::Char(','),
        _ => Code::Char(char::from_u32(number)?),
    })
}

/// A key or button number that the caller took from a small range.
fn to_u8(number: u32) -> u8 {
    u8::try_from(number).unwrap_or(u8::MAX)
}

/// `CSI < button ; column ; row {M|m}`.
fn sgr_mouse(body: &[u8], release: bool, n: usize) -> Step {
    let mut fields = fields(body);
    let (Some(mask), Some(column), Some(row)) = (
        fields.next().and_then(number),
        fields.next().map(|field| number(field).unwrap_or(1)),
        fields.next().map(|field| number(field).unwrap_or(1)),
    ) else {
        return Step::Skip(n);
    };
    mouse(mask, column, row, Some(release)).map_or(Step::Skip(n), |mouse| Step::Event(Event::Mouse(mouse), n))
}

/// `CSI M` and three bytes, each offset by 32, from a terminal without SGR reports.
fn parse_x10_mouse(input: &[u8]) -> Step {
    let [_, _, _, mask, column, row, ..] = *input else {
        return Step::Incomplete;
    };
    let offset = |byte: u8| u32::from(byte.saturating_sub(32));
    mouse(offset(mask), offset(column), offset(row), None)
        .map_or(Step::Skip(6), |mouse| Step::Event(Event::Mouse(mouse), 6))
}

/// A mouse report from its button mask and one-based place. `release` is `None` for an X10 report, which has no
/// release flag.
fn mouse(mask: u32, column: u32, row: u32, release: Option<bool>) -> Option<Mouse> {
    // Only pixel reports set the leave bit, and yuke asks for none.
    if mask & 0x100 != 0 {
        return None;
    }
    let button = match mask & 0b1100_0011 {
        0 => Button::Left,
        1 => Button::Middle,
        2 => Button::Right,
        3 => Button::None,
        64 => Button::WheelUp,
        65 => Button::WheelDown,
        66 => Button::WheelRight,
        67 => Button::WheelLeft,
        extra @ 128..=131 => Button::Extra(to_u8(extra - 120)),
        _ => return None,
    };
    let motion = mask & 32 != 0;
    let kind = match (motion, button, release) {
        (true, Button::None, _) => MouseKind::Motion,
        (true, _, _) => MouseKind::Drag,
        (false, _, Some(true)) | (false, Button::None, None) => MouseKind::Release,
        _ => MouseKind::Press,
    };
    // The shift, alt, and ctrl bits of the mask are the first three modifier bits, moved left by 2.
    let modifiers = Modifiers(to_u8((mask >> 2) & 7));
    let place = |value: u32| u16::try_from(value.saturating_sub(1)).unwrap_or(u16::MAX);
    Some(Mouse {
        column: place(column),
        row: place(row),
        button,
        kind,
        modifiers,
    })
}

fn fields(params: &[u8]) -> impl Iterator<Item = &[u8]> {
    params.split(|&byte| byte == b';')
}

/// A decimal parameter. An empty or non-decimal one is `None`.
fn number(digits: &[u8]) -> Option<u32> {
    if digits.is_empty() {
        return None;
    }
    digits.iter().try_fold(0u32, |value, &digit| {
        let digit = char::from(digit).to_digit(10)?;
        value.checked_mul(10)?.checked_add(digit)
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// The paste text with each line end as `\n` and no control character except `\t`, because a control character in a
/// cell can break the screen.
fn clean_paste(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    let mut clean = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        match character {
            '\r' => {
                characters.next_if_eq(&'\n');
                clean.push('\n');
            }
            '\n' | '\t' => clean.push(character),
            _ if character.is_control() => {}
            _ => clean.push(character),
        }
    }
    clean
}

#[cfg(test)]
mod tests;
