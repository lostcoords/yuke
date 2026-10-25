use super::*;

fn key(code: Code, modifiers: Modifiers, text: &str) -> Event {
    let mut key = Key::new(code);
    key.modifiers = modifiers;
    text.clone_into(&mut key.text);
    Event::Key(key)
}

fn char_key(character: char) -> Event {
    key(Code::Char(character), Modifiers::NONE, &character.to_string())
}

fn mouse(column: u16, row: u16, button: Button, kind: MouseKind, modifiers: Modifiers) -> Event {
    Event::Mouse(Mouse {
        column,
        row,
        button,
        kind,
        modifiers,
    })
}

fn rgb(red: u8, green: u8, blue: u8) -> Rgb {
    Rgb { red, green, blue }
}

/// The events of `parsed`. A probe answer fails the test.
fn only_events(parsed: Vec<Parsed>) -> Vec<Event> {
    parsed
        .into_iter()
        .map(|parsed| match parsed {
            Parsed::Event(event) => event,
            Parsed::Answer(answer) => panic!("an answer {answer:?}"),
        })
        .collect()
}

fn parse_all(bytes: &[u8]) -> Vec<Event> {
    only_events(Parser::new().feed(bytes))
}

/// The test sequences that start with an escape byte, and their events.
fn sequences() -> Vec<(&'static [u8], Vec<Event>)> {
    let none = Modifiers::NONE;
    vec![
        (b"\x1b[A", vec![key(Code::Up, none, "")]),
        (b"\x1bOA", vec![key(Code::Up, none, "")]),
        (b"\x1b[1;5A", vec![key(Code::Up, Modifiers::CTRL, "")]),
        (b"\x1b[3~", vec![key(Code::Delete, none, "")]),
        (b"\x1b[5;2~", vec![key(Code::PageUp, Modifiers::SHIFT, "")]),
        (b"\x1b[15~", vec![key(Code::F(5), none, "")]),
        (b"\x1b[24~", vec![key(Code::F(12), none, "")]),
        (b"\x1b[Z", vec![key(Code::Tab, Modifiers::SHIFT, "")]),
        (b"\x1b\x1b", vec![key(Code::Escape, Modifiers::ALT, "")]),
        (b"\x1b[27u", vec![key(Code::Escape, none, "")]),
        (b"\x1b[13;2u", vec![key(Code::Enter, Modifiers::SHIFT, "")]),
        (b"\x1b[97;5u", vec![key(Code::Char('a'), Modifiers::CTRL, "")]),
        (b"\x1b[97;5:2u", vec![key(Code::Char('a'), Modifiers::CTRL, "")]),
        (b"\x1b[97;;97u", vec![key(Code::Char('a'), none, "a")]),
        (
            b"\x1b[57441;2u",
            vec![key(Code::Modifier(Modifier::LeftShift), Modifiers::SHIFT, "")],
        ),
        (b"\x1b[57430u", vec![key(Code::Media(Media::PlayPause), none, "")]),
        (b"\x1b[57375u", vec![key(Code::F(12), none, "")]),
        (b"\x1b[27;2;13~", vec![key(Code::Enter, Modifiers::SHIFT, "")]),
        (b"\x1b[27;5;105~", vec![key(Code::Char('i'), Modifiers::CTRL, "")]),
        (b"\x1b[I", vec![Event::Focus(true)]),
        (b"\x1b[O", vec![Event::Focus(false)]),
        (
            b"\x1b[<0;10;5M",
            vec![mouse(9, 4, Button::Left, MouseKind::Press, none)],
        ),
        (
            b"\x1b[<0;10;5m",
            vec![mouse(9, 4, Button::Left, MouseKind::Release, none)],
        ),
        (b"\x1b[<32;3;4M", vec![mouse(2, 3, Button::Left, MouseKind::Drag, none)]),
        (
            b"\x1b[<35;3;4M",
            vec![mouse(2, 3, Button::None, MouseKind::Motion, none)],
        ),
        (
            b"\x1b[<64;1;1M",
            vec![mouse(0, 0, Button::WheelUp, MouseKind::Press, none)],
        ),
        (
            b"\x1b[<20;1;1M",
            vec![mouse(
                0,
                0,
                Button::Left,
                MouseKind::Press,
                Modifiers::SHIFT | Modifiers::CTRL,
            )],
        ),
        (
            b"\x1b[<128;1;1M",
            vec![mouse(0, 0, Button::Extra(8), MouseKind::Press, none)],
        ),
        (b"\x1b[M !!", vec![mouse(0, 0, Button::Left, MouseKind::Press, none)]),
        (b"\x1b[M#!!", vec![mouse(0, 0, Button::None, MouseKind::Release, none)]),
        (
            b"\x1b]11;rgb:1e1e/1e1e/2e2e\x07",
            vec![Event::Background(rgb(0x1e, 0x1e, 0x2e))],
        ),
        (
            b"\x1b]11;rgb:ffff/8080/0000\x1b\\",
            vec![Event::Background(rgb(0xff, 0x80, 0))],
        ),
        (b"\x1b]11;rgb:ff/80/00\x07", vec![Event::Background(rgb(0xff, 0x80, 0))]),
        (b"\x1b]11;rgba:f/0/0/f\x07", vec![Event::Background(rgb(0xff, 0, 0))]),
        (b"\x1b[?997;1n", vec![Event::Scheme(Scheme::Dark)]),
        (b"\x1b[?997;2n", vec![Event::Scheme(Scheme::Light)]),
        (
            b"\x1b[200~one\r\ntwo\x1b[201~",
            vec![Event::Paste("one\ntwo".to_owned())],
        ),
    ]
}

