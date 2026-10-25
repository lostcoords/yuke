use super::*;

/// A model terminal: it replays the bytes of a render into cells, as a terminal does.
struct Model {
    size: Size,
    cells: Vec<(String, Style)>,
    at: (u16, u16),
    style: Style,
    cursor_visible: bool,
    /// The text that the model drew, without the escape sequences.
    drawn: String,
}

impl Model {
    /// A model whose cells hold `junk`, so a render must write every cell that it claims.
    fn new(size: Size, junk: &str) -> Self {
        let cells = vec![(junk.to_owned(), Style::default()); usize::from(size.columns) * usize::from(size.rows)];
        Self {
            size,
            cells,
            at: (0, 0),
            style: Style::default(),
            cursor_visible: true,
            drawn: String::new(),
        }
    }

    fn replay(&mut self, bytes: &[u8]) {
        let text = std::str::from_utf8(bytes).expect("the render writes UTF-8");
        let mut rest = text;
        while !rest.is_empty() {
            if let Some(sequence) = rest.strip_prefix("\x1b[") {
                let end = sequence
                    .find(|character: char| ('@'..='~').contains(&character))
                    .expect("a final byte");
                self.control(&sequence[..end], &sequence[end..=end]);
                rest = &sequence[end + 1..];
                continue;
            }
            let end = rest.find('\x1b').unwrap_or(rest.len());
            for grapheme in rest[..end].graphemes(true) {
                self.draw(grapheme);
            }
            rest = &rest[end..];
        }
    }

    fn control(&mut self, params: &str, last: &str) {
        match (params, last) {
            ("?25", "l") => self.cursor_visible = false,
            ("?25", "h") => self.cursor_visible = true,
            (_, "H") => {
                let (row, column) = params.split_once(';').expect("row and column");
                self.at = (column.parse::<u16>().unwrap() - 1, row.parse::<u16>().unwrap() - 1);
            }
            (_, "m") => self.select(params),
            _ => {}
        }
    }

    fn select(&mut self, params: &str) {
        if let Some(underline) = params.strip_prefix("58:") {
            let parts: Vec<u8> = underline
                .split(':')
                .filter(|part| !part.is_empty())
                .map(|part| part.parse().unwrap())
                .collect();
            self.style.underline_color = match parts[..] {
                [5, index] => Color::Index(index),
                [2, red, green, blue] => Color::Rgb(Rgb { red, green, blue }),
                _ => panic!("underline color {underline}"),
            };
            return;
        }
        let numbers: Vec<u8> = params.split(';').map(|part| part.parse().unwrap()).collect();
        let mut numbers = numbers.into_iter();
        while let Some(number) = numbers.next() {
            let extended = |numbers: &mut std::vec::IntoIter<u8>| match numbers.next() {
                Some(5) => Color::Index(numbers.next().unwrap()),
                Some(2) => Color::Rgb(Rgb {
                    red: numbers.next().unwrap(),
                    green: numbers.next().unwrap(),
                    blue: numbers.next().unwrap(),
                }),
                other => panic!("extended color {other:?}"),
            };
            match number {
                0 => self.style = Style::default(),
                1 => self.style.attributes = self.style.attributes | Attributes::BOLD,
                2 => self.style.attributes = self.style.attributes | Attributes::DIM,
                3 => self.style.attributes = self.style.attributes | Attributes::ITALIC,
                4 => self.style.attributes = self.style.attributes | Attributes::UNDERLINE,
                7 => self.style.attributes = self.style.attributes | Attributes::REVERSE,
                30..=37 => self.style.fg = Color::Index(number - 30),
                90..=97 => self.style.fg = Color::Index(number - 82),
                40..=47 => self.style.bg = Color::Index(number - 40),
                100..=107 => self.style.bg = Color::Index(number - 92),
                38 => self.style.fg = extended(&mut numbers),
                48 => self.style.bg = extended(&mut numbers),
                _ => panic!("SGR {number}"),
            }
        }
    }

