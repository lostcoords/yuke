//! The JavaScript thread. One OS thread owns the engine, because the engine values are not `Send`. Callers on other
//! threads send it calls through a channel and await the answers.

use std::cell::RefCell;
use std::fmt;
use std::future::Future;
use std::path::PathBuf;
use std::pin::pin;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::Poll;
use std::thread::JoinHandle;

use rquickjs::{AsyncContext, AsyncRuntime, Ctx, Module, Persistent, Value};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};

use crate::error::{Error, Report, ScriptError, caught};
use crate::loader::{ModuleLoader, NameResolver};
use crate::models::{Models, OnConsumer};
use crate::native;
use crate::processes::Processes;
use crate::strip::Cache;
use crate::timers::{self, Timers};
use crate::tools::Registry;

/// The stack that the engine gives the JavaScript. The engine checks it, so a deep recursion throws a catchable
/// `RangeError` instead of an overflow of the thread, which would abort the process.
const STACK: usize = 8 << 20;

/// The stack of the JavaScript thread above [`STACK`]. The engine checks only its own frames, so the thread needs room
/// for the Rust frames too.
const THREAD_HEADROOM: usize = 2 << 20;

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
}

impl fmt::Debug for Options {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Options")
            .field("cache", &self.cache)
            .field("processes", &self.processes)
            .finish_non_exhaustive()
    }
}

/// A call for the JavaScript thread. It receives the tool registry.
type Call = Box<dyn for<'js> FnOnce(Ctx<'js>, &Rc<Registry>) + Send>;

/// A QuickJS runtime on its own thread. Share it through an `Arc`. A drop asks the thread to end and does not wait;
/// [`Runtime::shutdown`] waits.
pub struct Runtime {
    pub(crate) caller: Caller,
    /// The models of the plugins, on the runtime of the consumer.
    pub(crate) models: Arc<dyn Models>,
    /// The drop of this sender ends the thread. A tool keeps a clone of the caller, so the call channel can outlive the
    /// runtime.
    stop: oneshot::Sender<()>,
    /// Its drop stops the JavaScript that runs, so the thread can end even inside a loop without an `await`.
    stopping: Stopping,
    thread: JoinHandle<()>,
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

/// The sender of calls to the JavaScript thread. A tool keeps a clone, so its calls reach the thread.
#[derive(Debug, Clone)]
pub(crate) struct Caller {
    calls: mpsc::UnboundedSender<Call>,
}

impl Runtime {
    /// Start the JavaScript thread. The receiver gets each [`Report`]: a script failure that belongs to no call, or a
    /// notice of a plugin.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Thread`] when the thread or its tokio runtime does not start. Returns [`Error::Script`] when the
    /// engine does not start, and [`Error::Stopped`] when the thread ends before it is ready.
    pub async fn start(options: Options) -> Result<(Self, mpsc::UnboundedReceiver<Report>), Error> {
        let options = Options {
            models: Arc::new(OnConsumer {
                models: options.models,
                handle: Handle::current(),
            }),
            ..options
        };
        let models = Arc::clone(&options.models);
        let (calls, call_receiver) = mpsc::unbounded_channel();
        let (faults, fault_receiver) = mpsc::unbounded_channel();
        let (ready, started) = oneshot::channel();
        let (stop, stopped) = oneshot::channel();
        let stopping = Arc::new(AtomicBool::new(false));
        let interrupt = Arc::clone(&stopping);

        let thread = std::thread::Builder::new()
            .name("yuke-js".into())
            .stack_size(STACK + THREAD_HEADROOM)
            .spawn(move || serve(options, interrupt, call_receiver, stopped, faults, ready))
            .map_err(Error::Thread)?;

        let runtime = Self {
            caller: Caller { calls },
            models,
            stop,
            stopping: Stopping(stopping),
            thread,
        };
        started.await.map_err(|_| Error::Stopped)??;
        Ok((runtime, fault_receiver))
    }

    /// Import the module `name`: a built-in module such as `yuke:tools`, or the absolute path of a file. Wait for its
    /// evaluation, top-level `await` included.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when a module of the import graph fails to resolve, to load, or to evaluate.
    /// Returns [`Error::Stopped`] when the thread has ended or ends during the import.
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

