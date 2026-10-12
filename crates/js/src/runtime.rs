//! The JavaScript thread. One OS thread owns the engine, because the engine values are not `Send`. Callers on other
//! threads send it calls through a channel and await the answers.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use rquickjs::runtime::DriveFuture;
use rquickjs::{AsyncContext, AsyncRuntime, Ctx, Module, Persistent, Value};
use tokio::sync::{Notify, mpsc, oneshot};

use crate::error::{Error, Fault, ScriptError, caught};
use crate::loader::{FileLoader, PathResolver};
use crate::strip::Cache;
use crate::timers::{self, Timers};

/// The stack of the JavaScript thread above [`Limits::stack`]. The engine checks only its own frames, so the thread
/// needs room for the Rust frames too.
const THREAD_HEADROOM: usize = 2 << 20;

/// The settings of a runtime.
#[derive(Debug, Clone)]
pub struct Options {
    /// The limits of the JavaScript.
    pub limits: Limits,

    /// The folder that keeps the JavaScript of each TypeScript file. The runtime makes it when it is missing.
    pub cache: PathBuf,
}

/// The limits of the JavaScript of one runtime.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// The most bytes that the JavaScript heap holds. An allocation past it throws a catchable `InternalError`.
    pub memory: usize,

    /// The most bytes of stack that the JavaScript uses. A deeper call throws a catchable `RangeError`. A value above
    /// 16 MiB means no limit, and a deep recursion then overflows the thread and aborts the process.
    pub stack: usize,

    /// The longest time of one slice: an uninterrupted stretch of JavaScript. A slice past it stops with
    /// [`Error::Interrupted`].
    pub slice: Duration,
}

/// A call for the JavaScript thread. It receives the notice of interrupts.
type Call = Box<dyn for<'js> FnOnce(Ctx<'js>, &Arc<Notify>) + Send>;

/// A QuickJS runtime on its own thread. Share it through an `Arc`. A drop asks the thread to end and does not wait;
/// [`Runtime::shutdown`] waits.
#[derive(Debug)]
pub struct Runtime {
    calls: mpsc::UnboundedSender<Call>,
    thread: JoinHandle<()>,
}

impl Runtime {
    /// Start the JavaScript thread. The receiver gets each [`Fault`]: a failure that belongs to no call.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Thread`] when the thread or its tokio runtime does not start. Returns [`Error::Script`] when the
    /// engine does not start, and [`Error::Stopped`] when the thread ends before it is ready.
    pub async fn start(options: Options) -> Result<(Self, mpsc::UnboundedReceiver<Fault>), Error> {
        let (calls, call_receiver) = mpsc::unbounded_channel();
        let (faults, fault_receiver) = mpsc::unbounded_channel();
        let (ready, started) = oneshot::channel();

        let thread = std::thread::Builder::new()
            .name("yuke-js".into())
            .stack_size(options.limits.stack.saturating_add(THREAD_HEADROOM))
            .spawn(move || serve(options, call_receiver, faults, ready))
            .map_err(Error::Thread)?;

        let runtime = Self { calls, thread };
        started.await.map_err(|_| Error::Stopped)??;
        Ok((runtime, fault_receiver))
    }

    /// Import the module at the absolute `path`, and wait for its evaluation, top-level `await` included.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when a module of the import graph fails to resolve, to load, or to evaluate.
    /// Returns [`Error::Interrupted`] when the slice limit stops the JavaScript, and [`Error::Stopped`] when the
    /// thread has ended.
    pub async fn import(&self, path: impl AsRef<Path>) -> Result<(), Error> {
        let path = path.as_ref();
        let Some(name) = path.to_str().map(str::to_owned) else {
            return Err(Error::Script(ScriptError {
                name: Some("TypeError".into()),
                message: format!("the module path {} is not UTF-8", path.display()),
                stack: None,
            }));
        };
        self.run(async move |ctx: Ctx<'_>| {
            let promise = caught(&ctx, Module::import(&ctx, name))?;
            caught(&ctx, promise.into_future::<Value<'_>>().await)?;
            Ok(())
        })
        .await
    }

