//! The JavaScript engine and the local task that drives it.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::future::Future;
use std::path::PathBuf;
use std::pin::pin;
use std::rc::{Rc, Weak};
use std::sync::Arc;
use std::task::Poll;
use std::time::Instant;

use rquickjs::{AsyncContext, AsyncRuntime, Ctx, Module, Persistent, Value};
use tokio::sync::{Notify, mpsc, oneshot};

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
    /// The version of the running host. Plugins read it from their context without starting another process.
    pub version: String,
    /// The folder that keeps the JavaScript of each TypeScript file. The runtime makes it when it is missing.
    pub cache: PathBuf,

    /// The child processes of the tools. Give every JavaScript runtime of the process the same value, so a job
    /// outlives a reload.
    pub processes: Rc<Processes>,

    /// The models that the plugins call.
    pub models: Rc<dyn Models>,

    /// The sessions and the catalog that the plugins use.
    pub sessions: Rc<dyn Sessions>,

    /// The client of `fetch`. The consumer chooses its idle timeout. With none, only the signal stops a slow fetch.
    pub http: Arc<yuke_http::Client>,

    /// The terminal interface, or `None` for a runtime with no view, such as `yuke -p`. The runtime draws its frames
    /// on its display.
    pub interface: Option<Interface>,

    /// Let every module import the `yuke:internal/` modules. Only the runner of the tests of yuke sets it; a plugin
    /// can never import them.
    pub internal_imports: bool,

    /// The host of `createHost` in `yuke:test`, or `None` outside a test.
    pub test_host: Option<Rc<dyn TestHost>>,
}

impl fmt::Debug for Options {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Options")
            .field("version", &self.version)
            .field("cache", &self.cache)
            .field("processes", &self.processes)
            .field("http", &self.http)
            .field("interface", &self.interface)
            .field("internal_imports", &self.internal_imports)
            .field("test_host", &self.test_host.is_some())
            .finish_non_exhaustive()
    }
}

/// A QuickJS runtime with a local drive task. A drop of the runtime asks the task to stop and does not wait.
/// [`Runtime::shutdown`] waits.
pub struct Runtime {
    access: EngineAccess,
    /// The models of the plugins.
    pub(crate) models: Rc<dyn Models>,
    /// Its drop asks the drive task to stop. Handles can still exist.
    stop: oneshot::Sender<()>,
    /// Its drop stops each later stretch of JavaScript, so the task ends at its next poll.
    stopping: Stopping,
    /// The engine stops each stretch of JavaScript after this time. A busy loop holds the thread, so no timer can stop it.
    deadline: Rc<Cell<Option<Instant>>>,
    /// Starts the frame loop with the snapshot of the start event. [`Runtime::show`] takes it.
    show: Option<oneshot::Sender<Option<String>>>,
    task: tokio::task::JoinHandle<()>,
}

impl fmt::Debug for Runtime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Runtime")
            .field("access", &self.access())
            .finish_non_exhaustive()
    }
}

/// The flag of the interrupt handler. A drop sets it, and the engine then stops each stretch of JavaScript.
#[derive(Debug)]
struct Stopping(Rc<Cell<bool>>);

impl Drop for Stopping {
    fn drop(&mut self) {
        self.0.set(true);
    }
}

/// A weak handle that opens sessions on a runtime.
#[derive(Clone)]
pub struct Handle {
    pub(crate) access: EngineAccess,
    pub(crate) models: Rc<dyn Models>,
}

impl fmt::Debug for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Handle")
            .field("access", &self.access)
            .finish_non_exhaustive()
    }
}

/// Weak access to the engine. Script handles can outlive the engine.
#[derive(Debug, Clone)]
pub(crate) struct EngineAccess {
    pub(crate) engine: Weak<Engine>,
}

impl Runtime {
    /// Build the engine and start its local drive task. The receiver gets each [`Report`]: a script failure that
    /// belongs to no call, a notice or an event of a plugin, or a `console` entry.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when the engine does not start.
    ///
    /// # Panics
    ///
    /// Panics outside a [`tokio::runtime::LocalRuntime`] or a [`tokio::task::LocalSet`].
    pub async fn start(options: Options) -> Result<(Self, mpsc::UnboundedReceiver<Report>), Error> {
        let models = Rc::clone(&options.models);
        let (reports, report_receiver) = mpsc::unbounded_channel();
        let (stop, stopped) = oneshot::channel();
        let (show, shown) = oneshot::channel();
        let stopping = Rc::new(Cell::new(false));
        let deadline = Rc::new(Cell::new(None));
        let engine = Rc::new(
            Engine::new(
                options,
                Rc::clone(&stopping),
                Rc::clone(&deadline),
                shown,
                reports.clone(),
            )
            .await?,
        );
        let access = EngineAccess {
            engine: Rc::downgrade(&engine),
        };
        let task = tokio::task::spawn_local(drive_engine(engine, stopped, reports));

        let runtime = Self {
            access,
            models,
            stop,
            stopping: Stopping(stopping),
            deadline,
            show: Some(show),
            task,
        };
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
        self.access()
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
        self.stopping.0.set(true);
    }

