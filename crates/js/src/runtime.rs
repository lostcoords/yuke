//! The JavaScript engine. It runs as a local task of the host runtime, because the engine values are not `Send`.
//! Callers send it calls through a channel and await the answers.

use std::cell::RefCell;
use std::fmt;
use std::future::Future;
use std::path::PathBuf;
use std::pin::pin;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::Poll;
use std::time::Instant;

use rquickjs::{AsyncContext, AsyncRuntime, Ctx, Module, Persistent, Value};
use tokio::sync::{mpsc, oneshot};

use crate::display::Interface;
use crate::error::{Error, Report, ScriptError, caught};
use crate::loader::{ModuleLoader, NameResolver};
use crate::models::Models;
use crate::native;
use crate::native::term::{Frames, drive};
use crate::processes::Processes;
use crate::sessions::Sessions;
use crate::strip::Cache;
use crate::test_host::TestHost;
use crate::timers::{self, Timers};
use crate::tools::Registry;

/// The stack that the engine gives the JavaScript. The engine checks it, so a deep recursion throws a catchable
/// `RangeError` instead of an overflow of the thread, which would abort the process.
const STACK: usize = 8 << 20;

/// The room above [`STACK`] for the Rust frames. The engine checks only its own frames.
const THREAD_HEADROOM: usize = 2 << 20;

/// The stack of a thread that runs an engine: the stack of the engine and the room for the Rust frames.
pub const THREAD_STACK: usize = STACK + THREAD_HEADROOM;

/// The built-in module that adds the web globals, such as `AbortController`. It runs before any other module.
const WEB: &str = "yuke:internal/web";

/// The settings of a runtime.
#[derive(Clone)]
pub struct Options {
    /// The folder that keeps the JavaScript of each TypeScript file. The runtime makes it when it is missing.
    pub cache: PathBuf,

    /// The child processes of the tools. Give every JavaScript runtime of the process the same value, so a job
    /// outlives a reload.
    pub processes: Arc<Processes>,

    /// The models that the plugins call.
    pub models: Arc<dyn Models>,

    /// The sessions and the catalog that the plugins use.
    pub sessions: Arc<dyn Sessions>,

    /// The client of `fetch`. The consumer chooses its idle timeout. With none, only the signal stops a slow fetch.
    pub http: Arc<yuke_http::Client>,

    /// The terminal interface, or `None` for a runtime with no view, such as `yuke -p`. The runtime draws its frames
    /// on its display.
    pub interface: Option<Interface>,

    /// Let every module import the `yuke:internal/` modules. Only the runner of the tests of yuke sets it; a plugin
    /// can never import them.
    pub internal_imports: bool,

    /// The host of `createHost` in `yuke:test`, or `None` outside a test.
    pub test_host: Option<Arc<dyn TestHost>>,
}

impl fmt::Debug for Options {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Options")
            .field("cache", &self.cache)
            .field("processes", &self.processes)
            .field("http", &self.http)
            .field("interface", &self.interface)
            .field("internal_imports", &self.internal_imports)
            .field("test_host", &self.test_host.is_some())
            .finish_non_exhaustive()
    }
}

/// A call for the engine task. It receives the tool registry.
type Call = Box<dyn for<'js> FnOnce(Ctx<'js>, &Rc<Registry>)>;

/// A QuickJS runtime as a local task. Share it through an `Arc`. A drop asks the task to end and does not wait.
/// [`Runtime::shutdown`] waits.
pub struct Runtime {
    pub(crate) caller: Caller,
    /// The models of the plugins.
    pub(crate) models: Arc<dyn Models>,
    /// The drop of this sender ends the task. A tool keeps a clone of the caller, so the call channel can outlive the
    /// runtime.
    stop: oneshot::Sender<()>,
    /// Its drop stops each later stretch of JavaScript, so the task ends at its next poll.
    stopping: Stopping,
    /// The engine stops each stretch of JavaScript after this time. A busy loop holds the thread, so no timer can stop it.
    deadline: Arc<Mutex<Option<Instant>>>,
    /// Starts the frame loop with the snapshot of the start event. [`Runtime::show`] takes it.
    show: Option<oneshot::Sender<Option<String>>>,
    task: tokio::task::JoinHandle<()>,
}

