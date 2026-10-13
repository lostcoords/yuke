//! The JavaScript thread. One OS thread owns the engine, because the engine values are not `Send`. Callers on other
//! threads send it calls through a channel and await the answers.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::path::PathBuf;
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
use crate::loader::{ModuleLoader, NameResolver};
use crate::native;
use crate::processes::Processes;
use crate::strip::Cache;
use crate::timers::{self, Timers};
use crate::tools::{self, Registry, ScriptTool, SessionHost};

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

    /// The child processes of the tools. Give every JavaScript runtime of the process the same value, so a job
    /// outlives a reload.
    pub processes: Arc<Processes>,
}

/// The limits of the JavaScript of one runtime.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// The most bytes that the JavaScript heap holds. An allocation past it throws a catchable `InternalError`.
    /// Zero means no limit.
    pub memory: usize,

    /// The most bytes of stack that the JavaScript uses. A deeper call throws a catchable `RangeError`. Zero or a value
    /// above 16 MiB means no limit, and a deep recursion then overflows the thread and aborts the process.
    pub stack: usize,

    /// The longest time of one slice: an uninterrupted stretch of JavaScript. A slice past it stops with
    /// [`Error::Interrupted`].
    pub slice: Duration,
}

/// A call for the JavaScript thread. It receives the tool registry and the notice of interrupts.
type Call = Box<dyn for<'js> FnOnce(Ctx<'js>, &Rc<Registry>, &Arc<Notify>) + Send>;

/// A QuickJS runtime on its own thread. Share it through an `Arc`. A drop asks the thread to end and does not wait;
/// [`Runtime::shutdown`] waits.
#[derive(Debug)]
pub struct Runtime {
    caller: Caller,
    processes: Arc<Processes>,
    /// The drop of this sender ends the thread. A tool keeps a clone of the caller, so the call channel can outlive the
    /// runtime.
    stop: oneshot::Sender<()>,
    thread: JoinHandle<()>,
}

/// The sender of calls to the JavaScript thread. A tool keeps a clone, so its calls reach the thread.
#[derive(Debug, Clone)]
pub(crate) struct Caller {
    calls: mpsc::UnboundedSender<Call>,
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
        let (stop, stopped) = oneshot::channel();
        let processes = Arc::clone(&options.processes);

        let thread = std::thread::Builder::new()
            .name("yuke-js".into())
            .stack_size(options.limits.stack.saturating_add(THREAD_HEADROOM))
            .spawn(move || serve(options, call_receiver, stopped, faults, ready))
            .map_err(Error::Thread)?;

