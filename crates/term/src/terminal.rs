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

/// The alternate screen, bracketed paste, button and motion mouse reports in SGR form, focus reports, and kitty keys
/// with the disambiguate and alternate-key flags. A terminal ignores each mode that it does not know.
const ENTER: &[u8] = b"\x1b[?1049h\x1b[?2004h\x1b[?1002;1004;1006h\x1b[>5u";

/// The OSC 11 query of the background color.
const BACKGROUND_QUERY: &[u8] = b"\x1b]11;?\x1b\\";

/// After the background query: mode 2031, the kitty keyboard flags, and the primary device attributes. A terminal
/// answers in order, so the device attributes end the probe.
const PROBE: &[u8] = b"\x1b[?2031$p\x1b[?u\x1b[c";

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
    scheme_reports: bool,
    modify_other_keys: bool,
    /// The parser of the probe and the input that came during the probe, for the first reader.
    early: Option<(Parser, Vec<Event>)>,
    reader: Option<Reader>,
}

impl Terminal {
    /// Open the terminal of the process. See [`Terminal::from_file`].
    ///
    /// # Errors
    ///
    /// Returns the error of the system when no terminal device opens or a setting fails.
    pub fn open() -> io::Result<Self> {
        Self::from_file(device()?)
    }

    /// Take `file`, a terminal device: enter raw mode and the alternate screen, and probe the terminal. The wait for
    /// the answers ends 100 ms after the probe, and a busy system can add to it. Then the call turns on scheme reports
    /// when the terminal has them, and xterm modifyOtherKeys unless the terminal reports kitty flags.
    ///
    /// # Errors
    ///
    /// Returns the error of the system when `file` is no terminal, a setting fails, or a write fails.
    pub fn from_file(file: File) -> io::Result<Self> {
        let saved = termios::tcgetattr(&file)?;
        let mut raw = saved.clone();
        raw.make_raw();
        set(&file, &raw)?;
        let mut terminal = Self {
            file,
            saved,
            background: None,
            scheme_reports: false,
            modify_other_keys: false,
            early: None,
            reader: None,
        };
        terminal.write_all(ENTER)?;
        terminal.query_background()?;
        terminal.write_all(PROBE)?;
        terminal.probe()?;
        Ok(terminal)
    }

    /// The background color that the probe found. It is `None` when the terminal did not answer in time. A later
    /// answer to [`Terminal::query_background`] comes as an [`Event::Background`] and does not change this value.
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

    /// Ask for the background color again, such as after a [`Event::Scheme`]. The reader gives the answer as an
    /// [`Event::Background`]. Without a reader, no callback gets it.
    ///
    /// # Errors
    ///
    /// Returns the error of the write.
    pub fn query_background(&self) -> io::Result<()> {
        self.write_all(BACKGROUND_QUERY)
    }

    /// Read the answers until the device attributes come or the timeout ends, and turn on the modes that they allow.
    /// The parser and the other input stay for the first reader, so no typed key gets lost.
    fn probe(&mut self) -> io::Result<()> {
        let deadline = Instant::now() + PROBE_TIMEOUT;
        let mut parser = Parser::new();
        let mut early = Vec::new();
        let (mut scheme_reports, mut kitty_keyboard, mut complete) = (false, false, false);
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
                    Parsed::Answer(Answer::SchemeReports) => scheme_reports = true,
                    Parsed::Answer(Answer::KittyKeyboard(flags)) => kitty_keyboard = flags != 0,
                    Parsed::Answer(Answer::DeviceAttributes) => complete = true,
                }
            }
        }
        if scheme_reports {
            self.write_all(b"\x1b[?2031h")?;
            self.scheme_reports = true;
        }
        if !kitty_keyboard {
            self.write_all(b"\x1b[>4;2m")?;
            self.modify_other_keys = true;
        }
        self.early = Some((parser, early));
        Ok(())
    }

    /// Start a thread that reads the terminal and calls `events` with each event. The first events are the input that
    /// came during the probe. A later reader starts with a new parser. The thread sees a stop only between two calls,
    /// so a call that blocks for ever blocks [`Terminal::stop_reader`] and the drop too.
    ///
    /// # Errors
    ///
    /// Returns an error of kind [`io::ErrorKind::AlreadyExists`] while the terminal has a reader, also one whose
    /// thread ended. Then [`Terminal::stop_reader`] gives how it ended. Other errors come from the system.
    pub fn start_reader<F>(&mut self, events: F) -> io::Result<()>
    where
        F: FnMut(Event) + Send + 'static,
    {
        // Two readers would split the bytes of one key between them.
        if self.reader.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the terminal has a reader",
            ));
        }
        let input = self.file.try_clone()?;
        let pipe = rustix::pipe::pipe()?;
        let (parser, early) = self.early.take().unwrap_or_default();
        self.reader = Some(Reader::spawn(input, pipe, parser, early, events)?);
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
        let mut leave = b"\x1b[<u".to_vec();
        if self.modify_other_keys {
            // No value resets modifyOtherKeys to the initial value of the terminal.
            leave.extend_from_slice(b"\x1b[>4m");
        }
        if self.scheme_reports {
            leave.extend_from_slice(b"\x1b[?2031l");
        }
        leave.extend_from_slice(b"\x1b[?1002;1004;1006l\x1b[?2004l\x1b[0m\x1b[?25h\x1b[?1049l");
        if self.write_all(&leave).is_err() {
            // The drop cannot report the failure, and a terminal that refuses the write keeps the modes.
        }
        if set(&self.file, &self.saved).is_err() {
            // The drop cannot report the failure, and a terminal that refuses the settings stays raw.
        }
    }
}

/// Drop the input that waits, such as a late probe answer, and apply `settings` at once. A wait for the output to
/// drain could block on a reader that never reads.
fn set(file: &File, settings: &Termios) -> io::Result<()> {
    termios::tcflush(file, QueueSelector::IFlush)?;
    termios::tcsetattr(file, OptionalActions::Now, settings)?;
    Ok(())
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
