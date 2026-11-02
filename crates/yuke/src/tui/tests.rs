//! The interface host on a test display: notices in the core, the chat pane, and `/reload` with its snapshot.

use std::io::Write;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use yuke_ai::scripted::ScriptedTransport;
use yuke_js::{Display, Interface, Startup};
use yuke_protocol::{ModelReference, SessionActivity, SessionId, SessionSettings};
use yuke_term::Size;

use super::{Notices, reload};
use crate::app::{App, Mode};
use crate::testing::{Place, with_key};

/// An output that keeps what the frames write.
#[derive(Clone, Default)]
struct Output {
    bytes: Arc<Mutex<Vec<u8>>>,
    flushed: Arc<tokio::sync::Notify>,
}

impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.bytes.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.flushed.notify_one();
        Ok(())
    }
}

impl Output {
    /// The rows of the screen after the frames so far. A frame moves the cursor with `CSI row;column H` between
    /// changed cells; the other escape sequences change no character. Each character fills one cell.
    fn rows(&self) -> Vec<String> {
        let text = String::from_utf8_lossy(&self.bytes.lock().unwrap()).into_owned();
        let mut grid = vec![vec![' '; COLUMNS]; ROWS];
        let (mut row, mut column) = (0, 0);
        let mut rest = text.as_str();
        while let Some(character) = rest.chars().next() {
            if let Some(sequence) = rest.strip_prefix("\x1b[") {
                let end = sequence.find(|found: char| found.is_ascii_alphabetic()).unwrap();
                if sequence[end..].starts_with('H') {
                    let (r, c) = sequence[..end].split_once(';').unwrap();
                    (row, column) = (r.parse::<usize>().unwrap() - 1, c.parse::<usize>().unwrap() - 1);
                }
                rest = &sequence[end + 1..];
            } else {
                if column < COLUMNS {
                    grid[row][column] = character;
                }
                column += 1;
                rest = &rest[character.len_utf8()..];
            }
        }
        grid.into_iter()
            .map(|row| row.into_iter().collect::<String>().trim_end().to_owned())
            .collect()
    }

    /// Wait until a row holds `text`, as a toast at the right does. A toast wraps a long text.
    async fn contains(&self, text: &str) {
        self.until(text, |row| row.contains(text)).await;
    }

    /// Wait until a row of the screen starts with `text`.
    async fn shows(&self, text: &str) {
        self.until(text, |row| row.starts_with(text)).await;
    }

    /// Wait until a row of the screen satisfies `holds`. Each flush of a frame wakes the wait.
    async fn until(&self, text: &str, holds: impl Fn(&str) -> bool) {
        let shown = || self.rows().iter().any(|row| holds(row));
        let waited = tokio::time::timeout(Duration::from_secs(10), async {
            while !shown() {
                self.flushed.notified().await;
            }
        })
        .await;
        assert!(
            waited.is_ok() && shown(),
            "the screen does not show {text:?}: {:#?}",
            self.rows()
        );
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
    started_on(place, display, None).await
}

/// [`started`] with `session` as the session of the startup.
async fn started_on(place: &Place, display: &Arc<Display>, session: Option<SessionId>) -> App {
    let startup = Startup {
        cwd: "/work".to_owned(),
        session,
    };
    let machine = crate::app::Machine {
        interface: Some(Interface {
            display: Arc::clone(display),
            startup,
        }),
        ..place.machine(Box::new(with_key), Box::new(ScriptedTransport::new([])))
    };
    let store = crate::app::open_store(&place.paths.data).await.unwrap();
    let observer = Rc::new(Notices(Arc::clone(display)));
    let (mut app, plugins) = App::prepare(machine, Mode::Server, observer, store, Rc::new(crate::app::TokioTimer))
        .await
        .unwrap();
    app.show(None);
    app.load_plugins(&plugins).await;
    app
}

/// A test plugin whose root view draws the newest notice on the first row and the panes below it. The views of yuke
/// draw no notice until the toasts come.
const BOARD: &str = "export function apply(ctx) {
  const tui = ctx.get('tui');
  tui.setRoot(() => ({
    layout: (size) => [{ view: tui.panes.view, rect: { column: 0, row: 1, width: size.width, height: size.height - 1 } }],
    draw: (canvas) => {
      const notice = tui.notices.list().at(-1);
      if (notice !== undefined) canvas.text(0, 0, `${notice.level} ${notice.source}: ${notice.text}`);
    },
  }));
}";

#[tokio::test(flavor = "local")]
async fn the_console_of_a_plugin_reaches_the_screen_as_a_notice() {
    let place = Place::new("tui", "console_notice");
    place.plugin("board", BOARD);
    place.plugin(
        "talker",
        "export function apply() { console.info('hello from a plugin'); }",
    );
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "plugins": ["board", "talker"] }"#,
    )
    .unwrap();
    let (display, output) = display();

    let app = started(&place, &display).await;

    output.shows("info console: hello from a plugin").await;
    app.shutdown().await;
}