#[test]
fn probe_answers_read_as_answers_also_when_a_read_cuts_them() {
    let cases: [(&[u8], Answer); 3] = [
        (b"\x1b[?2031;2$y", Answer::SchemeReports),
        (b"\x1b[?5u", Answer::KittyKeyboard(5)),
        (b"\x1b[?62;22c", Answer::DeviceAttributes),
    ];
    for (bytes, answer) in cases {
        for cut in 2..=bytes.len() {
            let mut parser = Parser::new();
            let mut read = parser.feed(&bytes[..cut]);
            read.extend(parser.feed(&bytes[cut..]));
            assert_eq!(
                read,
                [Parsed::Answer(answer)],
                "{:?} cut at {cut}",
                String::from_utf8_lossy(bytes)
            );
        }
    }
}

#[test]
fn sequences_read_as_their_events_also_when_a_read_cuts_them() {
    // A cut after the first escape byte reads as the escape key, as in libvaxis, so each cut starts later. The last
    // cut feeds the whole sequence.
    for (bytes, events) in sequences() {
        for cut in 2..=bytes.len() {
            let mut parser = Parser::new();
            let mut read = only_events(parser.feed(&bytes[..cut]));
            read.extend(only_events(parser.feed(&bytes[cut..])));
            assert_eq!(read, events, "{:?} cut at {cut}", String::from_utf8_lossy(bytes));
        }
    }
}

#[test]
fn ground_bytes_read_as_keys() {
    let ctrl = Modifiers::CTRL;
    let cases: [(&[u8], Event); 10] = [
        (b"a", char_key('a')),
        (b"G", char_key('G')),
        (b"\x01", key(Code::Char('a'), ctrl, "")),
        (b"\x00", key(Code::Char(' '), ctrl, "")),
        (b"\x1c", key(Code::Char('\\'), ctrl, "")),
        (b"\r", key(Code::Enter, Modifiers::NONE, "")),
        (b"\t", key(Code::Tab, Modifiers::NONE, "")),
        (b"\x7f", key(Code::Backspace, Modifiers::NONE, "")),
        (b"\x1b", key(Code::Escape, Modifiers::NONE, "")),
        (b"\x1ba", key(Code::Char('a'), Modifiers::ALT, "")),
    ];
    for (bytes, event) in cases {
        assert_eq!(parse_all(bytes), [event], "{bytes:?}");
    }
}

#[test]
fn typed_text_reads_one_grapheme_per_key() {
    assert_eq!(parse_all("ab".as_bytes()), [char_key('a'), char_key('b')]);
    assert_eq!(parse_all("é".as_bytes()), [char_key('é')]);
    assert_eq!(
        parse_all("e\u{301}x".as_bytes()),
        [key(Code::Cluster, Modifiers::NONE, "e\u{301}"), char_key('x')]
    );
    assert_eq!(parse_all("👋🏿".as_bytes()), [key(Code::Cluster, Modifiers::NONE, "👋🏿")]);
}

#[test]
fn a_utf8_character_that_a_read_cuts_waits_for_the_rest() {
    let bytes = "中".as_bytes();
    let mut parser = Parser::new();
    assert_eq!(only_events(parser.feed(&bytes[..1])), []);
    assert_eq!(only_events(parser.feed(&bytes[1..])), [char_key('中')]);
}