    fn draw(&mut self, grapheme: &str) {
        let (column, row) = self.at;
        let width = u16::try_from(grapheme_width(grapheme)).unwrap();
        assert!(
            column + width <= self.size.columns,
            "{grapheme:?} drawn past the edge at {:?}",
            self.at
        );
        let columns = usize::from(self.size.columns);
        let index = usize::from(row) * columns + usize::from(column);
        // A terminal erases the other half of a wide grapheme that a draw covers in part. "?" marks the erased half,
        // and only a later draw of that cell removes the mark.
        if self.cells[index].0.is_empty() && column > 0 {
            self.cells[index - 1].0 = "?".to_owned();
        }
        let last = index + usize::from(width) - 1;
        if (last + 1) % columns != 0 && self.cells[last + 1].0.is_empty() {
            self.cells[last + 1].0 = "?".to_owned();
        }
        self.cells[index] = (grapheme.to_owned(), self.style);
        if width == 2 {
            self.cells[index + 1] = (String::new(), self.style);
        }
        self.at = (column + width, row);
        self.drawn.push_str(grapheme);
    }

    fn glyphs(&self) -> Vec<&str> {
        self.cells.iter().map(|(text, _)| text.as_str()).collect()
    }

    /// Check that the model cells equal the shown cells of `screen`, with its cursor.
    fn assert_shows(&self, screen: &Screen) {
        for (index, (cell, (text, style))) in screen.shown.iter().zip(&self.cells).enumerate() {
            let expected = std::str::from_utf8(cell.glyph.as_bytes()).unwrap();
            assert_eq!((text.as_str(), *style), (expected, cell.style), "cell {index}");
        }
        assert_eq!(self.cursor_visible, screen.shown_cursor.is_some());
        if let Some(at) = screen.shown_cursor {
            assert_eq!(self.at, at);
        }
    }
}

fn size(columns: u16, rows: u16) -> Size {
    Size { columns, rows }
}

fn render(screen: &mut Screen) -> Vec<u8> {
    let mut out = Vec::new();
    screen.render(&mut out);
    out
}

fn red() -> Style {
    Style {
        fg: Color::Index(1),
        ..Style::default()
    }
}

#[test]
fn an_unchanged_frame_writes_nothing() {
    let mut screen = Screen::new(size(8, 2));
    screen.text(0, 0, "hello", Style::default());
    render(&mut screen);
    screen.clear();
    screen.text(0, 0, "hello", Style::default());
    assert_eq!(render(&mut screen), b"");
}

#[test]
fn a_written_space_on_a_blank_cell_writes_nothing() {
    let mut screen = Screen::new(size(3, 1));
    render(&mut screen);
    screen.text(0, 0, " ", Style::default());
    assert_eq!(render(&mut screen), b"");
}

#[test]
fn the_first_render_writes_every_cell() {
    let mut screen = Screen::new(size(4, 2));
    screen.text(1, 1, "ab", red());
    let mut model = Model::new(size(4, 2), "#");
    model.replay(&render(&mut screen));
    model.assert_shows(&screen);
}

#[test]
fn a_changed_cell_writes_only_that_cell() {
    let mut screen = Screen::new(size(10, 3));
    screen.text(0, 0, "abcdefghij", Style::default());
    let mut model = Model::new(size(10, 3), "#");
    model.replay(&render(&mut screen));
    model.drawn.clear();

    screen.text(4, 0, "X", red());
    model.replay(&render(&mut screen));
    assert_eq!(model.drawn, "X");
    model.assert_shows(&screen);
}

