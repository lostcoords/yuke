//! The thread that reads the terminal and parses its bytes, and the poll and read steps that the probe shares.

use std::fs::File;
use std::io::{self, Read as _};
use std::os::fd::OwnedFd;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;

use crate::event::Event;
use crate::parser::{Parsed, Parser};

/// The thread that passes each event of the terminal to a callback. It ends at a stop, at the end of the input, or
/// at a read error. [`Terminal`](crate::Terminal) owns it.
#[derive(Debug)]
pub(crate) struct Reader {
    /// The write end of a pipe that the thread polls. Its close stops the thread.
    stop: Option<OwnedFd>,
    thread: Option<JoinHandle<io::Result<()>>>,
}

impl Reader {
    /// Start a thread that reads `input` with `parser`, and calls `events` first with `early` and then with each
    /// event. The thread polls the read end of `pipe`, and a close of its write end stops the thread.
    pub(crate) fn spawn<F>(
        input: File,
        (stopped, stop): (OwnedFd, OwnedFd),
        parser: Parser,
        early: Vec<Event>,
        mut events: F,
    ) -> io::Result<Self>
    where
        F: FnMut(Event) + Send + 'static,
    {
        let thread = thread::Builder::new()
            .name("yuke-term input".to_owned())
            .spawn(move || {
                for event in early {
                    events(event);
                }
                read_events(&input, &stopped, parser, &mut events)
            })?;
        Ok(Self {
            stop: Some(stop),
            thread: Some(thread),
        })
    }

    /// Stop the thread, wait for it, and return the error that ended it, if one did.
    pub(crate) fn stop(mut self) -> io::Result<()> {
        self.finish()
    }

    fn finish(&mut self) -> io::Result<()> {
        drop(self.stop.take());
        match self.thread.take().map(JoinHandle::join) {
            Some(Ok(result)) => result,
            Some(Err(_)) => Err(io::Error::other("the input thread panicked")),
            None => Ok(()),
        }
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        if self.finish().is_err() {
            // The owner dropped the reader without asking how the thread ended.
        }
    }
}

fn read_events(input: &File, stopped: &OwnedFd, mut parser: Parser, events: &mut impl FnMut(Event)) -> io::Result<()> {
    let mut buffer = [0; 4096];
    loop {
        let mut fds = [PollFd::new(&input, PollFlags::IN), PollFd::new(stopped, PollFlags::IN)];
        wait(&mut fds, None)?;
        // The close of the write end wakes the poll with a hang-up.
        if !fds[1].revents().is_empty() {
            return Ok(());
        }
        if fds[0].revents().is_empty() {
            continue;
        }
        let Some(read) = read_input(input, &mut buffer)? else {
            return Ok(());
        };
        for parsed in parser.feed(&buffer[..read]) {
            // An answer that comes after the probe has no reader.
            if let Parsed::Event(event) = parsed {
                events(event);
            }
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
