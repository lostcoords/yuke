//! The events that the parser reads from the terminal.

use std::ops::{BitOr, BitOrAssign};

/// One input event of the terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// A key press or a key repeat. yuke asks for no key releases.
    Key(Key),
    /// A mouse button, wheel, or motion report.
    Mouse(Mouse),
    /// The window gained the focus.
    FocusGained,
    /// The window lost the focus.
    FocusLost,
    /// The text of a bracketed paste, with each line end as `\n` and no other control character except `\t`.
    Paste(String),
    /// The background color: the answer to [`BACKGROUND_QUERY`](crate::BACKGROUND_QUERY).
    Background(Rgb),
    /// The color scheme of the terminal changed (a mode 2031 report). Ask for the background again.
    SchemeChanged,
}

/// A key and the modifiers that the terminal reports with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    /// The key.
    pub code: Code,
    /// The modifiers.
    pub modifiers: Modifiers,
    /// The text that the key types. It is empty for a key that types nothing, such as ctrl+a or an arrow.
    pub text: String,
    /// The key with shift on the current layout, from a kitty terminal.
    pub shifted: Option<char>,
    /// The key at the same place on a US layout, from a kitty terminal.
    pub base_layout: Option<char>,
}

impl Key {
    /// A key with no modifiers and no text.
    pub fn new(code: Code) -> Self {
        Self {
            code,
            modifiers: Modifiers::NONE,
            text: String::new(),
            shifted: None,
            base_layout: None,
        }
    }
}

/// The identity of a key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Code {
    /// A key of one code point, also with modifiers: [`Key::text`] holds what it types. Space is `Char(' ')`. A typed
    /// grapheme of more code points, such as an emoji with a skin tone, comes as one key for each code point.
    Char(char),
    /// Enter.
    Enter,
    /// Tab. Shift+tab is `Tab` with shift.
    Tab,
    /// Backspace.
    Backspace,
    /// Escape.
    Escape,
    /// Insert.
    Insert,
    /// Delete.
    Delete,
    /// Arrow left.
    Left,
    /// Arrow right.
    Right,
    /// Arrow up.
    Up,
    /// Arrow down.
    Down,
    /// Page up.
    PageUp,
    /// Page down.
    PageDown,
    /// Home.
    Home,
    /// End.
    End,
    /// Menu.
    Menu,
    /// A function key from 1 to 35.
    F(u8),
}

/// A set of modifiers, in the bit order of the kitty keyboard protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Modifiers(pub(crate) u8);

impl Modifiers {
    /// No modifier.
    pub const NONE: Self = Self(0);
    /// Shift.
    pub const SHIFT: Self = Self(1);
    /// Alt (option).
    pub const ALT: Self = Self(1 << 1);
    /// Control.
    pub const CTRL: Self = Self(1 << 2);
    /// Super (command, windows).
    pub const SUPER: Self = Self(1 << 3);
    /// Hyper.
    pub const HYPER: Self = Self(1 << 4);
    /// Meta.
    pub const META: Self = Self(1 << 5);
    /// Caps lock is on.
    pub const CAPS_LOCK: Self = Self(1 << 6);
    /// Num lock is on.
    pub const NUM_LOCK: Self = Self(1 << 7);

    /// The bits of the set, in the order of the kitty keyboard protocol.
    pub const fn bits(self) -> u8 {
        self.0
    }

    /// True when the set holds each modifier of `other`.
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The set without the modifiers of `other`.
    #[must_use]
    pub(crate) const fn without(self, other: Self) -> Self {
        Self(self.0 & !other.0)
    }
}

impl BitOr for Modifiers {
    type Output = Self;

    fn bitor(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

impl BitOrAssign for Modifiers {
    fn bitor_assign(&mut self, other: Self) {
        self.0 |= other.0;
    }
}

/// A mouse report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mouse {
    /// The column, from 0.
    pub column: u16,
    /// The row, from 0.
    pub row: u16,
    /// The button. A motion with no button held reports [`Button::None`].
    pub button: Button,
    /// What the mouse did.
    pub kind: MouseKind,
    /// Shift, alt, and ctrl, as far as the terminal reports them.
    pub modifiers: Modifiers,
}

/// A mouse button or a wheel direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Button {
    /// The left button.
    Left,
    /// The middle button.
    Middle,
    /// The right button.
    Right,
    /// No button.
    None,
    /// The wheel up.
    WheelUp,
    /// The wheel down.
    WheelDown,
    /// The wheel left.
    WheelLeft,
    /// The wheel right.
    WheelRight,
    /// An extra button from 8 to 11.
    Extra(u8),
}

/// What a mouse report says.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseKind {
    /// A button went down, or the wheel turned.
    Press,
    /// A button went up.
    Release,
    /// The mouse moved with no button held.
    Motion,
    /// The mouse moved with a button held.
    Drag,
}

/// A 24-bit color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Rgb {
    /// The red channel.
    pub red: u8,
    /// The green channel.
    pub green: u8,
    /// The blue channel.
    pub blue: u8,
}
