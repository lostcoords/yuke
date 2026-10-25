//! The terminal device in raw mode on the alternate screen, and its probe.

use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io::{self, Write as _};
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt as _;
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags};
use rustix::termios::{self, OptionalActions, QueueSelector, Termios};

use crate::event::{Event, Rgb};
use crate::parser::{Answer, Parsed, Parser};
use crate::reader::{Reader, read_input, wait};
use crate::screen::Size;

/// The alternate screen, bracketed paste, button and motion mouse reports in SGR form, focus reports, color scheme
/// reports, and kitty keys with the disambiguate and alternate-key flags. A terminal ignores each mode that it does
/// not know.
const ENTER: &[u8] = b"\x1b[?1049h\x1b[?2004h\x1b[?1002;1004;1006h\x1b[?2031h\x1b[>5u";

/// The OSC 11 query of the background color. The answer is an [`Event::Background`].
pub const BACKGROUND_QUERY: &[u8] = b"\x1b]11;?\x1b\\";

/// After the background query: the kitty keyboard flags and the primary device attributes. A terminal answers in
/// order, so the device attributes end the probe.
const PROBE: &[u8] = b"\x1b[?u\x1b[c";

/// The longest wait for the probe answers, as in the Zig yuke. A real terminal answers in a few milliseconds.
const PROBE_TIMEOUT: Duration = Duration::from_millis(100);

/// The terminal device in raw mode. A drop tries to turn off each mode that the terminal turned on and to restore the
/// saved settings.
#[derive(Debug)]
#[must_use = "a drop of the terminal restores the device at once"]
pub struct Terminal {
    file: File,
    saved: Termios,
    background: Option<Rgb>,
    modify_other_keys: bool,
    /// The parser of the probe and the input that came during the probe, for the first reader.
    early: Option<(Parser, Vec<Event>)>,
    reader: Option<Reader>,
}

impl Terminal {
    /// Open the terminal of the process: enter raw mode and the alternate screen, and probe the terminal. The wait for
    /// the answers ends 100 ms after the probe, and a busy system can add to it. Then the call turns on xterm
    /// modifyOtherKeys unless the terminal reports kitty flags.
    ///
    /// # Errors
    ///
    /// Returns the error of the system when no terminal device opens, a setting fails, or a write fails.
    pub fn open() -> io::Result<Self> {
        Self::from_file(device()?)
    }

    /// [`Terminal::open`] on `file`, a terminal device.
    fn from_file(file: File) -> io::Result<Self> {
        let saved = termios::tcgetattr(&file)?;
        let mut terminal = Self {
            file,
            saved,
            background: None,
            modify_other_keys: false,
            early: None,
            reader: None,
        };
        terminal.enter()?;
        terminal.write_all(BACKGROUND_QUERY)?;
        terminal.write_all(PROBE)?;
        terminal.probe()?;
        Ok(terminal)
    }

    /// The background color that the probe found. It is `None` when the terminal did not answer in time. A later
    /// answer to [`BACKGROUND_QUERY`] comes as an [`Event::Background`] and does not change this value.
    pub fn background(&self) -> Option<Rgb> {
        self.background
    }

    /// The size of the terminal.
    ///
    /// # Errors
    ///
    /// Returns the error of the system when the device does not report its size.
    pub fn size(&self) -> io::Result<Size> {
        let size = termios::tcgetwinsize(&self.file)?;
        Ok(Size {
            columns: size.ws_col,
            rows: size.ws_row,
        })
    }

