//! Show the background color of the terminal and each event. Run
//! `mise exec -- cargo run -p yuke-term --example events`, and press ctrl+c to quit.

use std::io;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;

use yuke_term::{Attributes, Code, Event, Modifiers, Screen, Style, Terminal};

fn main() -> io::Result<()> {
    let mut terminal = Terminal::open()?;
    let (send, events) = mpsc::channel();
    terminal.start_reader(
        move |event| {
            if send.send(event).is_err() {
                // The main loop ended, so no one shows the event.
            }
        },
        || {},
    )?;
    let mut screen = Screen::new(terminal.size()?);
    let mut background = terminal.background();
    let mut lines: Vec<String> = Vec::new();
    let mut out = Vec::new();
    let bold = Style {
        attributes: Attributes::BOLD,
        ..Style::default()
    };
    loop {
        let size = terminal.size()?;
        if size != screen.size() {
            screen.resize(size);
        }
        screen.clear();
        screen.text(0, 0, &format!("background {background:?}  (ctrl+c quits)"), bold);
        for (row, line) in (1..size.rows).zip(lines.iter().rev()) {
            screen.text(0, row, line, Style::default());
        }
        out.clear();
        screen.render(&mut out);
        terminal.write_all(&out)?;

        match events.recv_timeout(Duration::from_millis(100)) {
            Ok(Event::Key(key)) if key.code == Code::Char('c') && key.modifiers.contains(Modifiers::CTRL) => break,
            Ok(event) => {
                match event {
                    Event::SchemeChanged => terminal.query_background()?,
                    Event::Background(color) => background = Some(color),
                    _ => {}
                }
                lines.push(format!("{event:?}"));
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        if lines.len() > 500 {
            lines.drain(..250);
        }
    }
    terminal.stop_reader()
}
