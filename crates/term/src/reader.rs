//! The thread that reads the terminal and parses its bytes, and the poll and read steps that the probe shares.

use std::fs::File;
use std::io::{self, PipeReader, PipeWriter, Read as _};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;

use crate::event::Event;
use crate::parser::{Parsed, Parser};

/// The longest wait for the rest of a cut sequence, from its first byte, as the default `ttimeoutlen` of Neovim. Kitty
/// sends the escape key as a whole sequence, so a kitty escape key does not wait, and a legacy one waits this long.
const ASSEMBLY_TIMEOUT: Duration = Duration::from_millis(50);

/// The thread that passes each event of the terminal to a callback. It ends at a stop, at the end of the input, or
/// at a read error. [`Terminal`](crate::Terminal) owns it and stops it.
#[derive(Debug)]
pub(crate) struct Reader {
    /// The write end of a pipe that the thread polls. Its close stops the thread.
    stop: PipeWriter,
    thread: JoinHandle<io::Result<()>>,
}

impl Reader {
    /// Start a thread that reads `input` with `parser`, and calls `events` first with `early` and then with each
    /// event. The thread polls the read end of `pipe`, and a close of its write end stops the thread. The thread calls
    /// `ended` when it ends for another reason. A stop and an end of the input at the same time give no call.
    pub(crate) fn spawn<F, G>(
        input: File,
        (stopped, stop): (PipeReader, PipeWriter),
        parser: Parser,
        early: Vec<Event>,
        mut events: F,
        ended: G,
    ) -> io::Result<Self>
    where
        F: FnMut(Event) + Send + 'static,
        G: FnOnce() + Send + 'static,
    {
        let thread = thread::Builder::new()
            .name("yuke-term input".to_owned())
            .spawn(move || {
                for event in early {
                    events(event);
                }
                let result = read_events(&input, &stopped, parser, &mut events);
                if !matches!(result, Ok(End::Stop)) {
                    ended();
                }
                result.map(drop)
            })?;
        Ok(Self { stop, thread })
    }

    /// Stop the thread, wait for it, and return the error that ended it, if one did.
    pub(crate) fn stop(self) -> io::Result<()> {
        drop(self.stop);
        self.thread
            .join()
            .unwrap_or_else(|_| Err(io::Error::other("the input thread panicked")))
    }
}

/// Why the reading ended without an error.
enum End {
    /// The write end of the stop pipe closed.
    Stop,
    /// The input ended.
    Input,
}

fn read_events(
    input: &File,
    stopped: &PipeReader,
    mut parser: Parser,
    events: &mut impl FnMut(Event),
) -> io::Result<End> {
    let mut buffer = [0; 4096];
    // The time when the kept bytes of the parser stop waiting for the rest of their sequence.
    let mut deadline = None;
    let mut parsed = Vec::new();
    loop {
        // A cut sequence keeps the deadline of its first byte, so later bytes cannot hold it back for ever. A signal
        // can end the wait early, so only the deadline flushes.
        if parser.waits() {
            let now = Instant::now();
            match deadline {
                None => deadline = Some(now + ASSEMBLY_TIMEOUT),
                Some(at) if at <= now => {
                    parsed.extend(parser.flush());
                    deadline = None;
                }
                Some(_) => {}
            }
        } else {
            deadline = None;
        }
        for result in parsed.drain(..) {
            // An answer that comes after the probe has no reader.
            if let Parsed::Event(event) = result {
                events(event);
            }
        }
        let mut fds = [PollFd::new(&input, PollFlags::IN), PollFd::new(stopped, PollFlags::IN)];
        wait(
            &mut fds,
            deadline.map(|deadline| deadline.saturating_duration_since(Instant::now())),
        )?;
        // The close of the write end wakes the poll with a hang-up.
        if !fds[1].revents().is_empty() {
            return Ok(End::Stop);
        }
        if fds[0].revents().is_empty() {
            continue;
        }
        let Some(read) = read_input(input, &mut buffer)? else {
            return Ok(End::Input);
        };
        let kept = parser.kept();
        parsed = parser.feed(&buffer[..read]);
        // A read that ends the cut sequence also ends its deadline, so a new cut sequence gets its own.
        if parser.kept() != kept + read {
            deadline = None;
        }
    }
}

/// Wait until a file of `fds` is ready, or until `timeout` ends. A signal ends the wait early, so the caller checks
/// the ready flags again.
pub(crate) fn wait(fds: &mut [PollFd<'_>], timeout: Option<Duration>) -> io::Result<()> {
    let timeout = timeout.map(|timeout| Timespec {
        tv_sec: i64::try_from(timeout.as_secs()).unwrap_or(i64::MAX),
        tv_nsec: i64::from(timeout.subsec_nanos()),
    });
    match poll(fds, timeout.as_ref()) {
        Ok(_) | Err(Errno::INTR) => {}
        Err(error) => return Err(error.into()),
    }
    if fds.iter().any(|fd| fd.revents().contains(PollFlags::NVAL)) {
        return Err(io::Error::other("the terminal device refuses poll"));
    }
    Ok(())
}

/// Read once from the ready `input`. `None` is the end of the input.
pub(crate) fn read_input(mut input: &File, buffer: &mut [u8]) -> io::Result<Option<usize>> {
    loop {
        match input.read(buffer) {
            Ok(0) => return Ok(None),
            Ok(read) => return Ok(Some(read)),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}