    /// Run `f` on the JavaScript thread, and return its answer. A drop of the returned future drops the future of `f` at
    /// its next await. The slice limit stops a loop without an await.
    pub(crate) async fn run<F, R>(&self, f: F) -> Result<R, Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>) -> Result<R, Error> + Send + 'static,
        R: Send + 'static,
    {
        let (reply, answer) = oneshot::channel();
        let call: Call = Box::new(move |ctx: Ctx<'_>, interrupts: &Arc<Notify>| {
            // The notice counts the interrupts from its creation, so an interrupt before the first poll still ends the
            // call.
            let interrupted = Arc::clone(interrupts).notified_owned();
            ctx.clone().spawn(async move {
                let mut reply = reply;
                tokio::select! {
                    result = f(ctx) => {
                        if reply.send(result).is_err() {
                            // The caller has left.
                        }
                    }
                    () = interrupted => {
                        if reply.send(Err(Error::Interrupted)).is_err() {
                            // The caller has left.
                        }
                    }
                    () = reply.closed() => {}
                }
            });
        });

        self.calls.send(call).map_err(|_| Error::Stopped)?;
        answer.await.map_err(|_| Error::Stopped)?
    }

    /// Stop the JavaScript and wait for the end of the thread. The thread ends after its current slice.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Panicked`] when the thread panicked, and [`Error::Stopped`] when the tokio runtime of the caller
    /// ends during the wait.
    pub async fn shutdown(self) -> Result<(), Error> {
        let Self { calls, thread } = self;
        // The closed channel ends the loop of the thread.
        drop(calls);
        let joined = tokio::task::spawn_blocking(move || thread.join())
            .await
            .map_err(|_| Error::Stopped)?;
        joined.map_err(|panic| {
            let message = match panic.downcast::<String>() {
                Ok(text) => *text,
                Err(panic) => panic
                    .downcast_ref::<&str>()
                    .map_or_else(String::new, |text| (*text).to_owned()),
            };
            Error::Panicked(message)
        })
    }
}

/// The body of the JavaScript thread.
fn serve(
    options: Options,
    calls: mpsc::UnboundedReceiver<Call>,
    faults: mpsc::UnboundedSender<Fault>,
    ready: oneshot::Sender<Result<(), Error>>,
) {
    let tokio_runtime = match tokio::runtime::Builder::new_current_thread().enable_time().build() {
        Ok(tokio_runtime) => tokio_runtime,
        Err(error) => {
            if ready.send(Err(Error::Thread(error))).is_err() {
                // The caller of `start` has left.
            }
            return;
        }
    };
    tokio::task::LocalSet::new().block_on(&tokio_runtime, serve_calls(options, calls, faults, ready));
}

async fn serve_calls(
    options: Options,
    mut calls: mpsc::UnboundedReceiver<Call>,
    faults: mpsc::UnboundedSender<Fault>,
    ready: oneshot::Sender<Result<(), Error>>,
) {
    let engine = match Engine::new(options, faults.clone()).await {
        Ok(engine) => engine,
        Err(error) => {
            if ready.send(Err(error)).is_err() {
                // The caller of `start` has left.
            }
            return;
        }
    };
    if ready.send(Ok(())).is_err() {
        // The caller of `start` has left.
        engine.close();
        return;
    }

    let interrupts = Arc::new(Notify::new());
    let mut driver = Driver {
        drive: Box::pin(engine.runtime.drive()),
        slice: Rc::clone(&engine.slice),
        rejections: Rc::clone(&engine.rejections),
        faults: faults.clone(),
    };
    loop {
        tokio::select! {
            call = calls.recv() => match call {
                Some(call) => engine.context.with(|ctx| call(ctx, &interrupts)).await,
                None => break,
            },
            () = std::future::poll_fn(|context| driver.poll_interrupt(context)) => {
                // The drive leaves the exception of an interrupted job in the context, and the module loader takes a
                // pending exception for its own failure.
                engine.context.with(|ctx| drop(ctx.catch())).await;
                interrupts.notify_waiters();
                if faults.send(Fault::Interrupted).is_err() {
                    // The owner dropped the receiver, so it ignores faults.
                }
            }
        }
    }

    drop(driver);
    engine.close();
}