impl fmt::Debug for Runtime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Runtime")
            .field("caller", &self.caller)
            .finish_non_exhaustive()
    }
}

/// The flag of the interrupt handler. A drop sets it, and the engine then stops each stretch of JavaScript.
#[derive(Debug)]
struct Stopping(Arc<AtomicBool>);

impl Drop for Stopping {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

/// A cheap clone of a [`Runtime`] that opens sessions.
#[derive(Clone)]
pub struct Handle {
    pub(crate) caller: Caller,
    pub(crate) models: Arc<dyn Models>,
}

impl fmt::Debug for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Handle")
            .field("caller", &self.caller)
            .finish_non_exhaustive()
    }
}

/// The sender of calls to the engine task. A tool keeps a clone, so its calls reach the task.
#[derive(Debug, Clone)]
pub(crate) struct Caller {
    calls: mpsc::UnboundedSender<Call>,
}

impl Runtime {
    /// Start the engine task on the local runtime of the caller. The receiver gets each [`Report`]: a script failure that belongs to no call, a notice
    /// or an event of a plugin, or a `console` entry.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when the engine does not start, and [`Error::Stopped`] when the task ends before it is
    /// ready.
    ///
    /// # Panics
    ///
    /// Panics outside a [`tokio::runtime::LocalRuntime`] or a [`tokio::task::LocalSet`].
    pub async fn start(options: Options) -> Result<(Self, mpsc::UnboundedReceiver<Report>), Error> {
        let models = Arc::clone(&options.models);
        let (calls, call_receiver) = mpsc::unbounded_channel();
        let (reports, report_receiver) = mpsc::unbounded_channel();
        let (ready, started) = oneshot::channel();
        let (stop, stopped) = oneshot::channel();
        let (show, shown) = oneshot::channel();
        let stopping = Arc::new(AtomicBool::new(false));
        let interrupt = Arc::clone(&stopping);
        let deadline = Arc::new(Mutex::new(None));

        // The engine runs as a local task of the host runtime, so the host and the JavaScript share one scheduler.
        let task = tokio::task::spawn_local(serve_calls(
            options,
            interrupt,
            Arc::clone(&deadline),
            call_receiver,
            stopped,
            shown,
            reports,
            ready,
        ));

        let runtime = Self {
            caller: Caller { calls },
            models,
            stop,
            stopping: Stopping(stopping),
            deadline,
            show: Some(show),
            task,
        };
        started.await.map_err(|_| Error::Stopped)??;
        Ok((runtime, report_receiver))
    }

    /// Import the module `name`: a built-in module such as `yuke:tools`, or the absolute path of a file. Wait for its
    /// evaluation, top-level `await` included.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when a module of the import graph fails to resolve, to load, or to evaluate.
    /// Returns [`Error::Stopped`] when the task has ended or ends during the import.
    pub async fn import(&self, name: &str) -> Result<(), Error> {
        let name = name.to_owned();
        self.caller
            .run(async move |ctx: Ctx<'_>, _registry: Rc<Registry>| {
                let promise = caught(&ctx, Module::import(&ctx, name))?;
                caught(&ctx, promise.into_future::<Value<'_>>().await)?;
                Ok(())
            })
            .await
    }

    /// Stop each later stretch of JavaScript. The task stays until [`Runtime::shutdown`].
    /// A test that runs past its time limit calls it, so a cleanup does not wait for the loop of the test.
    pub fn interrupt(&self) {
        self.stopping.0.store(true, Ordering::Relaxed);
    }

