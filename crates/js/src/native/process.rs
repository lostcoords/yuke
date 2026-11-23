//! The native of `yuke:process`:
//! - `processOutput` runs a program without a shell, and answers its end and its output.
//! - `processSpawn` starts a program and gives a child. `processRead`, `processWrite`, and `processClose` use its
//!   pipes. `processStatus` waits for its end. `processKill` sends a signal to its group, and `processStop` stops it.
//! - `processEnv` reads a variable of the environment of yuke.

use std::future::poll_fn;
use std::io;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Poll, ready};

use rquickjs::class::Trace;
use rquickjs::{Class, Ctx, Function, JsLifetime, Object, Promise, TypedArray, Value};
use rustix::process::Pid;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::process::{ChildStderr, ChildStdin, ChildStdout};
use tokio::sync::watch;
use yuke_engine::CancellationToken;

use super::Operation;
use crate::error::{ErrorClass, throw};
use crate::processes::{
    Processes, Program, ProgramStatus, SpawnedEnd, kill_rest_of_group, signal_group, signal_of, spawn_program,
};

/// The most bytes of one read.
const CHUNK: usize = 64 * 1024;

/// A spawned program with its pipes. A free by QuickJS stops a program that still runs.
#[derive(Trace, JsLifetime)]
#[rquickjs::class(rename = "ProcessChild")]
pub(crate) struct Child {
    /// `None` without a pipe or after a close. Operations borrow a pipe only during a poll.
    #[qjs(skip_trace)]
    stdin: Option<ChildStdin>,
    #[qjs(skip_trace)]
    stdout: Option<ChildStdout>,
    #[qjs(skip_trace)]
    stderr: Option<ChildStderr>,
    /// The close of a pipe cancels its token, so a pending read or write of the pipe ends. In the order stdin, stdout,
    /// stderr.
    #[qjs(skip_trace)]
    closed: [CancellationToken; 3],
    #[qjs(skip_trace)]
    group: Pid,
    /// A cancel before the exit stops the group.
    #[qjs(skip_trace)]
    stop: CancellationToken,
    #[qjs(skip_trace)]
    end: watch::Receiver<SpawnedEnd>,
}

impl Drop for Child {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

/// Add the functions of `yuke:process` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, processes: &Rc<Processes>) -> rquickjs::Result<()> {
    // A missing variable and a value that is not valid Unicode both give `undefined`.
    object.set(
        "processEnv",
        Function::new(ctx.clone(), |name: String| std::env::var(name).ok())?,
    )?;
    let processes = Rc::clone(processes);
    object.set(
        "processOutput",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, program: Program| -> rquickjs::Result<Operation<'js>> {
                output(&ctx, Rc::clone(&processes), program)
            },
        )?,
    )?;
    add_spawn(ctx, object)
}

/// Start `program`, and answer the operation of its run.
fn output<'js>(ctx: &Ctx<'js>, processes: Rc<Processes>, program: Program) -> rquickjs::Result<Operation<'js>> {
    Operation::start(ctx, move |ctx, stop| async move {
        match processes.output(program, stop).await {
            Ok(end) => {
                let object = status_object(&ctx, end.status)?;
                object.set("stdout", TypedArray::<u8>::new(ctx.clone(), end.stdout)?)?;
                object.set("stderr", TypedArray::<u8>::new(ctx.clone(), end.stderr)?)?;
                Ok(object)
            }
            Err(message) => Err(throw(&ctx, ErrorClass::Error, &message)),
        }
    })
}

/// The record `{ code, signal }` of `status`.
fn status_object<'js>(ctx: &Ctx<'js>, status: ProgramStatus) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("code", status.code)?;
    // `null` as the type says: a `None` alone would be `undefined`.
    match status.signal {
        Some(name) => object.set("signal", name)?,
        None => object.set("signal", Value::new_null(ctx.clone()))?,
    }
    Ok(object)
}

