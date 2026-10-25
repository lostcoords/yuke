//! A cell grid that writes only its changes. The caller draws the next frame into the grid, and [`Screen::render`]
//! writes the escape bytes that turn the last frame into it.

use std::io::Write as _;
use std::ops::BitOr;

use unicode_segmentation::UnicodeSegmentation;

use crate::event::Rgb;
use crate::width::grapheme_width;

/// The size of a terminal in cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Size {
    /// The cells in a row.
    pub columns: u16,
    /// The rows.
    pub rows: u16,
}

/// A terminal color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Color {
    /// The default color of the terminal.
    #[default]
    Default,
    /// An entry of the 256-color palette. Entries 0 to 15 follow the theme of the terminal.
    Index(u8),
    /// A 24-bit color.
    Rgb(Rgb),
}

/// Text attributes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Attributes(u8);

impl Attributes {
    /// No attribute.
    pub const NONE: Self = Self(0);
    /// Bold.
    pub const BOLD: Self = Self(1);
    /// Dim.
    pub const DIM: Self = Self(1 << 1);
    /// Italic.
    pub const ITALIC: Self = Self(1 << 2);
    /// Underline.
    pub const UNDERLINE: Self = Self(1 << 3);
    /// Reverse video.
    pub const REVERSE: Self = Self(1 << 4);