    /// Stop each stretch of JavaScript after `deadline`, or never with `None`.
    pub(crate) fn set_deadline(&self, deadline: Option<Instant>) {
        *self.deadline.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = deadline;
    }

    /// A handle that opens sessions on this runtime.
    pub fn handle(&self) -> Handle {
        Handle {
            caller: self.caller.clone(),
            models: Arc::clone(&self.models),
        }
    }

    /// Start the frame loop on the display. Its start event has `snapshot` when the argument is `Some`. The inputs and
    /// the frames follow. Until this call, the runtime draws nothing and takes no input, so a reload can load a new
    /// runtime while the old one draws. A second call, or a call without a display, does nothing.
    pub fn show(&mut self, snapshot: Option<String>) {
        if let Some(show) = self.show.take()
            && show.send(snapshot).is_err()
        {
            // The frame loop has ended: the runtime has no display, or it stopped.
        }
    }

    /// Stop the JavaScript and wait for the end of the task.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Panicked`] when the task panicked, and [`Error::Stopped`] when the tokio runtime of the caller
    /// ends during the wait.
    pub async fn shutdown(self) -> Result<(), Error> {
        let Self {
            caller,
            models: _,
            stop,
            stopping,
            deadline: _,
            show: _,
            task,
        } = self;
        drop(caller);
        drop(stopping);
        drop(stop);
        task.await.map_err(|error| {
            if !error.is_panic() {
                return Error::Stopped;
            }
            let panic = error.into_panic();
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
    /// Post `f` to the engine task without an answer. It runs to its end, unless the runtime stops first.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the task has ended.
    pub(crate) fn post<F>(&self, f: F) -> Result<(), Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) + 'static,
    {
        let call: Call = Box::new(move |ctx: Ctx<'_>, registry: &Rc<Registry>| {
            let registry = Rc::clone(registry);
            ctx.clone().spawn(async move { f(ctx, registry).await });
        });
        self.calls.send(call).map_err(|_| Error::Stopped)
    }

    /// Run `f` on the engine task, and return its answer. A drop of the returned future drops the future of `f` at
    /// its next await. Only an interrupt or a deadline stops a loop without an await.
    pub(crate) async fn run<F, R>(&self, f: F) -> Result<R, Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) -> Result<R, Error> + 'static,
        R: 'static,
    {
        let (mut reply, answer) = oneshot::channel();
        self.post(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
            tokio::select! {
                result = f(ctx, registry) => {
                    if reply.send(result).is_err() {
                        // The caller has left.
                    }
                }
                () = reply.closed() => {}
            }
        })?;
        answer.await.map_err(|_| Error::Stopped)?
    }
}

