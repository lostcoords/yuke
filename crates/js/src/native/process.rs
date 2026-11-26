//! The native of `yuke:process`: a program of a plugin, without a shell.
//! - `processSpawn` starts a program and gives its child. `processStatus` gives the status of the leader at its exit.
//! - `processRead` reads one chunk of stdout or stderr, and gives `undefined` at the end. `processClose` closes a pipe.
//! - `processKill` sends a signal to the group. `processStop` stops the group, and a free of the child does too.
//! - `processEnv` reads a variable of the environment of yuke.

use rquickjs::class::Trace;
use rquickjs::{Class, Ctx, Function, JsLifetime, Object, Promise, TypedArray, Value};
use rustix::process::Pid;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::sync::watch;
use yuke_engine::CancellationToken;

use crate::error::{ErrorClass, throw};
use crate::processes::{Program, SpawnedStatus, kill_rest_of_group, signal_group, signal_of, spawn_program};

/// The most bytes of one read.
const CHUNK: usize = 64 * 1024;

/// A spawned program. A free of the child stops a program that still runs.
#[derive(Trace, JsLifetime)]
#[rquickjs::class(rename = "ProcessChild")]
pub(crate) struct Child {
    #[qjs(skip_trace)]
    group: Pid,
    /// stdout, then stderr.
    #[qjs(skip_trace)]
    pipes: [Pipe; 2],
    #[qjs(skip_trace)]
    status: watch::Receiver<SpawnedStatus>,
    /// A cancel stops the group of a running program. A free of the child cancels it.
    #[qjs(skip_trace)]
    stop: CancellationToken,
}

impl Drop for Child {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

impl Child {
    /// Whether the leader of the group exited.
    fn exited(&self) -> bool {
        self.status.borrow().is_some()
    }

    /// The pipe of the stream `name`: `stdout`, or else `stderr`. `yuke:process` is the only caller, and it sends no
    /// other name.
    fn pipe(&mut self, name: &str) -> &mut Pipe {
        &mut self.pipes[usize::from(name != "stdout")]
    }
}

/// An output pipe.
struct Pipe {
    /// `None` without a pipe or after a close.
    reader: Option<Box<dyn AsyncRead + Unpin>>,
    /// A close cancels it, so a pending read ends.
    closed: CancellationToken,
}

impl Pipe {
    fn of(reader: Option<impl AsyncRead + Unpin + 'static>) -> Self {
        Self {
            reader: reader.map(|reader| Box::new(reader) as Box<dyn AsyncRead + Unpin>),
            closed: CancellationToken::new(),
        }
    }
}

/// Add the functions of `yuke:process` to `object`, the export object of the native module: `processEnv`,
/// `processSpawn`, `processStatus`, `processKill`, and `processStop` here, and the functions of the pipes.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    // A missing variable and a value that is not valid Unicode both give `undefined`.
    object.set(
        "processEnv",
        Function::new(ctx.clone(), |name: String| std::env::var(name).ok())?,
    )?;
    object.set(
        "processSpawn",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, program: Program| {
            let spawned = spawn_program(&program).map_err(|message| throw(&ctx, ErrorClass::Error, &message))?;
            let child = Class::instance(
                ctx.clone(),
                Child {
                    group: spawned.group,
                    pipes: [Pipe::of(spawned.stdout), Pipe::of(spawned.stderr)],
                    status: spawned.status,
                    stop: spawned.stop,
                },
            )?;
            let answer = Object::new(ctx)?;
            answer.set("child", child)?;
            // The leader of the group has the id of the group.
            answer.set("pid", spawned.group.as_raw_nonzero().get())?;
            Ok::<_, rquickjs::Error>(answer)
        })?,
    )?;
    object.set(
        "processStatus",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, child: Class<'js, Child>| {
            let mut status = child.borrow().status.clone();
            Promise::wrap_future(&ctx.clone(), async move {
                // The future holds the child, so the program runs until its exit without a reference of the plugin.
                let exited = status
                    .wait_for(Option::is_some)
                    .await
                    .ok()
                    .and_then(|status| status.clone());
                drop(child);
                // The wait task ends without a status only when the host runtime shuts down.
                let status = exited
                    .unwrap_or_else(|| Err("the wait of the program ended".to_owned()))
                    .map_err(|message| throw(&ctx, ErrorClass::Error, &message))?;
                let object = Object::new(ctx.clone())?;
                object.set("code", status.code)?;
                // `null` as the type says: a `None` alone would be `undefined`.
                match status.signal {
                    Some(name) => object.set("signal", name)?,
                    None => object.set("signal", Value::new_null(ctx.clone()))?,
                }
                Ok::<_, rquickjs::Error>(object)
            })
        })?,
    )?;
    object.set(
        "processKill",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, child: Class<'js, Child>, name: String| {
            let state = child.borrow();
            let Some(signal) = signal_of(&name) else {
                return Err(throw(&ctx, ErrorClass::TypeError, &format!("Invalid signal: {name}")));
            };
            if state.exited() {
                return Err(throw(
                    &ctx,
                    ErrorClass::TypeError,
                    "Child process has already terminated",
                ));
            }
            signal_group(state.group, signal).map_err(|error| throw(&ctx, ErrorClass::Error, &error.to_string()))
        })?,
    )?;
    object.set(
        "processStop",
        Function::new(ctx.clone(), |child: Class<'js, Child>| {
            let state = child.borrow();
            if state.exited() {
                // A process that the program left can still hold a pipe open.
                kill_rest_of_group(state.group);
            } else {
                state.stop.cancel();
            }
        })?,
    )?;
    add_pipes(ctx, object)
}

/// Add `processRead` and `processClose`.
fn add_pipes<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "processRead",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, child: Class<'js, Child>, stream: String| {
                // The future owns the reader during the read, so no borrow of the child lasts across a poll.
                let (reader, closed) = {
                    let mut state = child.borrow_mut();
                    let pipe = state.pipe(&stream);
                    (pipe.reader.take(), pipe.closed.clone())
                };
                Promise::wrap_future(&ctx.clone(), async move {
                    let Some(mut reader) = reader else {
                        return Ok::<_, rquickjs::Error>(None);
                    };
                    let mut buffer = vec![0; CHUNK];
                    let count = tokio::select! {
                        read = reader.read(&mut buffer) => read.map_err(|error| {
                            throw(&ctx, ErrorClass::Error, &format!("yuke could not read the {stream}: {error}"))
                        })?,
                        () = closed.cancelled() => return Ok(None),
                    };
                    // At the end, the reader drops, so a later read gives the end too. After a close, the pipe stays closed.
                    if count == 0 || closed.is_cancelled() {
                        return Ok(None);
                    }
                    child.borrow_mut().pipe(&stream).reader = Some(reader);
                    Ok(Some(TypedArray::<u8>::new(ctx.clone(), &buffer[..count])?))
                })
            },
        )?,
    )?;
    object.set(
        "processClose",
        Function::new(ctx.clone(), |child: Class<'js, Child>, stream: String| {
            let mut state = child.borrow_mut();
            let pipe = state.pipe(&stream);
            pipe.reader = None;
            pipe.closed.cancel();
        })?,
    )?;
    Ok(())
}