    /// True when the set holds each attribute of `other`.
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for Attributes {
    type Output = Self;

    fn bitor(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// The look of a cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Style {
    /// The text color.
    pub fg: Color,
    /// The background color.
    pub bg: Color,
    /// The underline color. It does not turn the underline on.
    pub underline_color: Color,
    /// The attributes.
    pub attributes: Attributes,
}

/// The grapheme of a cell. Most graphemes fit inline, so they need no allocation of their own.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Glyph {
    Inline { length: u8, bytes: [u8; 14] },
    Heap(Box<str>),
}

impl Glyph {
    // The unused bytes are zero, as in `Glyph::new`, so a written space equals a blank cell.
    const SPACE: Self = Self::Inline {
        length: 1,
        bytes: [b' ', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    };
    /// The second cell of a wide grapheme. The terminal draws it with the first cell.
    const TAIL: Self = Self::Inline {
        length: 0,
        bytes: [0; 14],
    };

    fn new(grapheme: &str) -> Self {
        let mut bytes = [0; 14];
        match (bytes.get_mut(..grapheme.len()), u8::try_from(grapheme.len())) {
            (Some(inline), Ok(length)) => {
                inline.copy_from_slice(grapheme.as_bytes());
                Self::Inline { length, bytes }
            }
            _ => Self::Heap(grapheme.into()),
        }
    }

    fn as_bytes(&self) -> &[u8] {
        match self {
            Self::Inline { length, bytes } => &bytes[..usize::from(*length)],
            Self::Heap(text) => text.as_bytes(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Cell {
    glyph: Glyph,
    /// 1 or 2 for a grapheme, 0 for the tail of a wide grapheme.
    width: u8,
    style: Style,
}

impl Cell {
    fn blank(style: Style) -> Self {
        Self {
            glyph: Glyph::SPACE,
            width: 1,
            style,
        }
    }

    fn tail(style: Style) -> Self {
        Self {
            glyph: Glyph::TAIL,
            width: 0,
            style,
        }
    }
}

/// The next frame and the frame on the terminal.
#[derive(Debug, Clone)]
pub struct Screen {
    size: Size,
    next: Vec<Cell>,
    shown: Vec<Cell>,
    cursor: Option<(u16, u16)>,
    shown_cursor: Option<(u16, u16)>,
    /// The terminal content is unknown, so the next render writes every cell.
    repaint: bool,
}

impl Screen {
    /// A blank screen of `size`. The first render writes every cell.
    pub fn new(size: Size) -> Self {
        let cells = usize::from(size.columns) * usize::from(size.rows);
        Self {
            size,
            next: vec![Cell::blank(Style::default()); cells],
            shown: vec![Cell::blank(Style::default()); cells],
            cursor: None,
            shown_cursor: None,
            repaint: true,
        }
    }

    /// The size of the grid.
    pub fn size(&self) -> Size {
        self.size
    }

    /// Change the size and blank the grid. The next render writes every cell.
    pub fn resize(&mut self, size: Size) {
        *self = Self::new(size);
    }

    /// Write every cell at the next render, for a terminal whose content changed under the screen, such as after a
    /// suspend.
    pub fn repaint(&mut self) {
        self.repaint = true;
    }

    /// Blank the next frame with the default style and hide its cursor.
    pub fn clear(&mut self) {
        self.next.fill(Cell::blank(Style::default()));
        self.cursor = None;
    }

    /// Blank the cells of a rectangle with `style`. The grid clips the rectangle.
    pub fn fill(&mut self, x: u16, y: u16, width: u16, height: u16, style: Style) {
        let right = x.saturating_add(width).min(self.size.columns);
        let bottom = y.saturating_add(height).min(self.size.rows);
        for row in y..bottom {
            for column in x..right {
                self.put(column, row, Cell::blank(style));
            }
        }
    }

    /// Write `text` on one row from column `x`, and return the column after it. The grid drops control characters
    /// and clips at the right edge; a wide grapheme that does not fit leaves a blank cell.
    pub fn text(&mut self, x: u16, y: u16, text: &str, style: Style) -> u16 {
        let mut column = x;
        if y >= self.size.rows {
            return column;
        }
        for grapheme in text.graphemes(true) {
            let wide = match grapheme_width(grapheme) {
                0 => continue,
                1 => false,
                _ => true,
            };
            let width = if wide { 2 } else { 1 };
            if column >= self.size.columns {
                break;
            }
            if u32::from(column) + u32::from(width) > u32::from(self.size.columns) {
                self.put(column, y, Cell::blank(style));
                column = self.size.columns;
                break;
            }
            self.put(
                column,
                y,
                Cell {
                    glyph: Glyph::new(grapheme),
                    width: if wide { 2 } else { 1 },
                    style,
                },
            );
            column += width;
        }
        column
    }

    /// Show the cursor at a column and a row of the next frame, or hide it with `None`.
    pub fn cursor(&mut self, at: Option<(u16, u16)>) {
        self.cursor = at.filter(|&(column, row)| column < self.size.columns && row < self.size.rows);
    }

    /// Append to `out` the bytes that turn the shown frame into the next frame, inside a synchronized update. An
    /// unchanged frame appends nothing.
    pub fn render(&mut self, out: &mut Vec<u8>) {
        if !self.repaint && self.cursor == self.shown_cursor && self.next == self.shown {
            return;
        }
        out.extend_from_slice(b"\x1b[?2026h\x1b[?25l\x1b[0m");
        let mut style = Style::default();
        let mut at: Option<(u16, u16)> = None;
        let columns = usize::from(self.size.columns);
        for (index, cell) in self.next.iter().enumerate() {
            if cell.width == 0 || (!self.repaint && self.shown.get(index) == Some(cell)) {
                continue;
            }
            let column = u16::try_from(index % columns).unwrap_or(u16::MAX);
            let row = u16::try_from(index / columns).unwrap_or(u16::MAX);
            if at != Some((column, row)) {
                move_to(out, column, row);
            }
            if cell.style != style {
                write_style(out, cell.style);
                style = cell.style;
            }
            out.extend_from_slice(cell.glyph.as_bytes());
            at = Some((column.saturating_add(u16::from(cell.width)), row));
        }
        out.extend_from_slice(b"\x1b[0m");
        if let Some((column, row)) = self.cursor {
            move_to(out, column, row);
            out.extend_from_slice(b"\x1b[?25h");
        }
        out.extend_from_slice(b"\x1b[?2026l");
        self.shown.clone_from(&self.next);
        self.shown_cursor = self.cursor;
        self.repaint = false;
    }

    /// Set one cell of the next frame. A cell that covers half of a wide grapheme blanks the other half.
    fn put(&mut self, column: u16, row: u16, cell: Cell) {
        let columns = usize::from(self.size.columns);
        let index = usize::from(row) * columns + usize::from(column);
        let wide = cell.width == 2;
        if self.next[index].width == 0 && column > 0 {
            let head = &mut self.next[index - 1];
            *head = Cell::blank(head.style);
        }
        if self.next[index].width == 2 && !wide {
            let tail = &mut self.next[index + 1];
            *tail = Cell::blank(tail.style);
        }
        if wide {
            if self.next[index + 1].width == 2 && usize::from(column) + 2 < columns {
                let tail = &mut self.next[index + 2];
                *tail = Cell::blank(tail.style);
            }
            self.next[index + 1] = Cell::tail(cell.style);
        }
        self.next[index] = cell;
    }
}

fn move_to(out: &mut Vec<u8>, column: u16, row: u16) {
    write_bytes(
        out,
        format_args!("\x1b[{};{}H", u32::from(row) + 1, u32::from(column) + 1),
    );
}

/// Write one SGR sequence that sets the whole style. The underline color goes in its own sequence, because a terminal
/// that does not know it can misread the parameters after it.
fn write_style(out: &mut Vec<u8>, style: Style) {
    out.extend_from_slice(b"\x1b[0");
    for (attribute, code) in [
        (Attributes::BOLD, ";1"),
        (Attributes::DIM, ";2"),
        (Attributes::ITALIC, ";3"),
        (Attributes::UNDERLINE, ";4"),
        (Attributes::REVERSE, ";7"),
    ] {
        if style.attributes.contains(attribute) {
            out.extend_from_slice(code.as_bytes());
        }
    }
    write_color(out, style.fg, 30, 90, 38);
    write_color(out, style.bg, 40, 100, 48);
    out.push(b'm');
    match style.underline_color {
        Color::Default => {}
        Color::Index(index) => write_bytes(out, format_args!("\x1b[58:5:{index}m")),
        Color::Rgb(Rgb { red, green, blue }) => write_bytes(out, format_args!("\x1b[58:2::{red}:{green}:{blue}m")),
    }
}

/// Write the parameters of one color: `base` for colors 0 to 7, `bright` for 8 to 15, `extended` for the rest.
fn write_color(out: &mut Vec<u8>, color: Color, base: u8, bright: u8, extended: u8) {
    match color {
        Color::Default => {}
        Color::Index(index @ 0..=7) => write_bytes(out, format_args!(";{}", base + index)),
        Color::Index(index @ 8..=15) => write_bytes(out, format_args!(";{}", bright + index - 8)),
        Color::Index(index) => write_bytes(out, format_args!(";{extended};5;{index}")),
        Color::Rgb(Rgb { red, green, blue }) => write_bytes(out, format_args!(";{extended};2;{red};{green};{blue}")),
    }
}

fn write_bytes(out: &mut Vec<u8>, arguments: std::fmt::Arguments<'_>) {
    if out.write_fmt(arguments).is_err() {
        // Numbers format into a vector with no error.
    }
}

#[cfg(test)]
mod tests;