#[test]
fn frames_on_the_terminal_match_the_grid() {
    let mut screen = Screen::new(size(6, 3));
    let mut model = Model::new(size(6, 3), "#");
    let bold = Style {
        attributes: Attributes::BOLD | Attributes::ITALIC,
        ..Style::default()
    };
    let colors = Style {
        fg: Color::Rgb(Rgb {
            red: 1,
            green: 2,
            blue: 3,
        }),
        bg: Color::Index(200),
        underline_color: Color::Index(9),
        attributes: Attributes::UNDERLINE,
    };
    let frames: [&dyn Fn(&mut Screen); 7] = [
        &|screen| {
            screen.text(0, 0, "中文字", Style::default());
            screen.text(0, 1, "abcdef", bold);
        },
        // Narrow text over the second half of a wide grapheme.
        &|screen| {
            screen.text(1, 0, "x", colors);
        },
        // A wide grapheme over the tail of one wide grapheme and the head of the next one.
        &|screen| {
            screen.text(3, 0, "本", red());
        },
        // Wide graphemes over narrow ones.
        &|screen| {
            screen.text(1, 1, "日本", red());
            screen.text(3, 0, "y", Style::default());
        },
        &|screen| {
            screen.fill(1, 0, 2, 3, colors);
            screen.cursor(Some((5, 2)));
        },
        &|screen| {
            screen.clear();
            screen.text(0, 2, "👩\u{200d}🚀🇺🇸z", bold);
        },
        &|screen| {
            screen.text(5, 2, "中", red());
            screen.cursor(None);
        },
    ];
    for frame in frames {
        frame(&mut screen);
        model.replay(&render(&mut screen));
        model.assert_shows(&screen);
    }
}

#[test]
fn a_wide_grapheme_past_the_right_edge_leaves_a_blank() {
    let mut screen = Screen::new(size(3, 1));
    assert_eq!(screen.text(0, 0, "ab中", red()), 3);
    let mut model = Model::new(size(3, 1), "#");
    model.replay(&render(&mut screen));
    assert_eq!(model.glyphs(), ["a", "b", " "]);
    assert_eq!(model.cells[2].1, red());
}

#[test]
fn a_wide_grapheme_at_the_largest_column_fits_no_cell() {
    let mut screen = Screen::new(size(u16::MAX, 1));
    assert_eq!(screen.text(u16::MAX - 1, 0, "中", red()), u16::MAX);
    let mut model = Model::new(size(u16::MAX, 1), "#");
    model.replay(&render(&mut screen));
    assert_eq!(model.glyphs().last(), Some(&" "));
}

#[test]
fn text_drops_control_characters_and_returns_the_column_after_it() {
    let mut screen = Screen::new(size(6, 1));
    assert_eq!(screen.text(1, 0, "a\tb\u{1b}中", Style::default()), 5);
    let mut model = Model::new(size(6, 1), "#");
    model.replay(&render(&mut screen));
    assert_eq!(model.glyphs(), [" ", "a", "b", "中", "", " "]);
}

#[test]
fn a_resize_writes_every_cell() {
    let mut screen = Screen::new(size(4, 1));
    screen.text(0, 0, "abcd", Style::default());
    render(&mut screen);
    screen.resize(size(5, 2));
    screen.text(0, 1, "e", Style::default());
    let mut model = Model::new(size(5, 2), "#");
    model.replay(&render(&mut screen));
    model.assert_shows(&screen);
}

#[test]
fn a_repaint_writes_every_cell_of_the_same_frame() {
    let mut screen = Screen::new(size(3, 1));
    screen.text(0, 0, "abc", Style::default());
    render(&mut screen);
    screen.repaint();
    let mut model = Model::new(size(3, 1), "#");
    model.replay(&render(&mut screen));
    assert_eq!(model.drawn, "abc");
}

#[test]
fn a_moved_cursor_writes_no_cell() {
    let mut screen = Screen::new(size(4, 2));
    screen.text(0, 0, "ab", Style::default());
    let mut model = Model::new(size(4, 2), "#");
    model.replay(&render(&mut screen));
    model.drawn.clear();
    screen.cursor(Some((3, 1)));
    model.replay(&render(&mut screen));
    assert_eq!(model.drawn, "");
    model.assert_shows(&screen);
}

#[test]
fn a_cursor_outside_the_grid_is_hidden() {
    let mut screen = Screen::new(size(4, 2));
    screen.cursor(Some((4, 0)));
    let mut model = Model::new(size(4, 2), "#");
    model.replay(&render(&mut screen));
    assert!(!model.cursor_visible);
}

#[test]
fn a_long_grapheme_renders_whole() {
    let family = "👨\u{200d}👩\u{200d}👧\u{200d}👦";
    let mut screen = Screen::new(size(4, 1));
    screen.text(0, 0, family, Style::default());
    let mut model = Model::new(size(4, 1), "#");
    model.replay(&render(&mut screen));
    assert_eq!(model.drawn, format!("{family}  "));
}
