//! The display of the terminal interface: the cell grid, its output, and the queues between the host and the
//! JavaScript. The host owns it, so it outlives a reload: each new runtime draws on the same display.

use std::collections::VecDeque;
use std::fmt;
use std::io::Write;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use serde::Serialize;
use tokio::sync::{Notify, mpsc};
use yuke_protocol::{NoticeParams, SessionId};
use yuke_term::{Event, Rgb, Screen, Size};

/// The terminal interface of a runtime: the display, and how yuke started. Give each runtime of a reload the same
/// display.
#[derive(Debug, Clone)]
pub struct Interface {
    /// The display that the frames draw on.
    pub display: Arc<Display>,
    /// The value of `tui.startup`.
    pub startup: Startup,
}

/// How the terminal interface started: the value of `tui.startup`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Startup {
    /// The folder that yuke started in.
    pub cwd: String,
    /// The session of `--continue` or `--session`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionId>,
}

/// What the host gives the display.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    /// An event of the terminal.
    Event(Event),
    /// The terminal has this size, or its content is unknown, as after a suspend. The next frame writes every cell.
    Resize(Size),
    /// A notice of the host or of a plugin, for the user.
    Notice(NoticeParams),
}

/// What the JavaScript asks of the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// `term.quit()` ran.
    Quit,
    /// `term.suspend()` ran: give the terminal to the shell until the shell resumes yuke.
    Suspend,
    /// `term.reload(snapshot)` ran: load the plugins again, and give `snapshot` to the start event of the new runtime.
    Reload(String),
}

/// The cell grid of the terminal interface, its output, the queue of [`Input`], and the sender of [`Request`]. Give it
/// to the runtimes in [`Options::interface`](crate::Options::interface).
pub struct Display {
    frame: Mutex<Frame>,
    inputs: Mutex<VecDeque<Input>>,
    /// A new input wakes the frame loop of the runtime.
    pub(crate) arrived: Notify,
    requests: mpsc::UnboundedSender<Request>,
}

/// The light or dark class of a terminal background.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Scheme {
    /// Light text on a dark background.
    Dark,
    /// Dark text on a light background.
    Light,
}

/// The state that each frame reads and draws.
pub(crate) struct Frame {
    pub(crate) screen: Screen,
    pub(crate) output: Box<dyn Write + Send>,
    /// The buffer of a render, kept from frame to frame.
    pub(crate) bytes: Vec<u8>,
    pub(crate) scheme: Scheme,
    pub(crate) truecolor: bool,
    pub(crate) tmux: bool,
}

impl fmt::Debug for Display {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Display").finish_non_exhaustive()
    }
}

impl Display {
    /// A display of `size` that writes its frames to `output`, and the one receiver of the requests of the
    /// JavaScript. `background` is the color of the probe; without one, the scheme is dark.
    /// `truecolor` says that the terminal draws 24-bit color, and `tmux` that a copy also needs the tmux passthrough.
    pub fn new(
        size: Size,
        output: Box<dyn Write + Send>,
        background: Option<Rgb>,
        truecolor: bool,
        tmux: bool,
    ) -> (Arc<Self>, mpsc::UnboundedReceiver<Request>) {
        let (requests, received) = mpsc::unbounded_channel();
        let display = Arc::new(Self {
            frame: Mutex::new(Frame {
                screen: Screen::new(size),
                output,
                bytes: Vec::new(),
                scheme: background.map_or(Scheme::Dark, scheme_of),
                truecolor,
                tmux,
            }),
            inputs: Mutex::default(),
            arrived: Notify::new(),
            requests,
        });
        (display, received)
    }

    /// Give `input` to the frame loop. A call from any thread works.
    pub fn send(&self, input: Input) {
        lock(&self.inputs).push_back(input);
        self.arrived.notify_one();
    }

    /// Run `f` while no frame and no copy writes, such as a write of the host to the terminal. A frame waits for `f`,
    /// so its escape sequences do not mix with those of `f`.
    pub fn hold<R>(&self, f: impl FnOnce() -> R) -> R {
        let _frame = self.frame();
        f()
    }

    /// Take the notices that no frame loop took, such as those of the shutdown, and drop the other inputs.
    pub fn take_notices(&self) -> Vec<NoticeParams> {
        self.take_inputs()
            .into_iter()
            .filter_map(|input| match input {
                Input::Notice(notice) => Some(notice),
                Input::Event(_) | Input::Resize(_) => None,
            })
            .collect()
    }

    pub(crate) fn ask(&self, request: Request) {
        if self.requests.send(request).is_err() {
            // The host dropped the receiver, so it answers no request.
        }
    }

    pub(crate) fn take_inputs(&self) -> VecDeque<Input> {
        std::mem::take(&mut *lock(&self.inputs))
    }

    pub(crate) fn frame(&self) -> MutexGuard<'_, Frame> {
        lock(&self.frame)
    }
}

/// The class of a background color. A color below half of the full BT.601 luma is dark, as in Neovim.
pub(crate) fn scheme_of(color: Rgb) -> Scheme {
    let luma = 299 * u32::from(color.red) + 587 * u32::from(color.green) + 114 * u32::from(color.blue);
    if luma * 2 < 1000 * 255 {
        Scheme::Dark
    } else {
        Scheme::Light
    }
}

/// Lock `mutex`. A panic of another holder leaves state that a frame can still read, so a poisoned lock goes on.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
