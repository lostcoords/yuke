//! The terminal interface: `yuke` with no `-p`. The terminal and its display live here, so they outlive a reload of
//! the plugins. The plugin runtime imports `yuke:internal/tui`, which draws on the display.

use std::io;
use std::sync::Arc;

use tokio::signal::unix::{Signal, SignalKind, signal};
use yuke_engine::{CancellationToken, chain_text};
use yuke_js::{Display, Input, Request};
use yuke_protocol::ServerNotification;
use yuke_term::Terminal;

use crate::app::{App, Machine, Mode, Observer};

/// Drops each notification: the interface shows none yet.
struct NoView;

impl Observer for NoView {
    fn notify(&self, _notification: ServerNotification) {}
}

/// Run the interface on the terminal of the process until a quit or `shutdown`. The drop of the terminal restores
/// the device, also on an error.
pub(crate) async fn run(machine: Machine, shutdown: CancellationToken) -> Result<(), String> {
    let failed = |what: &'static str| move |error: io::Error| format!("{what}: {error}");
    // The stream registers before the app starts, so a resize while the app starts wakes the loop later.
    let mut resizes = signal(SignalKind::window_change()).map_err(failed("SIGWINCH"))?;
    let mut terminal = Terminal::open().map_err(failed("the terminal did not open"))?;
    let truecolor = matches!(std::env::var("COLORTERM").as_deref(), Ok("truecolor" | "24bit"));
    let tmux = std::env::var_os("TMUX").is_some();
    let display = Display::new(
        terminal.size().map_err(failed("the terminal size"))?,
        Box::new(terminal.writer().map_err(failed("the terminal output"))?),
        terminal.background(),
        truecolor,
        tmux,
    );
    start_reader(&mut terminal, &display).map_err(failed("the terminal input"))?;
    let machine = Machine {
        display: Some(Arc::clone(&display)),
        ..machine
    };
    let app = App::start(machine, Mode::Server, Arc::new(NoView)).await?;
    let ended = serve(&mut terminal, &display, &mut resizes, &shutdown).await;
    app.shutdown().await;
    ended
}

/// Answer the requests of the JavaScript and pass each resize, until a quit or `shutdown`.
async fn serve(
    terminal: &mut Terminal,
    display: &Arc<Display>,
    resizes: &mut Signal,
    shutdown: &CancellationToken,
) -> Result<(), String> {
    loop {
        let answered = tokio::select! {
            () = shutdown.cancelled() => return Ok(()),
            request = display.request() => match request {
                Request::Quit => return Ok(()),
                Request::Suspend => suspend(terminal, display),
            },
            _ = resizes.recv() => terminal.size().map(|size| display.send(Input::Resize(size))),
        };
        answered.map_err(|error| format!("the terminal: {}", chain_text(&error)))?;
    }
}

/// Give the terminal to the shell. When the shell resumes yuke, read the terminal again and redraw every cell: the
/// size can be new, because a stopped process gets no SIGWINCH.
fn suspend(terminal: &mut Terminal, display: &Arc<Display>) -> io::Result<()> {
    display.hold(|| terminal.suspend())?;
    start_reader(terminal, display)?;
    display.send(Input::Resize(terminal.size()?));
    Ok(())
}

fn start_reader(terminal: &mut Terminal, display: &Arc<Display>) -> io::Result<()> {
    let display = Arc::clone(display);
    terminal.start_reader(move |event| display.send(Input::Event(event)))
}
