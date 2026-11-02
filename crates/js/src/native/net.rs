//! The native of `yuke:net`: connections to Unix sockets on tokio.
//! - `netConnect` connects to a path. `netRead` reads one chunk, and gives `undefined` at the end.
//! - `netWrite` writes each byte. `netClose` shuts down both directions of the socket.
//! - `netListen`, `netAccept`, and `netUnlisten` serve the test server of `yuke:test`.
//! - A failure rejects with a record `{ code, message }`. A stop or a closed connection rejects with `{ cancelled: true }`.

use std::cell::RefCell;
use std::future::poll_fn;
use std::io;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Poll, ready};
use std::time::{SystemTime, UNIX_EPOCH};

use rquickjs::class::Trace;
use rquickjs::{Class, Ctx, Function, IntoJs, JsLifetime, Object, TypedArray};
use rustix::io::Errno;
use rustix::net::{Shutdown, shutdown};
use tokio::net::{UnixListener, UnixStream};

use super::{Cancelled, Operation};

/// The most bytes of one read.
const CHUNK: usize = 64 * 1024;

/// A connection with one socket shared by its reads and writes.
#[derive(Trace, JsLifetime)]
#[rquickjs::class(rename = "NetConnection")]
pub(crate) struct Connection {
    /// `None` after a close. Operations borrow the socket only during a poll.
    #[qjs(skip_trace)]
    stream: Option<UnixStream>,
}

impl Connection {
    fn of(stream: UnixStream) -> Self {
        Self { stream: Some(stream) }
    }
}

/// A test server. The listener drops at `netUnlisten`, or when QuickJS frees the object.
#[derive(Trace, JsLifetime)]
#[rquickjs::class(rename = "NetListener")]
pub(crate) struct Listener {
    /// An accept shares the listener across its wait.
    #[qjs(skip_trace)]
    listener: RefCell<Option<Rc<UnixListener>>>,
    /// The socket file. `netUnlisten` removes it.
    #[qjs(skip_trace)]
    path: PathBuf,
}

/// A started test server and the path of its socket.
#[derive(IntoJs)]
struct Served<'js> {
    listener: Class<'js, Listener>,
    path: String,
}

/// The count of the test servers of the process, for the name of the next socket file.
static LISTENERS: AtomicU64 = AtomicU64::new(0);

/// Add the functions of the connections and of the test server to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    add_connections(ctx, object)?;
    add_test_server(ctx, object)
}

/// Add `netConnect`, `netRead`, `netWrite`, and `netClose`.
fn add_connections<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "netConnect",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, path: String| {
            Operation::start(&ctx, move |ctx, stop| async move {
                let stream = tokio::select! {
                    stream = UnixStream::connect(&path) => stream,
                    () = stop.cancelled() => return Err(cancelled(&ctx)),
                };
                let stream = stream.map_err(|error| failure(&ctx, &format!("connect {path}"), &error))?;
                Class::instance(ctx.clone(), Connection::of(stream))
            })
        })?,
    )?;
    object.set(
        "netRead",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, connection: Class<'js, Connection>| {
            Operation::start(&ctx, move |ctx, stop| async move {
                let mut buffer = vec![0; CHUNK];
                let read = tokio::select! {
                    read = poll_fn(|task| {
                        let state = connection.borrow();
                        let Some(stream) = &state.stream else {
                            return Poll::Ready(Err(cancelled(&ctx)));
                        };
                        loop {
                            ready!(stream.poll_read_ready(task)).map_err(|error| failure(&ctx, "read", &error))?;
                            match stream.try_read(&mut buffer) {
                                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {},
                                read => return Poll::Ready(read.map_err(|error| failure(&ctx, "read", &error))),
                            }
                        }
                    }) => read,
                    () = stop.cancelled() => return Err(cancelled(&ctx)),
                };
                match read? {
                    0 => Ok(None),
                    count => Ok(Some(TypedArray::<u8>::new(ctx.clone(), &buffer[..count])?)),
                }
            })
        })?,
    )?;
    object.set(
        "netWrite",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, connection: Class<'js, Connection>, bytes: TypedArray<'js, u8>| {
                let bytes = crate::bytes::copy(&bytes)?;
                Operation::start(&ctx, move |ctx, stop| async move {
                    let mut written = 0;
                    tokio::select! {
                        written = poll_fn(|task| {
                            let state = connection.borrow();
                            let Some(stream) = &state.stream else {
                                return Poll::Ready(Err(cancelled(&ctx)));
                            };
                            while written < bytes.len() {
                                ready!(stream.poll_write_ready(task))
                                    .map_err(|error| failure(&ctx, "write", &error))?;
                                match stream.try_write(&bytes[written..]) {
                                    Ok(0) => return Poll::Ready(Err(failure(&ctx, "write", &io::ErrorKind::WriteZero.into()))),
                                    Ok(count) => written += count,
                                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {},
                                    Err(error) => return Poll::Ready(Err(failure(&ctx, "write", &error))),
                                }
                            }
                            Poll::Ready(Ok(()))
                        }) => written,
                        () = stop.cancelled() => Err(cancelled(&ctx)),
                    }
                })
            },
        )?,
    )?;
    object.set(
        "netClose",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, connection: Class<'js, Connection>| {
            let mut state = connection.borrow_mut();
            let Some(stream) = &state.stream else {
                return Ok(());
            };
            match shutdown(stream, Shutdown::Both) {
                Ok(()) | Err(Errno::NOTCONN) => {}
                Err(error) => return Err(failure(&ctx, "close", &error.into())),
            }
            // On macOS, shutdown alone still lets the peer write until the socket drops.
            drop(state.stream.take());
            Ok(())
        })?,
    )?;
    Ok(())
}