    /// Stop each stretch of JavaScript after `deadline`, or never with `None`.
    pub(crate) fn set_deadline(&self, deadline: Option<Instant>) {
        self.deadline.set(deadline);
    }

    pub(crate) fn access(&self) -> EngineAccess {
        self.access.clone()
    }

    /// A handle that opens sessions on this runtime.
    pub fn handle(&self) -> Handle {
        Handle {
            access: self.access(),
            models: Rc::clone(&self.models),
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
            access: _,
            models: _,
            stop,
            stopping,
            deadline: _,
            show: _,
            task,
        } = self;
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

impl EngineAccess {
    pub(crate) fn close_session(&self, open: u64) {
        let Some(engine) = self.engine.upgrade() else {
            // The engine is gone, so no plugin of the session runs.
            return;
        };
        engine.sessions_to_close.borrow_mut().push(open);
        engine.close_requested.notify_one();
    }

    /// Launch `f` on the engine with no result. The engine runs `f` until it ends or the engine stops.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the engine has ended.
    pub(crate) async fn post<F>(&self, f: F) -> Result<(), Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) + 'static,
    {
        let engine = self.engine.upgrade().ok_or(Error::Stopped)?;
        engine
            .context
            .with(|ctx| {
                engine.close_sessions(&ctx);
                let registry = Rc::clone(&engine.registry);
                ctx.clone().spawn(async move { f(ctx, registry).await });
            })
            .await;
        Ok(())
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
        })
        .await?;
        answer.await.map_err(|_| Error::Stopped)?
    }
}

async fn drive_engine(engine: Rc<Engine>, mut stopped: oneshot::Receiver<()>, reports: mpsc::UnboundedSender<Report>) {
    // The drive runs the promise reactions and the spawned futures. It holds the runtime, so it drops before the engine.
    let mut drive = pin!(engine.runtime.drive());
    loop {
        engine.context.with(|ctx| engine.close_sessions(&ctx)).await;
        tokio::select! {
            _ = &mut stopped => break,
            () = engine.close_requested.notified() => {},
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
pub(crate) struct Engine {
    context: AsyncContext,
    runtime: AsyncRuntime,
    rejections: Rc<Rejections>,
    timers: Rc<Timers>,
    registry: Rc<Registry>,
    frames: Rc<Frames>,
    sessions_to_close: RefCell<Vec<u64>>,
    close_requested: Notify,
}

impl Engine {
    fn close_sessions(&self, ctx: &Ctx<'_>) {
        let sessions = self.sessions_to_close.take();
        for open in sessions {
            if crate::session::close_dropped(ctx, &self.registry, open).is_err() {
                // Only the end of the engine fails the close, and that end drops the plugins too.
            }
        }
    }

    async fn new(
        options: Options,
        stopping: Rc<Cell<bool>>,
        deadline: Rc<Cell<Option<Instant>>>,
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
                stopping.get() || deadline.get().is_some_and(|deadline| Instant::now() >= deadline)
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
        let registry = Rc::new(Registry::new(Rc::clone(&options.processes)));
        let frames = Rc::new(Frames::new(options.interface.clone()));
        let engine = Self {
            context,
            runtime,
            rejections,
            timers,
            registry,
            frames,
            sessions_to_close: RefCell::new(Vec::new()),
            close_requested: Notify::new(),
        };
        engine
            .context
            .with(|ctx| {
                timers::install(&ctx, &engine.timers, reports.clone())?;
                crate::error::install_report_error(&ctx, reports.clone())?;
                native::install(&ctx, &engine.registry, &options, &engine.frames, reports.clone())?;
                ctx.spawn(drive(ctx.clone(), Rc::clone(&engine.frames), shown, reports));
                Ok(())
            })
            .await
            .map_err(engine_error)?;
        engine
            .context
            .with(|ctx| {
                let promise = caught(&ctx, Module::import(&ctx, WEB))?;
                caught(&ctx, promise.finish::<Value<'_>>()).map(drop)
            })
            .await?;

        Ok(engine)
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