    /// Stop the JavaScript and wait for the end of the thread. The JavaScript that runs stops, also inside a loop.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Panicked`] when the thread panicked, and [`Error::Stopped`] when the tokio runtime of the caller
    /// ends during the wait.
    pub async fn shutdown(self) -> Result<(), Error> {
        let Self {
            caller,
            models: _,
            stop,
            stopping,
            thread,
        } = self;
        drop(caller);
        drop(stopping);
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
    /// Post `f` to the JavaScript thread without an answer. It runs to its end, unless the runtime stops first.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended.
    pub(crate) fn post<F>(&self, f: F) -> Result<(), Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) + Send + 'static,
    {
        let call: Call = Box::new(move |ctx: Ctx<'_>, registry: &Rc<Registry>| {
            let registry = Rc::clone(registry);
            ctx.clone().spawn(async move { f(ctx, registry).await });
        });
        self.calls.send(call).map_err(|_| Error::Stopped)
    }

    /// Run `f` on the JavaScript thread, and return its answer. A drop of the returned future drops the future of `f` at
    /// its next await. Only the end of the runtime stops a loop without an await.
    pub(crate) async fn run<F, R>(&self, f: F) -> Result<R, Error>
    where
        F: for<'js> AsyncFnOnce(Ctx<'js>, Rc<Registry>) -> Result<R, Error> + Send + 'static,
        R: Send + 'static,
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

/// The body of the JavaScript thread.
fn serve(
    options: Options,
    stopping: Arc<AtomicBool>,
    calls: mpsc::UnboundedReceiver<Call>,
    stopped: oneshot::Receiver<()>,
    faults: mpsc::UnboundedSender<Report>,
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
    tokio_runtime.block_on(serve_calls(options, stopping, calls, stopped, faults, ready));
}

async fn serve_calls(
    options: Options,
    stopping: Arc<AtomicBool>,
    mut calls: mpsc::UnboundedReceiver<Call>,
    mut stopped: oneshot::Receiver<()>,
    faults: mpsc::UnboundedSender<Report>,
    ready: oneshot::Sender<Result<(), Error>>,
) {
    let engine = match Engine::new(options, stopping, faults.clone()).await {
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
                // A rejection that got no handler in this poll is a fault. A later handler comes too late.
                for (_, error) in engine.rejections.pending.take() {
                    if faults.send(Report::Fault(error)).is_err() {
                        // The owner dropped the receiver, so it ignores faults.
                    }
                }
                Poll::Pending
            }) => {}
        }
    }
}

/// The engine of the thread, and the state that its callbacks share.
struct Engine {
    context: AsyncContext,
    runtime: AsyncRuntime,
    rejections: Rc<Rejections>,
    timers: Rc<Timers>,
    registry: Rc<Registry>,
}

impl Engine {
    async fn new(
        options: Options,
        stopping: Arc<AtomicBool>,
        faults: mpsc::UnboundedSender<Report>,
    ) -> Result<Self, Error> {
        let engine_error = |error: rquickjs::Error| Error::Script(ScriptError::from_engine(&error));
        let runtime = AsyncRuntime::new().map_err(engine_error)?;
        runtime.set_max_stack_size(STACK).await;
        runtime
            .set_loader(NameResolver, ModuleLoader::new(Cache::new(options.cache)))
            .await;
        // The engine asks once for each 10,000 interrupt checks. Only the end of the runtime stops the JavaScript.
        runtime
            .set_interrupt_handler(Some(Box::new(move || stopping.load(Ordering::Relaxed))))
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
        context
            .with(|ctx| {
                // The error constructors come before the natives, so each native throws with the constructors of the start.
                crate::error::install_error_classes(&ctx)?;
                timers::install(&ctx, &timers, faults.clone())?;
                crate::error::install_report_error(&ctx, faults.clone())?;
                native::install(&ctx, &registry, &options.processes, &options.models, faults)
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

/// The promise rejections that no handler took yet.
#[derive(Debug, Default)]
struct Rejections {
    pending: RefCell<Vec<(Persistent<Value<'static>>, ScriptError)>>,
}

impl Rejections {
    fn track<'js>(&self, ctx: &Ctx<'js>, promise: Value<'js>, reason: &Value<'js>, handled: bool) {
        let promise = Persistent::save(ctx, promise);
        if handled {
            self.pending.borrow_mut().retain(|(rejected, _)| *rejected != promise);
        } else {
            // The conversion can run a getter that rejects another promise and calls this function again. So the
            // conversion comes before the borrow of `pending`.
            let error = ScriptError::from_value(ctx, reason);
            self.pending.borrow_mut().push((promise, error));
        }
    }
}
