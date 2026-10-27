//! The errors of the runtime, and the conversion of a thrown JavaScript value into a Rust value.

use std::fmt;

use rquickjs::{CatchResultExt, CaughtError, Coerced, Constructor, Ctx, Exception, FromJs, Function, Object, Value};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::{mpsc, oneshot};

/// The failure of a call into the runtime.
#[derive(Debug)]
pub enum Error {
    /// The JavaScript threw, or the engine refused the operation.
    Script(ScriptError),

    /// The JavaScript thread has ended.
    Stopped,

    /// The JavaScript thread or its tokio runtime did not start.
    Thread(std::io::Error),

    /// The JavaScript thread panicked. The text is the message of the panic.
    Panicked(String),

    /// The workspace folder of a session is not UTF-8, so the JavaScript cannot name it.
    Folder(std::path::PathBuf),
}

/// What the runtime reports outside of a call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Report {
    /// A timer callback threw, or a promise rejection got no handler in the drive that settled it.
    Fault(ScriptError),
    /// A plugin sent a notice, or the setup or the cleanup of the session of a plugin failed.
    Notice(yuke_protocol::NoticeParams),
    /// A plugin sent an event for the clients.
    Event(yuke_protocol::ExtensionEventParams),
    /// A test host waits until the consumer got each report before this one. The consumer calls [`Barrier::release`].
    Barrier(Barrier),
    /// A script wrote an entry with `console`. The host shows it as a notice from the source `console`.
    Console {
        /// `debug` for `console.log` and `console.debug`. `info`, `warn`, and `error` for the methods of those names.
        level: yuke_protocol::NoticeLevel,
        /// The formatted entry. An error gives its stack frames on more lines.
        text: String,
    },
}

/// The release of a wait for the reports before it. A clone releases the same wait.
#[derive(Clone)]
pub struct Barrier(Arc<Mutex<Option<oneshot::Sender<()>>>>);

impl Barrier {
    /// A barrier, and the wait that its release ends.
    pub(crate) fn new() -> (Self, oneshot::Receiver<()>) {
        let (sender, receiver) = oneshot::channel();
        (Barrier(Arc::new(Mutex::new(Some(sender)))), receiver)
    }

    /// End the wait. A second release does nothing.
    pub fn release(&self) {
        if let Some(sender) = self.0.lock().unwrap_or_else(PoisonError::into_inner).take()
            && sender.send(()).is_err()
        {
            // The waiter has left.
        }
    }
}

impl fmt::Debug for Barrier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Barrier")
    }
}

impl PartialEq for Barrier {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

impl Eq for Barrier {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Script(error) => error.fmt(f),
            Self::Stopped => f.write_str("the JavaScript thread has ended"),
            // The text names no cause, because `source` returns it.
            Self::Thread(_) => f.write_str("the JavaScript thread did not start"),
            Self::Panicked(message) => write!(f, "the JavaScript thread panicked: {message}"),
            Self::Folder(folder) => write!(f, "the workspace folder {} is not UTF-8", folder.display()),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            // The text is the text of the inner error, so the source is the source of the inner error.
            Self::Script(error) => error.source(),
            Self::Thread(error) => Some(error),
            Self::Stopped | Self::Panicked(_) | Self::Folder(_) => None,
        }
    }
}

/// A thrown JavaScript value, copied out of the engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptError {
    /// The `name` of a thrown `Error`, for example `TypeError`. A throw of another value and a failure of the engine
    /// have no name.
    pub name: Option<String>,

    /// The `message` of a thrown `Error`, or the string form of another thrown value.
    pub message: String,

    /// The `stack` of a thrown `Error`. Each frame names its module, line, and column.
    pub stack: Option<String>,
}