/// A plugin with the view type `note`: a pane that shows its id.
const NOTES: &str = "export function apply(ctx) {
  const tui = ctx.get('tui');
  if (tui === undefined) return;
  // One surface per plugin: a second call gives the same one.
  if (ctx.get('tui') !== tui) throw new Error('two surfaces');
  tui.views.register('note', (state) => ({
    draw: (canvas) => { canvas.text(0, 0, `note ${state.id}`); },
    snapshot: () => ({ type: 'note', state }),
  }));
}";

#[tokio::test(flavor = "local")]
async fn a_plugin_pane_comes_back_after_a_reload() {
    let place = Place::new("tui", "reload_snapshot");
    place.plugin("notes", NOTES);
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["notes"] }"#).unwrap();
    let (display, output) = display();
    let mut app = started(&place, &display).await;
    // The bundled chat gives the first pane after the start event.
    output.shows("Message").await;

    let snapshot = r#"{"tree":{"type":"notes:note","state":{"id":4}},"focus":0}"#;
    reload(Some(&mut app), &display, snapshot.to_owned()).await;

    output.shows("note 4").await;
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_failed_reload_keeps_the_old_runtime_and_shows_a_notice() {
    let place = Place::new("tui", "reload_failure");
    let (display, output) = display();
    place.plugin("board", BOARD);
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["board"] }"#).unwrap();
    let mut app = started(&place, &display).await;
    place.plugin("broken", "throw new Error('broken on purpose');");
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["broken"] }"#).unwrap();

    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;

    // The new plugins have no board, so the notice on the screen comes from the old runtime.
    output
        .shows("error host:yuke: the reload failed: the reload keeps the old plugins")
        .await;
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn the_bundled_sessions_list_opens_through_the_service_of_the_bundled_chat() {
    let place = Place::new("tui", "sessions_list");
    place.plugin(
        "opener",
        "export function apply(ctx) { const tui = ctx.get('tui'); setTimeout(() => tui.commands.run('sessions:open'), 0); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["opener"] }"#).unwrap();
    let (display, output) = display();

    let app = started(&place, &display).await;

    // The screen of the test reads bytes, so it matches the ASCII start of the head row: the folder of the list.
    // The footer of the sessions dialog names the other scope.
    output.shows(" tab: every folder").await;
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_bundled_plugin_checks_its_options_at_the_start_and_at_a_reload() {
    let place = Place::new("tui", "bundled_options");
    // The item shows only in the bar, so it shows that the bar loaded.
    place.plugin(
        "marker",
        "export function apply(ctx) { ctx.get('tui').status.set('marker', { text: 'marked', side: 'left' }); }",
    );
    let config = |hide: &str| {
        let text = format!(
            r#"{{ "plugins": ["marker"], "disable": ["sessions"], "bundled": {{ "bar": {{ "hide": {hide} }} }} }}"#
        );
        std::fs::write(place.paths.config.join("config.json"), text).unwrap();
    };
    config(r#""no""#);
    let (display, output) = display();
    let mut app = started(&place, &display).await;
    output.contains("plugin bar did not load").await;
    assert!(
        output.rows().iter().all(|row| !row.contains("marked")),
        "{:?}",
        output.rows()
    );

    config("[]");
    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;
    output.contains("marked").await;

    config(r#""no""#);
    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;
    output.contains("the reload failed").await;
    // The old runtime keeps its bar.
    output.contains("marked").await;
    app.shutdown().await;
}

/// A saved session of `place` that no app holds open.
async fn saved_session(place: &Place) -> SessionId {
    let (display, _output) = display();
    let app = started(place, &display).await;
    let id = app
        .sessions()
        .create(
            SessionSettings {
                model: ModelReference {
                    provider: "minimax".to_owned(),
                    model: "MiniMax-M3".to_owned(),
                },
                settings: yuke_ai::Settings::new(),
                cwd: place.work.clone(),
            },
            None,
        )
        .await
        .unwrap();
    app.shutdown().await;
    id
}

#[tokio::test(flavor = "local")]
async fn the_start_pane_opens_the_session_of_the_startup() {
    let place = Place::new("tui", "start_session");
    let id = saved_session(&place).await;
    place.plugin(
        "opened",
        "export function apply(ctx) { ctx.on('session.opened', (data) => console.info(`opened ${data.sessionId}`)); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["opened"] }"#).unwrap();
    let (display, output) = display();

    let app = started_on(&place, &display, Some(id)).await;

    output.contains(&format!("opened {id}")).await;
    assert_eq!(app.sessions().get(id).await.unwrap().activity, SessionActivity::Idle);
    app.shutdown().await;
}

/// A test plugin whose root view draws `tui.startup` as JSON.
const STARTUP: &str = "export function apply(ctx) {
  const tui = ctx.get('tui');
  tui.setRoot(() => ({ draw: (canvas) => { canvas.text(0, 0, JSON.stringify(tui.startup)); } }));
}";

#[tokio::test(flavor = "local")]
async fn the_startup_gives_the_folder_and_the_session_of_the_start() {
    let place = Place::new("tui", "startup_config");
    place.plugin("startup", STARTUP);
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["startup"] }"#).unwrap();
    let id = saved_session(&place).await;
    let (display, output) = display();
    let app = started_on(&place, &display, Some(id)).await;
    output.shows(&format!(r#"{{"cwd":"/work","session":"{id}"}}"#)).await;
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
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
