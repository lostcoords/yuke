//! The terminal interface: `yuke` with no `-p`. The terminal and its display live here, so they outlive a reload of
//! the plugins. The plugin runtime imports `yuke:internal/tui`, which draws on the display.

use std::io;
use std::sync::Arc;

use tokio::signal::unix::{Signal, SignalKind, signal};
use tokio::sync::{Notify, mpsc};
use yuke_engine::{CancellationToken, chain_text};
use yuke_js::{Display, Input, Request};
use yuke_protocol::{NoticeLevel, NoticeParams, ServerNotification};
use yuke_term::Terminal;

use crate::app::{App, Machine, Mode, Observer, SOURCE, warn};

/// Gives each notice to the display. The interface shows no session update yet.
struct Notices(Arc<Display>);

impl Observer for Notices {
    fn notify(&self, notification: ServerNotification) {
        match notification {
            ServerNotification::Notice(notice) => self.0.send(Input::Notice(notice)),
            ServerNotification::SessionUpdate(_) | ServerNotification::LoginFinished(_) => {}
        }
    }
}

/// Run the interface on the terminal of the process until a quit or `shutdown`. The drop of the terminal restores
/// the device, also on an error. Then the notices that no frame loop took go to stderr.
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
        display: Arc::clone(&display),
        requests,
        resizes,
        ended: Arc::new(Notify::new()),
    };
    let ended = serve(&mut host, machine, &shutdown).await;
    drop(host);
    for notice in display.take_notices() {
        warn(&format!("{}: {}", notice.source, notice.message));
    }
    ended
}

/// Start the app on the display of `host`, and serve the host until a quit or `shutdown`.
async fn serve(host: &mut Host, machine: Machine, shutdown: &CancellationToken) -> Result<(), String> {
    host.start_reader()
        .map_err(|error| format!("the terminal input: {error}"))?;
    let machine = Machine {
        display: Some(Arc::clone(&host.display)),
        ..machine
    };
    let observer = Arc::new(Notices(Arc::clone(&host.display)));
    let (mut app, plugins) = App::prepare(machine, Mode::Server, observer).await?;
    app.show(None);
    // The host answers quit and suspend while the plugins load. A quit drops the load, so a slow plugin does not hold
    // the terminal, and the app shuts down before the terminal restores.
    let ended = tokio::select! {
        () = app.load_plugins(&plugins) => host.serve(shutdown, Some(&mut app)).await,
        ended = host.serve(shutdown, None) => ended,
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
    /// Without `app`, while the first plugins load, a reload gives a notice.
    async fn serve(&mut self, shutdown: &CancellationToken, mut app: Option<&mut App>) -> Result<(), String> {
        loop {
            let answered = tokio::select! {
                () = shutdown.cancelled() => return Ok(()),
                // The host keeps the display, so the requests never end.
                request = self.requests.recv() => match request {
                    Some(Request::Quit) | None => return Ok(()),
                    Some(Request::Suspend) => self.suspend(),
                    Some(Request::Reload(snapshot)) => {
                        // A quit drops the reload, as it drops the first load, and the app shuts down after it.
                        tokio::select! {
                            () = reload(app.as_deref_mut(), &self.display, snapshot) => Ok(()),
                            () = shutdown.cancelled() => return Ok(()),
                            () = quit(&mut self.requests) => return Ok(()),
                        }
                    }
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

/// Wait for a quit or the end of `requests`. The other requests go, so a second ctrl+r during a reload does nothing.
async fn quit(requests: &mut mpsc::UnboundedReceiver<Request>) {
    while let Some(request) = requests.recv().await {
        match request {
            Request::Quit => return,
            Request::Suspend | Request::Reload(_) => {}
        }
    }
}

/// Load the plugins of `app` again, and show the new runtime with `snapshot`. A failure keeps the old runtime and gives
/// `display` a notice. The old runtime draws until it stops.
async fn reload(app: Option<&mut App>, display: &Display, snapshot: String) {
    let failure = match app {
        Some(app) => match app.reload().await {
            Ok(()) => {
                app.show(Some(snapshot));
                return;
            }
            Err(error) => chain_text(&error),
        },
        None => "yuke is still loading the plugins".to_owned(),
    };
    display.send(Input::Notice(NoticeParams {
        session_id: None,
        level: NoticeLevel::Error,
        source: SOURCE.to_owned(),
        message: format!("the reload failed: {failure}"),
    }));
}

#[cfg(test)]
mod tests;