/// Add `processSpawn`, `processClose`, `processStatus`, `processKill`, `processStop`, and the reads and writes.
fn add_spawn<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "processSpawn",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, program: Program| {
            let stop = CancellationToken::new();
            let spawned =
                spawn_program(&program, stop.clone()).map_err(|message| throw(&ctx, ErrorClass::Error, &message))?;
            let result = Object::new(ctx.clone())?;
            result.set("pid", spawned.pid)?;
            let child = Child {
                stdin: spawned.stdin,
                stdout: spawned.stdout,
                stderr: spawned.stderr,
                closed: Default::default(),
                group: spawned.group,
                stop,
                end: spawned.end,
            };
            result.set("child", Class::instance(ctx, child)?)?;
            Ok::<_, rquickjs::Error>(result)
        })?,
    )?;
    add_pipes(ctx, object)?;
    object.set(
        "processClose",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, child: Class<'js, Child>, stream: String| {
                let mut state = child.borrow_mut();
                // The drop closes the end of yuke: the program reads the end of its input, or a write of it fails.
                let index = match stream.as_str() {
                    "stdin" => {
                        drop(state.stdin.take());
                        0
                    }
                    "stdout" => {
                        drop(state.stdout.take());
                        1
                    }
                    "stderr" => {
                        drop(state.stderr.take());
                        2
                    }
                    _ => {
                        return Err(throw(
                            &ctx,
                            ErrorClass::TypeError,
                            "the stream is not stdin, stdout, or stderr",
                        ));
                    }
                };
                state.closed[index].cancel();
                Ok(())
            },
        )?,
    )?;
    object.set(
        "processStatus",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, child: Class<'js, Child>| {
            let mut end = child.borrow().end.clone();
            Promise::wrap_future(&ctx.clone(), async move {
                let ended = end.wait_for(Option::is_some).await.map(|end| end.clone());
                match ended {
                    Ok(Some(Ok(status))) => status_object(&ctx, status),
                    Ok(Some(Err(message))) => Err(throw(&ctx, ErrorClass::Error, &message)),
                    _ => Err(throw(&ctx, ErrorClass::Error, "the runtime of yuke ended")),
                }
            })
        })?,
    )?;
    object.set(
        "processKill",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, child: Class<'js, Child>, name: String| {
            let state = child.borrow();
            if state.end.borrow().is_some() {
                return Err(throw(
                    &ctx,
                    ErrorClass::TypeError,
                    "Child process has already terminated",
                ));
            }
            let Some(signal) = signal_of(&name) else {
                return Err(throw(&ctx, ErrorClass::TypeError, &format!("Unknown signal: {name}")));
            };
            signal_group(state.group, signal).map_err(|error| throw(&ctx, ErrorClass::Error, &format!("kill: {error}")))
        })?,
    )?;
    object.set(
        "processStop",
        Function::new(ctx.clone(), |child: Class<'js, Child>| {
            let state = child.borrow();
            if state.end.borrow().is_some() {
                // The leader ended, so only a process that it left can hold a pipe open.
                kill_rest_of_group(state.group);
            } else {
                state.stop.cancel();
            }
        })?,
    )
}

/// Add `processRead` and `processWrite`.
fn add_pipes<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "processRead",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, child: Class<'js, Child>, stream: String| {
                let stdout = match stream.as_str() {
                    "stdout" => true,
                    "stderr" => false,
                    _ => return Err(throw(&ctx, ErrorClass::TypeError, "the stream is not stdout or stderr")),
                };
                let closed = child.borrow().closed[if stdout { 1 } else { 2 }].clone();
                Promise::wrap_future(&ctx.clone(), async move {
                    let mut buffer = vec![0; CHUNK];
                    let read = poll_fn(|task| {
                        let mut state = child.borrow_mut();
                        let mut read = ReadBuf::new(&mut buffer);
                        let pipe: Option<Pin<&mut dyn AsyncRead>> = if stdout {
                            state.stdout.as_mut().map(|pipe| Pin::new(pipe) as _)
                        } else {
                            state.stderr.as_mut().map(|pipe| Pin::new(pipe) as _)
                        };
                        let Some(pipe) = pipe else {
                            return Poll::Ready(Ok(0));
                        };
                        ready!(pipe.poll_read(task, &mut read))?;
                        Poll::Ready(Ok::<_, io::Error>(read.filled().len()))
                    });
                    // A closed pipe gives no more bytes.
                    let read = tokio::select! {
                        read = read => read,
                        () = closed.cancelled() => Ok(0),
                    };
                    let count =
                        read.map_err(|error| throw(&ctx, ErrorClass::Error, &format!("read {stream}: {error}")))?;
                    match count {
                        0 => Ok::<_, rquickjs::Error>(None),
                        count => Ok(Some(TypedArray::<u8>::new(ctx.clone(), &buffer[..count])?)),
                    }
                })
            },
        )?,
    )?;
    object.set(
        "processWrite",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, child: Class<'js, Child>, bytes: TypedArray<'js, u8>| {
                let bytes = crate::bytes::copy(&bytes)?;
                let closed = child.borrow().closed[0].clone();
                Promise::wrap_future(&ctx.clone(), async move {
                    let mut written = 0;
                    let write = poll_fn(|task| {
                        let mut state = child.borrow_mut();
                        let Some(pipe) = state.stdin.as_mut() else {
                            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
                        };
                        while written < bytes.len() {
                            match ready!(Pin::new(&mut *pipe).poll_write(task, &bytes[written..])) {
                                Ok(0) => return Poll::Ready(Err(io::ErrorKind::WriteZero.into())),
                                Ok(count) => written += count,
                                Err(error) => return Poll::Ready(Err(error)),
                            }
                        }
                        Poll::Ready(Ok::<_, io::Error>(()))
                    });
                    tokio::select! {
                        result = write => result.map_err(|error| throw(&ctx, ErrorClass::Error, &format!("write stdin: {error}"))),
                        () = closed.cancelled() => Err(throw(&ctx, ErrorClass::Error, "write stdin: stdin is closed")),
                    }
                })
            },
        )?,
    )?;
    Ok(())
}
