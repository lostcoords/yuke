//! The terminal interface: `yuke` with no `-p`. The terminal and its display live here, so they outlive a reload of
//! the plugins. The plugin runtime imports `yuke:internal/tui`, which draws on the display.

use std::io;
use std::sync::Arc;

use tokio::signal::unix::{Signal, SignalKind, signal};
use tokio::sync::{Notify, mpsc};
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
    let resizes = signal(SignalKind::window_change()).map_err(failed("SIGWINCH"))?;
    let terminal = Terminal::open().map_err(failed("the terminal did not open"))?;
    let truecolor = matches!(std::env::var("COLORTERM").as_deref(), Ok("truecolor" | "24bit"));
    let tmux = std::env::var_os("TMUX").is_some();
    let (display, requests) = Display::new(
        terminal.size().map_err(failed("the terminal size"))?,
        Box::new(terminal.writer().map_err(failed("the terminal output"))?),
        terminal.background(),
        truecolor,
        tmux,
    );
    let mut host = Host {
        terminal,
        display,
        requests,
        resizes,
        ended: Arc::new(Notify::new()),
    };
    host.start_reader().map_err(failed("the terminal input"))?;
    let machine = Machine {
        display: Some(Arc::clone(&host.display)),
        ..machine
    };
    let (app, plugins) = App::prepare(machine, Mode::Server, Arc::new(NoView)).await?;
    // The host answers quit and suspend while the plugins load. A quit drops the load, so a slow plugin does not hold
    // the terminal, and the app shuts down before the terminal restores.
    let ended = tokio::select! {
        () = app.load_plugins(&plugins) => host.serve(&shutdown).await,
        ended = host.serve(&shutdown) => ended,
    };
    app.shutdown().await;
    ended
}

/// The terminal, its display, and the things that the loop of the host waits for.
struct Host {
    terminal: Terminal,
    display: Arc<Display>,
    requests: mpsc::UnboundedReceiver<Request>,
    resizes: Signal,
    /// The current reader wakes it when the input ends. Each reader gets a new one, so a late wake of a stopped reader
    /// stops no later reader.
    ended: Arc<Notify>,
}

impl Host {
    /// Answer the requests of the JavaScript and pass each resize, until a quit, the end of the input, or `shutdown`.
    async fn serve(&mut self, shutdown: &CancellationToken) -> Result<(), String> {
        loop {
            let answered = tokio::select! {
                () = shutdown.cancelled() => return Ok(()),
                // The host keeps the display, so the requests never end.
                request = self.requests.recv() => match request {
                    Some(Request::Quit) | None => return Ok(()),
                    Some(Request::Suspend) => self.suspend(),
                },
                () = self.ended.notified() => return Err(match self.terminal.stop_reader() {
                    Ok(()) => "the terminal input ended".to_owned(),
                    Err(error) => format!("the terminal input: {}", chain_text(&error)),
                }),
                _ = self.resizes.recv() => self.terminal.size().map(|size| self.display.send(Input::Resize(size))),
            };
            answered.map_err(|error| format!("the terminal: {}", chain_text(&error)))?;
        }
    }

    /// Give the terminal to the shell. When the shell resumes yuke, read the terminal again and redraw every cell: the
    /// size can be new, because a stopped process gets no SIGWINCH.
    fn suspend(&mut self) -> io::Result<()> {
        self.display.hold(|| self.terminal.suspend())?;
        self.start_reader()?;
        self.display.send(Input::Resize(self.terminal.size()?));
        Ok(())
    }

    fn start_reader(&mut self) -> io::Result<()> {
        let display = Arc::clone(&self.display);
        self.ended = Arc::new(Notify::new());
        let ended = Arc::clone(&self.ended);
        self.terminal.start_reader(
            move |event| display.send(Input::Event(event)),
            move || ended.notify_one(),
        )
    }
}