        let runtime = Self {
            caller: Caller { calls },
            processes,
            stop,
            thread,
        };
        started.await.map_err(|_| Error::Stopped)??;
        Ok((runtime, fault_receiver))
    }

    /// Import the module `name`: a built-in module such as `yuke:builtins`, or the absolute path of a file. Wait for its
    /// evaluation, top-level `await` included.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when a module of the import graph fails to resolve, to load, or to evaluate.
    /// Returns [`Error::Interrupted`] when the slice limit stops the JavaScript, and [`Error::Stopped`] when the
    /// thread has ended.
    pub async fn import(&self, name: &str) -> Result<(), Error> {
        let name = name.to_owned();
        self.run(async move |ctx: Ctx<'_>, _registry: Rc<Registry>| {
            let promise = caught(&ctx, Module::import(&ctx, name))?;
            caught(&ctx, promise.into_future::<Value<'_>>().await)?;
            Ok(())
        })
        .await
    }

    /// The tools that the JavaScript has defined so far, each with its definition, for the session of `host`. The
    /// consumer adds each pair to the toolset of that session.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended.
    pub async fn tools(&self, host: Arc<dyn SessionHost>) -> Result<Vec<(yuke_ai::ToolDefinition, ScriptTool)>, Error> {
        tools::tools(&self.caller, &self.processes, host).await
    }

    /// Run `f` on the JavaScript thread, and return its answer.
    pub(crate) async fn run<F, R>(&self, f: F) -> Result<R, Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) -> Result<R, Error> + Send + 'static,
        R: Send + 'static,
    {
        self.caller.run(f).await
    }

    /// Stop the JavaScript and wait for the end of the thread. The thread ends after its current slice.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Panicked`] when the thread panicked, and [`Error::Stopped`] when the tokio runtime of the caller
    /// ends during the wait.
    pub async fn shutdown(self) -> Result<(), Error> {
        let Self {
            caller,
            processes,
            stop,
            thread,
        } = self;
        drop(processes);
        drop(caller);
        drop(stop);
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

impl Caller {
    /// Run `f` on the JavaScript thread, and return its answer. A drop of the returned future drops the future of `f` at
    /// its next await. The slice limit stops a loop without an await.
    pub(crate) async fn run<F, R>(&self, f: F) -> Result<R, Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) -> Result<R, Error> + Send + 'static,
        R: Send + 'static,
    {
        let (reply, answer) = oneshot::channel();
        let call: Call = Box::new(move |ctx: Ctx<'_>, registry: &Rc<Registry>, interrupts: &Arc<Notify>| {
            // The notice counts the interrupts from its creation, so an interrupt before the first poll still ends the
            // call.
            let interrupted = Arc::clone(interrupts).notified_owned();
            let registry = Rc::clone(registry);
            ctx.clone().spawn(async move {
                let mut reply = reply;
                tokio::select! {
                    result = f(ctx, registry) => {
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
}

/// The body of the JavaScript thread.
fn serve(
    options: Options,
    calls: mpsc::UnboundedReceiver<Call>,
    stopped: oneshot::Receiver<()>,
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
    tokio::task::LocalSet::new().block_on(&tokio_runtime, serve_calls(options, calls, stopped, faults, ready));
}

async fn serve_calls(
    options: Options,
    mut calls: mpsc::UnboundedReceiver<Call>,
    mut stopped: oneshot::Receiver<()>,
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
            _ = &mut stopped => break,
            call = calls.recv() => match call {
                Some(call) => engine.context.with(|ctx| call(ctx, &engine.registry, &interrupts)).await,
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

    // The drive holds the runtime, so it goes before the engine.
    drop(driver);
}

/// The engine of the thread, and the state that its callbacks share.
struct Engine {
    context: AsyncContext,
    runtime: AsyncRuntime,
    slice: Rc<Slice>,
    rejections: Rc<Rejections>,
    timers: Rc<Timers>,
    registry: Rc<Registry>,
}

impl Engine {
    async fn new(options: Options, faults: mpsc::UnboundedSender<Fault>) -> Result<Self, Error> {
        let engine_error = |error: rquickjs::Error| Error::Script(ScriptError::from_engine(&error));
        let runtime = AsyncRuntime::new().map_err(engine_error)?;
        runtime.set_memory_limit(options.limits.memory).await;
        runtime.set_max_stack_size(options.limits.stack).await;
        runtime
            .set_loader(NameResolver, ModuleLoader::new(Cache::new(options.cache)))
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
        let registry = Rc::new(Registry::default());
        context
            .with(|ctx| {
                timers::install(&ctx, &timers, faults.clone())?;
                crate::error::install_report_error(&ctx, faults)?;
                native::install(&ctx, &registry)
            })
            .await
            .map_err(engine_error)?;

        Ok(Self {
            context,
            runtime,
            slice,
            rejections,
            timers,
            registry,
        })
    }
}

impl Drop for Engine {
    /// Drop each saved value before the fields drop the context and the runtime: a saved value that outlives the
    /// runtime aborts the process. A panic of the thread drops the engine this way too.
    fn drop(&mut self) {
        self.timers.clear();
        self.registry.clear();
        self.rejections.pending.borrow_mut().clear();
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