#[expect(clippy::too_many_arguments, reason = "the task takes each part of its start")]
async fn serve_calls(
    options: Options,
    stopping: Arc<AtomicBool>,
    deadline: Arc<Mutex<Option<Instant>>>,
    mut calls: mpsc::UnboundedReceiver<Call>,
    mut stopped: oneshot::Receiver<()>,
    shown: oneshot::Receiver<Option<String>>,
    reports: mpsc::UnboundedSender<Report>,
    ready: oneshot::Sender<Result<(), Error>>,
) {
    let engine = match Engine::new(options, stopping, deadline, shown, reports.clone()).await {
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

    // The drive runs the promise reactions and the spawned futures. It holds the runtime, so it drops before the engine.
    let mut drive = pin!(engine.runtime.drive());
    loop {
        tokio::select! {
            _ = &mut stopped => break,
            call = calls.recv() => match call {
                Some(call) => engine.context.with(|ctx| call(ctx, &engine.registry)).await,
                None => break,
            },
            () = std::future::poll_fn(|context| {
                // The drive ends only with the runtime, and the runtime outlives it.
                let polled = drive.as_mut().poll(context);
                debug_assert!(polled.is_pending());
                // A poll can end before it runs each job: the lock is busy, or the futures yield. So a rejection gets
                // the next poll too, and a handler that comes in it is in time. A rejection that waits wakes the drive.
                let mut pending = engine.rejections.pending.borrow_mut();
                for (_, error, _) in pending.extract_if(.., |(_, _, seen)| *seen) {
                    if reports.send(Report::Fault(error)).is_err() {
                        // The owner dropped the receiver, so it ignores faults.
                    }
                }
                if !pending.is_empty() {
                    for (_, _, seen) in pending.iter_mut() {
                        *seen = true;
                    }
                    context.waker().wake_by_ref();
                }
                Poll::Pending
            }) => {}
        }
    }
}

/// The engine of the task, and the state that its callbacks share.
struct Engine {
    context: AsyncContext,
    runtime: AsyncRuntime,
    rejections: Rc<Rejections>,
    timers: Rc<Timers>,
    registry: Rc<Registry>,
    frames: Rc<Frames>,
}

impl Engine {
    async fn new(
        options: Options,
        stopping: Arc<AtomicBool>,
        deadline: Arc<Mutex<Option<Instant>>>,
        shown: oneshot::Receiver<Option<String>>,
        reports: mpsc::UnboundedSender<Report>,
    ) -> Result<Self, Error> {
        let engine_error = |error: rquickjs::Error| Error::Script(ScriptError::from_engine(&error));
        let runtime = AsyncRuntime::new().map_err(engine_error)?;
        runtime.set_max_stack_size(STACK).await;
        runtime
            .set_loader(
                NameResolver {
                    internal_imports: options.internal_imports,
                },
                ModuleLoader::new(Cache::new(options.cache.clone())),
            )
            .await;
        // The engine asks once for each 10,000 interrupt checks.
        runtime
            .set_interrupt_handler(Some(Box::new(move || {
                stopping.load(Ordering::Relaxed)
                    || deadline
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .is_some_and(|deadline| Instant::now() >= deadline)
            })))
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
        let registry = Rc::new(Registry::new(Arc::clone(&options.processes)));
        let frames = Rc::new(Frames::new(options.interface.clone()));
        context
            .with(|ctx| {
                timers::install(&ctx, &timers, reports.clone())?;
                crate::error::install_report_error(&ctx, reports.clone())?;
                native::install(&ctx, &registry, &options, &frames, reports.clone())?;
                ctx.spawn(drive(ctx.clone(), Rc::clone(&frames), shown, reports));
                Ok(())
            })
            .await
            .map_err(engine_error)?;
        context
            .with(|ctx| {
                let promise = caught(&ctx, Module::import(&ctx, WEB))?;
                caught(&ctx, promise.finish::<Value<'_>>()).map(drop)
            })
            .await?;

        Ok(Self {
            context,
            runtime,
            rejections,
            timers,
            registry,
            frames,
        })
    }
}

impl Drop for Engine {
    /// Drop each saved value before the fields drop the context and the runtime: a saved value that outlives the
    /// runtime aborts the process. A panic of the task drops the engine this way too.
    fn drop(&mut self) {
        self.timers.clear();
        self.registry.clear();
        self.frames.clear();
        self.rejections.pending.borrow_mut().clear();
    }
}

/// The promise rejections that no handler took yet, each with a mark that one poll of the drive ended after it.
#[derive(Debug, Default)]
struct Rejections {
    pending: RefCell<Vec<(Persistent<Value<'static>>, ScriptError, bool)>>,
}

impl Rejections {
    fn track<'js>(&self, ctx: &Ctx<'js>, promise: Value<'js>, reason: &Value<'js>, handled: bool) {
        let promise = Persistent::save(ctx, promise);
        if handled {
            self.pending
                .borrow_mut()
                .retain(|(rejected, _, _)| *rejected != promise);
        } else {
            // The conversion can run a getter that rejects another promise and calls this function again. So the
            // conversion comes before the borrow of `pending`.
            let error = ScriptError::from_value(ctx, reason);
            self.pending.borrow_mut().push((promise, error, false));
        }
    }
}
