//! The interface host on a test display: notices in the core, the chat pane, and `/reload` with its snapshot.

use std::io::Write;
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
    started_on(place, display, None).await
}

/// [`started`] with `session` as the session of the startup.
async fn started_on(place: &Place, display: &Arc<Display>, session: Option<SessionId>) -> App {
    let startup = Startup {
        cwd: "/work".to_owned(),
        session,
        model: None,
        reasoning: None,
    };
    let machine = crate::app::Machine {
        interface: Some(Interface {
            display: Arc::clone(display),
            startup,
        }),
        ..place.machine(Box::new(with_key), Box::new(ScriptedTransport::new([])))
    };
    let store = crate::app::open_store(&place.paths.data).await.unwrap();
    let observer = Arc::new(Notices(Arc::clone(display)));
    let (mut app, plugins) = App::prepare(machine, Mode::Server, observer, store, Arc::new(crate::app::TokioTimer))
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

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
async fn the_bundled_chat_checks_its_options_at_the_start_and_at_a_reload() {
    let place = Place::new("tui", "chat_options");
    place.plugin("board", BOARD);
    let config = |copy: &str| {
        let text = format!(r#"{{ "plugins": ["board"], "bundled": {{ "chat": {{ "copyOnRelease": {copy} }} }} }}"#);
        std::fs::write(place.paths.config.join("config.json"), text).unwrap();
    };
    config(r#""no""#);
    let (display, output) = display();
    let mut app = started(&place, &display).await;
    output
        .shows("error host:yuke: plugin chat did not load: TypeError: the options of the plugin: Set copyOnRelease")
        .await;
    // Without the chat, the pane stays empty.
    assert_eq!(output.rows()[1..], ["", "", ""]);

    config("false");
    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;
    output.shows("Message").await;

    config(r#""no""#);
    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;
    output
        .shows(concat!(
            "error host:yuke: the reload failed: the reload keeps the old plugins, because a plugin did not load: ",
            "plugin chat did not load: TypeError: the options of the plugin: Set copyOnRelease"
        ))
        .await;
    app.shutdown().await;
}

/// A saved session of `place` that no app holds open.
async fn saved_session(place: &Place) -> SessionId {
    let (display, _output) = display();
    let app = started(place, &display).await;
    let id = app
        .sessions()
        .create(SessionSettings {
            model: ModelReference {
                provider: "minimax".to_owned(),
                model: "MiniMax-M3".to_owned(),
            },
            settings: yuke_ai::Settings::new(),
            cwd: place.work.clone(),
        })
        .await
        .unwrap();
    app.shutdown().await;
    id
}

/// Wait until the session `id` is open in `app`. A session is closed until a holder opens it.
async fn opened(app: &App, id: SessionId) {
    let opened = tokio::time::timeout(Duration::from_secs(10), async {
        while app.sessions().get(id).await.unwrap().activity != SessionActivity::Idle {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    assert!(opened.is_ok(), "the session {id} did not open");
}

#[tokio::test]
async fn the_start_pane_opens_the_session_of_the_startup() {
    let place = Place::new("tui", "start_session");
    let id = saved_session(&place).await;
    let (display, _output) = display();

    let app = started_on(&place, &display, Some(id)).await;

    opened(&app, id).await;
    app.shutdown().await;
}

/// A test plugin whose root view draws `tui.startup` as JSON.
const STARTUP: &str = "export function apply(ctx) {
  const tui = ctx.get('tui');
  tui.setRoot(() => ({ draw: (canvas) => { canvas.text(0, 0, JSON.stringify(tui.startup)); } }));
}";

#[tokio::test]
async fn a_reload_keeps_the_startup_session_and_reads_the_model_and_the_reasoning_again() {
    let place = Place::new("tui", "startup_config");
    place.plugin("startup", STARTUP);
    let config = |reasoning: &str| {
        let text =
            format!(r#"{{ "plugins": ["startup"], "model": "minimax/MiniMax-M3", "reasoning": "{reasoning}" }}"#);
        std::fs::write(place.paths.config.join("config.json"), text).unwrap();
    };
    let model = r#""model":{"provider":"minimax","model":"MiniMax-M3"}"#;
    config("high");
    let id = saved_session(&place).await;
    let (display, output) = display();
    let mut app = started_on(&place, &display, Some(id)).await;
    // A reload fails while a session opens, so the chat pane ends its open first.
    opened(&app, id).await;
    output
        .shows(&format!(
            r#"{{"cwd":"/work","session":"{id}",{model},"reasoning":"high"}}"#
        ))
        .await;

    config("default");
    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;
    let shown = format!(r#"{{"cwd":"/work","session":"{id}",{model},"reasoning":"default"}}"#);
    output.shows(&shown).await;

    // The model does not take the level low, so the reload keeps the old runtime.
    config("low");
    reload(Some(&mut app), &display, r#"{"tree":null,"focus":0}"#.to_owned()).await;
    assert_eq!(output.rows()[0], shown);
    app.shutdown().await;
}

#[tokio::test]
async fn a_config_model_that_the_providers_do_not_have_stops_the_start() {
    let place = Place::new("tui", "startup_unknown_model");
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("config.json"), r#"{ "model": "nobody/none" }"#).unwrap();
    let store = crate::app::open_store(&place.paths.data).await.unwrap();
    let machine = place.machine(Box::new(with_key), Box::new(ScriptedTransport::new([])));
    let (display, _output) = display();
    let observer = Arc::new(Notices(display));
    let failed = App::prepare(machine, Mode::Server, observer, store, Arc::new(crate::app::TokioTimer)).await;
    assert!(
        failed
            .as_ref()
            .is_err_and(|error| error.starts_with("config.json: model nobody/none: ")),
        "{:?}",
        failed.err()
    );
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
