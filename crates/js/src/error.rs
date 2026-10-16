//! The errors of the runtime, and the conversion of a thrown JavaScript value into a Rust value.

use std::fmt;

use rquickjs::{CatchResultExt, CaughtError, Coerced, Constructor, Ctx, Exception, FromJs, Function, Value};
use tokio::sync::mpsc;

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
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Script(error) => error.fmt(f),
            Self::Stopped => f.write_str("the JavaScript thread has ended"),
            // The text names no cause, because `source` returns it.
            Self::Thread(_) => f.write_str("the JavaScript thread did not start"),
            Self::Panicked(message) => write!(f, "the JavaScript thread panicked: {message}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            // The text is the text of the inner error, so the source is the source of the inner error.
            Self::Script(error) => error.source(),
            Self::Thread(error) => Some(error),
            Self::Stopped | Self::Panicked(_) => None,
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
    /// Copy the thrown `value` out of the engine.
    pub(crate) fn from_value<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> Self {
        match value.as_object().cloned().and_then(Exception::from_object) {
            Some(exception) => Self {
                name: text_of(ctx, &exception, "name"),
                message: text_of(ctx, &exception, "message").unwrap_or_default(),
                stack: text_of(ctx, &exception, "stack"),
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
pub(crate) fn install_report_error<'js>(
    ctx: &Ctx<'js>,
    faults: mpsc::UnboundedSender<ScriptError>,
) -> rquickjs::Result<()> {
    let report = Function::new(ctx.clone(), move |ctx: Ctx<'js>, error: Value<'js>| {
        if faults.send(ScriptError::from_value(&ctx, &error)).is_err() {
            // The owner dropped the receiver, so it ignores faults.
        }
    })?;
    ctx.globals().set("reportError", report)
}

/// Throw a new error of the global class `class`, for example `TypeError`, with `message`. The typed throws of the
/// engine cut a message at 255 bytes. A constructed error keeps all of it.
pub(crate) fn throw(ctx: &Ctx<'_>, class: &str, message: &str) -> rquickjs::Error {
    let built = ctx
        .globals()
        .get::<_, Constructor<'_>>(class)
        .and_then(|constructor| constructor.construct::<_, Value<'_>>((message,)));
    match built {
        Ok(error) => ctx.throw(error),
        Err(error) => error,
    }
}