/// Add `netListen`, `netAccept`, and `netUnlisten`.
fn add_test_server<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "netListen",
        Function::new(ctx.clone(), |ctx: Ctx<'js>| {
            // The scratch folder of a test can be too long for a socket path, so the server takes a short one.
            // The time keeps the name new when a later process gets the pid of a killed one that left its file.
            let time = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |time| time.as_micros());
            let id = LISTENERS.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!("yuke-{}-{time}-{id}.sock", std::process::id()));
            let listener = UnixListener::bind(&path)
                .map_err(|error| failure(&ctx, &format!("listen {}", path.display()), &error))?;
            let listener = Class::instance(
                ctx,
                Listener {
                    listener: RefCell::new(Some(Rc::new(listener))),
                    path: path.clone(),
                },
            )?;
            Ok::<_, rquickjs::Error>(Served {
                listener,
                path: path.to_string_lossy().into_owned(),
            })
        })?,
    )?;
    object.set(
        "netAccept",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, listener: Class<'js, Listener>| {
            Operation::start(&ctx, move |ctx, stop| async move {
                let shared = listener.borrow().listener.borrow().clone();
                let Some(shared) = shared else {
                    return Err(cancelled(&ctx));
                };
                let accepted = tokio::select! {
                    accepted = shared.accept() => accepted,
                    () = stop.cancelled() => return Err(cancelled(&ctx)),
                };
                let (stream, _address) = accepted.map_err(|error| failure(&ctx, "accept", &error))?;
                Class::instance(ctx.clone(), Connection::of(stream))
            })
        })?,
    )?;
    object.set(
        "netUnlisten",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, listener: Class<'js, Listener>| {
            let state = listener.borrow();
            if state.listener.borrow_mut().take().is_none() {
                return Ok(());
            }
            std::fs::remove_file(&state.path)
                .map_err(|error| failure(&ctx, &format!("unlisten {}", state.path.display()), &error))
        })?,
    )?;
    Ok(())
}

/// The record of a failed operation.
#[derive(IntoJs)]
struct NetError {
    code: Option<&'static str>,
    message: String,
}

/// Throw the record of `error` in the operation `operation`, with the POSIX name of the failures that a caller acts on.
fn failure(ctx: &Ctx<'_>, operation: &str, error: &io::Error) -> rquickjs::Error {
    const CODES: &[(Errno, &str)] = &[
        (Errno::NOENT, "ENOENT"),
        (Errno::CONNREFUSED, "ECONNREFUSED"),
        (Errno::ACCESS, "EACCES"),
        (Errno::PIPE, "EPIPE"),
        (Errno::CONNRESET, "ECONNRESET"),
    ];
    let errno = Errno::from_io_error(error);
    let record = NetError {
        code: CODES
            .iter()
            .find(|(known, _)| Some(*known) == errno)
            .map(|(_, code)| *code),
        message: format!("{operation}: {error}"),
    };
    match record.into_js(ctx) {
        Ok(value) => ctx.throw(value),
        Err(error) => error,
    }
}

/// Throw the record of a stop.
fn cancelled(ctx: &Ctx<'_>) -> rquickjs::Error {
    match (Cancelled { cancelled: true }).into_js(ctx) {
        Ok(value) => ctx.throw(value),
        Err(error) => error,
    }
}