#[test]
fn invalid_utf8_reads_as_no_key() {
    assert_eq!(parse_all(b"\xffa"), [char_key('a')]);
    assert_eq!(parse_all(b"\x1b\xffa"), [char_key('a')]);
}

#[test]
fn kitty_keys_keep_their_alternate_keys() {
    let mut expected = Key::new(Code::Char('й'));
    expected.modifiers = Modifiers::CTRL;
    expected.shifted = Some('Й');
    expected.base_layout = Some('q');
    assert_eq!(parse_all("\x1b[1081:1049:113;5u".as_bytes()), [Event::Key(expected)]);
}

#[test]
fn shift_alone_types_the_shifted_character() {
    let mut space = Key::new(Code::Char(' '));
    space.modifiers = Modifiers::SHIFT;
    space.text = " ".to_owned();
    space.shifted = Some(' ');
    assert_eq!(parse_all(b"\x1b[32;2u"), [Event::Key(space)]);

    let mut letter = Key::new(Code::Char('a'));
    letter.modifiers = Modifiers::SHIFT | Modifiers::CAPS_LOCK;
    letter.text = "A".to_owned();
    letter.shifted = Some('A');
    assert_eq!(parse_all(b"\x1b[97;66u"), [Event::Key(letter)]);
}

#[test]
fn keypad_keys_read_as_their_keys_on_the_keypad() {
    let mut zero = Key::new(Code::Char('0'));
    zero.keypad = true;
    let mut enter = Key::new(Code::Enter);
    enter.keypad = true;
    let mut begin = Key::new(Code::Begin);
    begin.keypad = true;
    assert_eq!(
        parse_all(b"\x1b[57399u\x1b[57414u\x1b[57427~"),
        [Event::Key(zero), Event::Key(enter), Event::Key(begin)]
    );
}

#[test]
fn sequences_with_no_event_read_as_no_key() {
    // A DCS answer, an OSC 52 answer, an unknown CSI, a DECRPM for a mode that the terminal lacks, and an APC.
    let answers = b"\x1bP>|kitty\x1b\\\x1b]52;c;eA==\x07\x1b[?1;2;3X\x1b[?2031;0$y\x1b_Gi=1;OK\x1b\\x";
    assert_eq!(parse_all(answers), [char_key('x')]);
    // A DCS with a BEL inside, and a DCS with the payload of a background answer. Only an OSC ends at BEL or
    // gives a color.
    let strings = b"\x1bPa\x07b\x1b\\\x1bP11;rgb:ffff/ffff/ffff\x1b\\x";
    assert_eq!(parse_all(strings), [char_key('x')]);
    // Two key releases, a kitty report of text with no key, and a kitty report of an unknown event.
    let keys = b"\x1b[97;5:3u\x1b[1;1:3A\x1b[0;;233u\x1b[97;1:4ux";
    assert_eq!(parse_all(keys), [char_key('x')]);
}

#[test]
fn a_broken_sequence_leaves_the_next_sequence_intact() {
    assert_eq!(parse_all(b"\x1b]11;rgb:\x1b[A"), [key(Code::Up, Modifiers::NONE, "")]);
    assert_eq!(parse_all(b"\x1b[1;\x1b[B"), [key(Code::Down, Modifiers::NONE, "")]);
    assert_eq!(parse_all(b"\x1bPq\x1b[C"), [key(Code::Right, Modifiers::NONE, "")]);
}

#[test]
fn a_paste_keeps_escape_sequences_as_text() {
    let events = parse_all(b"\x1b[200~a\x1b[Ab\rc\x01\td\x1b[201~e");
    assert_eq!(events, [Event::Paste("a[Ab\nc\td".to_owned()), char_key('e')]);
}

#[test]
fn a_paste_that_reads_cut_waits_for_its_end_marker() {
    let mut parser = Parser::new();
    assert_eq!(only_events(parser.feed(b"\x1b[200~one")), []);
    assert_eq!(only_events(parser.feed(b" two\x1b[2")), []);
    assert_eq!(only_events(parser.feed(b"01~")), [Event::Paste("one two".to_owned())]);
}

#[test]
fn a_large_paste_stays_whole() {
    let mut parser = Parser::new();
    assert_eq!(only_events(parser.feed(b"\x1b[200~")), []);
    let chunk = [b'a'; 4096];
    for _ in 0..1024 {
        assert_eq!(only_events(parser.feed(&chunk)), []);
    }
    let paste = only_events(parser.feed(b"\x1b[201~"));
    assert_eq!(paste, [Event::Paste("a".repeat(4096 * 1024))]);
}