/// The engine of the thread, and the state that its callbacks share.
struct Engine {
    runtime: AsyncRuntime,
    context: AsyncContext,
    slice: Rc<Slice>,
    rejections: Rc<Rejections>,
    timers: Rc<Timers>,
}

impl Engine {
    async fn new(options: Options, faults: mpsc::UnboundedSender<Fault>) -> Result<Self, Error> {
        let engine_error = |error: rquickjs::Error| Error::Script(ScriptError::from_engine(&error));
        let runtime = AsyncRuntime::new().map_err(engine_error)?;
        runtime.set_memory_limit(options.limits.memory).await;
        runtime.set_max_stack_size(options.limits.stack).await;
        runtime
            .set_loader(PathResolver, FileLoader::new(Cache::new(options.cache)))
            .await;

        let slice = Rc::new(Slice {
            limit: options.limits.slice,
            start: Cell::new(None),
            interrupted: Cell::new(false),
        });
        let handler_slice = Rc::clone(&slice);
        runtime
            .set_interrupt_handler(Some(Box::new(move || handler_slice.expired())))
            .await;

        let rejections = Rc::new(Rejections::default());
        let tracker_rejections = Rc::clone(&rejections);
        runtime
            .set_host_promise_rejection_tracker(Some(Box::new(move |ctx, promise, reason, handled| {
                tracker_rejections.track(&ctx, promise, &reason, handled);
            })))
            .await;

        let context = AsyncContext::full(&runtime).await.map_err(engine_error)?;
        let timers = Rc::new(Timers::default());
        context
            .with(|ctx| timers::install(&ctx, &timers, faults))
            .await
            .map_err(engine_error)?;

        Ok(Self {
            runtime,
            context,
            slice,
            rejections,
            timers,
        })
    }

    /// Drop the engine. Each saved value goes first, because a saved value that outlives the runtime aborts the
    /// process.
    fn close(self) {
        self.timers.clear();
        self.rejections.pending.borrow_mut().clear();
        drop(self.context);
        drop(self.runtime);
    }
}

/// The time of the current slice, for the interrupt handler.
#[derive(Debug)]
struct Slice {
    limit: Duration,
    start: Cell<Option<Instant>>,
    interrupted: Cell<bool>,
}

impl Slice {
    /// Whether the current slice is past the limit. The engine calls this once for each 10,000 interrupt checks.
    fn expired(&self) -> bool {
        let expired = self.start.get().is_some_and(|start| start.elapsed() > self.limit);
        if expired {
            self.interrupted.set(true);
        }
        expired
    }
}

/// The promise rejections that no handler took yet.
#[derive(Debug, Default)]
struct Rejections {
    pending: RefCell<Vec<(Persistent<Value<'static>>, ScriptError)>>,
}

impl Rejections {
    fn track<'js>(&self, ctx: &Ctx<'js>, promise: Value<'js>, reason: &Value<'js>, handled: bool) {
        let promise = Persistent::save(ctx, promise);
        let mut pending = self.pending.borrow_mut();
        if handled {
            pending.retain(|(rejected, _)| *rejected != promise);
        } else {
            pending.push((promise, ScriptError::from_value(ctx, reason)));
        }
    }
}

/// The drive of the engine: it runs the promise jobs and the spawned futures. Each poll is one slice.
struct Driver {
    drive: Pin<Box<DriveFuture>>,
    slice: Rc<Slice>,
    rejections: Rc<Rejections>,
    faults: mpsc::UnboundedSender<Fault>,
}

impl Driver {
    /// Drive the engine. Ready means that the slice limit interrupted the JavaScript in this poll.
    fn poll_interrupt(&mut self, context: &mut Context<'_>) -> Poll<()> {
        self.slice.start.set(Some(Instant::now()));
        self.slice.interrupted.set(false);
        let drive = self.drive.as_mut().poll(context);
        self.slice.start.set(None);
        // The drive ends only with the runtime, and the runtime outlives the driver.
        debug_assert!(drive.is_pending());

        // A rejection that got no handler in this slice is a fault. A later handler comes too late.
        for (_, error) in self.rejections.pending.take() {
            if self.faults.send(Fault::Script(error)).is_err() {
                // The owner dropped the receiver, so it ignores faults.
            }
        }

        if self.slice.interrupted.get() {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    }
}