impl ScriptError {
    /// Throw this error again in `ctx`: an error of the global class of its name, with its message and its stack. An
    /// error without a name, or with the name of no class, is an `Error`.
    pub(crate) fn rethrow(&self, ctx: &Ctx<'_>) -> rquickjs::Error {
        let globals = ctx.globals();
        let built = self
            .name
            .as_deref()
            .and_then(|name| globals.get::<_, Constructor<'_>>(name).ok())
            .map_or_else(|| globals.get::<_, Constructor<'_>>("Error"), Ok)
            .and_then(|class| class.construct::<_, Object<'_>>((self.message.as_str(),)))
            .and_then(|error| {
                if let Some(stack) = &self.stack {
                    error.set("stack", stack.as_str())?;
                }
                Ok(error)
            });
        match built {
            Ok(error) => ctx.throw(error.into_value()),
            Err(error) => error,
        }
    }

    /// Copy the thrown `value` out of the engine.
    pub(crate) fn from_value<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> Self {
        match value.as_object().cloned().and_then(Exception::from_object) {
            // The error of `using` has an empty message, so its text names the error that it suppressed and its own.
            Some(exception) if text_of(ctx, &exception, "name").as_deref() == Some("SuppressedError") => {
                let part = |key: &str| {
                    if let Ok(value) = exception.get::<_, Value<'js>>(key) {
                        return Self::from_value(ctx, &value).to_string();
                    }
                    // The getter left its own exception, which belongs to no caller.
                    drop(ctx.catch());
                    String::new()
                };
                Self {
                    name: Some("SuppressedError".to_owned()),
                    message: format!("{}\nThen a disposal threw: {}", part("suppressed"), part("error")),
                    stack: None,
                }
            }
            Some(exception) => Self {
                name: text_of(ctx, &exception, "name"),
                message: text_of(ctx, &exception, "message").unwrap_or_default(),
                // An error that the host makes has no frame, and its stack is empty.
                stack: text_of(ctx, &exception, "stack").filter(|stack| !stack.trim().is_empty()),
            },
            None => Self {
                name: None,
                message: string_form(ctx, value),
                stack: None,
            },
        }
    }

    /// An error of the engine that is not a JavaScript throw, for example a failed conversion.
    pub(crate) fn from_engine(error: &rquickjs::Error) -> Self {
        Self {
            name: None,
            message: error.to_string(),
            stack: None,
        }
    }
}

impl fmt::Display for ScriptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(name) = &self.name {
            write!(f, "{name}: ")?;
        }
        f.write_str(&self.message)?;
        if let Some(stack) = &self.stack {
            write!(f, "\n{}", stack.trim_end())?;
        }
        Ok(())
    }
}

impl std::error::Error for ScriptError {}

/// The text property `key` of a thrown `Error`. A getter that throws gives no text.
fn text_of<'js>(ctx: &Ctx<'js>, exception: &Exception<'js>, key: &str) -> Option<String> {
    if let Ok(text) = exception.get::<_, Option<String>>(key) {
        return text;
    }
    // The getter left its own exception, which belongs to no caller.
    drop(ctx.catch());
    None
}

/// The string form of a thrown value that is not an `Error`. A conversion that throws gives the debug form.
fn string_form<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> String {
    if let Ok(Coerced(text)) = Coerced::<String>::from_js(ctx, value.clone()) {
        return text;
    }
    // The conversion left its own exception, which belongs to no caller.
    drop(ctx.catch());
    format!("{value:?}")
}

/// Turn the result of an engine call into a runtime result. An interrupt at the shutdown of the runtime becomes
/// [`Error::Stopped`].
pub(crate) fn caught<T>(ctx: &Ctx<'_>, result: rquickjs::Result<T>) -> Result<T, Error> {
    result.catch(ctx).map_err(|error| match error {
        CaughtError::Exception(exception) if exception.as_value().is_uncatchable_error() => Error::Stopped,
        CaughtError::Exception(exception) => Error::Script(ScriptError::from_value(ctx, exception.as_value())),
        CaughtError::Value(value) if value.is_uncatchable_error() => Error::Stopped,
        CaughtError::Value(value) => Error::Script(ScriptError::from_value(ctx, &value)),
        CaughtError::Error(error) => Error::Script(ScriptError::from_engine(&error)),
    })
}

/// Add the global `reportError(error)` of the web: it reports `error` as a fault without a throw.
pub(crate) fn install_report_error<'js>(ctx: &Ctx<'js>, faults: mpsc::UnboundedSender<Report>) -> rquickjs::Result<()> {
    let report = Function::new(ctx.clone(), move |ctx: Ctx<'js>, error: Value<'js>| {
        if faults
            .send(Report::Fault(ScriptError::from_value(&ctx, &error)))
            .is_err()
        {
            // The owner dropped the receiver, so it ignores faults.
        }
    })?;
    ctx.globals().set("reportError", report)
}

/// The class of an error that a native throws.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ErrorClass {
    Error,
    TypeError,
    SyntaxError,
}

impl ErrorClass {
    /// The name of the global constructor of the class.
    fn name(self) -> &'static str {
        match self {
            Self::Error => "Error",
            Self::TypeError => "TypeError",
            Self::SyntaxError => "SyntaxError",
        }
    }
}

/// Throw a new error of `class` with `message`. A constructed error keeps the whole message, and a typed throw of the
/// engine cuts it at 255 bytes.
pub(crate) fn throw(ctx: &Ctx<'_>, class: ErrorClass, message: &str) -> rquickjs::Error {
    let built = ctx
        .globals()
        .get::<_, Constructor<'_>>(class.name())
        .and_then(|constructor| constructor.construct::<_, Value<'_>>((message,)));
    match built {
        Ok(error) => ctx.throw(error),
        Err(error) => error,
    }
}