    /// Write `bytes` to the terminal, such as the output of [`Screen::render`](crate::Screen::render).
    ///
    /// # Errors
    ///
    /// Returns the error of the write.
    pub fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
        (&self.file).write_all(bytes)
    }

    /// Read the answers until the device attributes come or the timeout ends, and turn on the modes that they allow.
    /// The parser and the other input stay for the first reader, so no typed key gets lost.
    fn probe(&mut self) -> io::Result<()> {
        let deadline = Instant::now() + PROBE_TIMEOUT;
        let mut parser = Parser::new();
        let mut early = Vec::new();
        let (mut kitty_keyboard, mut complete) = (false, false);
        let mut buffer = [0; 4096];
        while !complete {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            let mut fds = [PollFd::new(&self.file, PollFlags::IN)];
            wait(&mut fds, Some(left))?;
            if fds[0].revents().is_empty() {
                continue;
            }
            let Some(read) = read_input(&self.file, &mut buffer)? else {
                break;
            };
            for parsed in parser.feed(&buffer[..read]) {
                match parsed {
                    // An answer after the last one is late and changes nothing.
                    Parsed::Answer(_) if complete => {}
                    Parsed::Event(Event::Background(color)) => self.background = Some(color),
                    Parsed::Event(event) => early.push(event),
                    Parsed::Answer(Answer::KittyKeyboard(flags)) => kitty_keyboard = flags != 0,
                    Parsed::Answer(Answer::DeviceAttributes) => complete = true,
                }
            }
        }
        if !kitty_keyboard {
            self.write_all(b"\x1b[>4;2m")?;
            self.modify_other_keys = true;
        }
        self.early = Some((parser, early));
        Ok(())
    }

    /// A second handle of the device, for writes from another thread, such as the frames of a
    /// [`Screen`](crate::Screen).
    ///
    /// # Errors
    ///
    /// Returns the error of the system when the handle does not open.
    pub fn writer(&self) -> io::Result<File> {
        self.file.try_clone()
    }

    /// Give the device back to the shell and stop the process group, as ctrl+z does in a shell. The call returns when
    /// the shell resumes the process: then the device is raw again, the modes are on, and the background query is
    /// out. The call stops the reader, so start a new one after it. The shell does not see the screen of the
    /// terminal while it waits, so redraw every cell after the call.
    ///
    /// # Errors
    ///
    /// Returns the error that ended the reader, or the error of the system when a setting, a write, or the signal
    /// fails.
    pub fn suspend(&mut self) -> io::Result<()> {
        self.stop_reader()?;
        self.leave()?;
        // The group stops, so a wrapper such as `mise exec` stops too, and the shell gets the terminal back.
        rustix::process::kill_current_process_group(rustix::process::Signal::TSTP)?;
        self.enter()?;
        self.write_all(BACKGROUND_QUERY)
    }

    /// Enter raw mode and turn on the modes: the screen modes, and modifyOtherKeys when the probe turned it on.
    fn enter(&self) -> io::Result<()> {
        let mut raw = self.saved.clone();
        raw.make_raw();
        set(&self.file, &raw)?;
        self.write_all(ENTER)?;
        if self.modify_other_keys {
            self.write_all(b"\x1b[>4;2m")?;
        }
        Ok(())
    }

    /// Turn off each mode that the terminal turned on, and restore the saved settings.
    fn leave(&self) -> io::Result<()> {
        let mut leave = b"\x1b[<u".to_vec();
        if self.modify_other_keys {
            // No value resets modifyOtherKeys to the initial value of the terminal.
            leave.extend_from_slice(b"\x1b[>4m");
        }
        leave.extend_from_slice(b"\x1b[?2031l\x1b[?1002;1004;1006l\x1b[?2004l\x1b[0m\x1b[?25h\x1b[?1049l");
        let written = self.write_all(&leave);
        // The settings come back also after a failed write, so the shell does not stay raw.
        let restored = set(&self.file, &self.saved);
        written.and(restored)
    }

    /// Start a thread that reads the terminal and calls `events` with each event. The first events are the input that
    /// came during the probe. A later reader starts with a new parser. The thread calls `ended` when the input ends or
    /// a read fails; then [`Terminal::stop_reader`] gives the error. A stop that the thread sees first gives no call,
    /// but a stop during the last read can. The thread sees a stop only between two calls, so a call that blocks for
    /// ever blocks [`Terminal::stop_reader`] and the drop too.
    ///
    /// # Errors
    ///
    /// Returns an error of kind [`io::ErrorKind::AlreadyExists`] while the terminal has a reader, also one whose
    /// thread ended. Other errors come from the system.
    pub fn start_reader<F, G>(&mut self, events: F, ended: G) -> io::Result<()>
    where
        F: FnMut(Event) + Send + 'static,
        G: FnOnce() + Send + 'static,
    {
        // Two readers would split the bytes of one key between them.
        if self.reader.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the terminal has a reader",
            ));
        }
        let input = self.file.try_clone()?;
        // The pipe of the standard library closes on exec, so a child process does not keep the stop open.
        let pipe = io::pipe()?;
        let (parser, early) = self.early.take().unwrap_or_default();
        self.reader = Some(Reader::spawn(input, pipe, parser, early, events, ended)?);
        Ok(())
    }

    /// Stop the reader thread and wait for it. Without a reader it does nothing.
    ///
    /// # Errors
    ///
    /// Returns the error that ended the thread, if one did.
    pub fn stop_reader(&mut self) -> io::Result<()> {
        self.reader.take().map_or(Ok(()), Reader::stop)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        // The reader stops first, so it reads nothing after the settings come back.
        if self.stop_reader().is_err() {
            // The drop cannot report how the thread ended.
        }
        if self.leave().is_err() {
            // The drop cannot report the failure, and a terminal that refuses the write or the settings stays raw.
        }
    }
}

/// Drop the input that waits, such as a late probe answer, and apply `settings` at once. A wait for the output to
/// drain could block on a reader that never reads.
fn set(file: &File, settings: &Termios) -> io::Result<()> {
    let flushed = termios::tcflush(file, QueueSelector::IFlush);
    let applied = termios::tcsetattr(file, OptionalActions::Now, settings);
    Ok(flushed.and(applied)?)
}

/// The device of the first standard stream that is a terminal, else `/dev/tty`. macOS `poll` refuses `/dev/tty`, so
/// the real device name comes first.
fn device() -> io::Result<File> {
    let open = |path: &OsStr| OpenOptions::new().read(true).write(true).open(path);
    let (stdin, stdout, stderr) = (io::stdin(), io::stdout(), io::stderr());
    for stream in [stdin.as_fd(), stdout.as_fd(), stderr.as_fd()] {
        let Ok(name) = termios::ttyname(stream, Vec::new()) else {
            continue;
        };
        // A stream redirected from `/dev/tty` names it, and that name is the one to avoid.
        let path = OsStr::from_bytes(name.as_bytes());
        if path != "/dev/tty"
            && let Ok(file) = open(path)
        {
            return Ok(file);
        }
    }
    open(OsStr::new("/dev/tty"))
}

#[cfg(test)]
mod tests;
