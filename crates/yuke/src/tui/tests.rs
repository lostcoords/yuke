//! The interface host on a test display: notices on the screen, and `/reload` with its snapshot.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use yuke_js::Display;
use yuke_term::Size;
use yuke_testing::ScriptedTransport;

use super::{Notices, reload};
use crate::app::{App, Mode};
use crate::testing::{Place, with_key};

/// An output that keeps what the frames write.
#[derive(Clone, Default)]
struct Output(Arc<Mutex<Vec<u8>>>);

impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Output {
    /// The rows of the screen after the frames so far. A frame moves the cursor with `CSI row;column H` between the
    /// changed cells; the other escape sequences change no character. Each test writes ASCII only.
    fn rows(&self) -> Vec<String> {
        let bytes = self.0.lock().unwrap().clone();
        let mut grid = vec![vec![' '; COLUMNS]; ROWS];
        let (mut row, mut column) = (0, 0);
        let mut at = 0;
        while at < bytes.len() {
            if bytes[at] == 0x1b && bytes.get(at + 1) == Some(&b'[') {
                let end = at + 2 + bytes[at + 2..].iter().position(u8::is_ascii_alphabetic).unwrap();
                if bytes[end] == b'H' {
                    let place = std::str::from_utf8(&bytes[at + 2..end]).unwrap();
                    let (r, c) = place.split_once(';').unwrap();
                    (row, column) = (r.parse::<usize>().unwrap() - 1, c.parse::<usize>().unwrap() - 1);
                }
                at = end + 1;
            } else {
                if column < COLUMNS {
                    grid[row][column] = char::from(bytes[at]);
                }
                column += 1;
                at += 1;
            }
        }
        grid.into_iter()
            .map(|row| row.into_iter().collect::<String>().trim_end().to_owned())
            .collect()
    }

    /// Wait until a row of the screen starts with `text`.
    async fn shows(&self, text: &str) {
        let waited = tokio::time::timeout(Duration::from_secs(10), async {
            while !self.rows().iter().any(|row| row.starts_with(text)) {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await;
        assert!(waited.is_ok(), "the screen does not show {text:?}: {:#?}", self.rows());
    }
}

const COLUMNS: usize = 200;
const ROWS: usize = 4;

/// A wide display, so a notice fits on its row.
fn display() -> (Arc<Display>, Output) {
    let output = Output::default();
    let (display, _requests) = Display::new(
        Size {
            columns: u16::try_from(COLUMNS).unwrap(),
            rows: u16::try_from(ROWS).unwrap(),
        },
        Box::new(output.clone()),
        None,
        true,
        false,
    );
    (display, output)
}

/// Start the app of `place` on `display` as the interface does: show the runtime, then load the plugins.
async fn started(place: &Place, display: &Arc<Display>) -> App {
    let machine = crate::app::Machine {
        display: Some(Arc::clone(display)),
        ..place.machine(Box::new(with_key), Box::new(ScriptedTransport::new([])))
    };
    let (mut app, plugins) = App::prepare(machine, Mode::Server, Arc::new(Notices(Arc::clone(display))))
        .await
        .unwrap();
    app.show(None);
    app.load_plugins(&plugins).await;
    app
}

#[tokio::test]
async fn the_console_of_a_plugin_reaches_the_screen_as_a_notice() {
    let place = Place::new("tui", "console_notice");
    place.plugin(
        "talker",
        "export function apply() { console.info('hello from a plugin'); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["talker"] }"#).unwrap();
    let (display, output) = display();

    let app = started(&place, &display).await;

    output.shows("info console: hello from a plugin").await;
    app.shutdown().await;
}

#[tokio::test]
async fn a_reload_shows_the_new_runtime_with_the_snapshot() {
    let place = Place::new("tui", "reload_snapshot");
    let (display, output) = display();
    let mut app = started(&place, &display).await;
    output.shows("yuke 200x4 dark reloads 0").await;

    reload(Some(&mut app), &display, r#"{"reloads":4}"#.to_owned()).await;

    output.shows("yuke 200x4 dark reloads 4").await;
    app.shutdown().await;
}

#[tokio::test]
async fn a_failed_reload_keeps_the_old_runtime_and_shows_a_notice() {
    let place = Place::new("tui", "reload_failure");
    let (display, output) = display();
    let mut app = started(&place, &display).await;
    output.shows("yuke 200x4 dark reloads 0").await;
    place.plugin("broken", "throw new Error('broken on purpose');");
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["broken"] }"#).unwrap();

    reload(Some(&mut app), &display, r#"{"reloads":1}"#.to_owned()).await;

    // Only the old runtime draws, so the notice on the screen comes from it.
    output
        .shows("error host:yuke: the reload failed: the reload keeps the old plugins")
        .await;
    assert_eq!(output.rows()[0], "yuke 200x4 dark reloads 0");
    app.shutdown().await;
}

#[tokio::test]
async fn a_reload_while_the_first_plugins_load_gives_a_notice() {
    let (display, _output) = display();

    reload(None, &display, "{}".to_owned()).await;

    let messages: Vec<String> = display
        .take_notices()
        .into_iter()
        .map(|notice| notice.message)
        .collect();
    assert_eq!(messages, ["the reload failed: yuke is still loading the plugins"]);
}
