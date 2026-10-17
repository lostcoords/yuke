//! The JavaScript runtime of yuke: the QuickJS engine on its own thread. Callers on any thread import modules through
//! a channel.
//!
//! A module is a built-in module with a `yuke:` name, or a `.ts` or a `.js` file. The built-in modules are bytecode in
//! the binary. The runtime removes the types of a `.ts` file and keeps the JavaScript in a cache folder. The globals
//! add web APIs to the language: timers, `reportError`, events and abort signals, `TextEncoder` and `TextDecoder`,
//! `console`, and `performance`. The runtime sets no heap and no time limit. It checks the stack
//! of the JavaScript, so a deep recursion throws and does not crash the thread. A shutdown stops running JavaScript.
//!
//! A tool that a plugin defines with `ctx.tools.define` is an engine tool: [`Runtime::tools`] gives each one as a
//! [`ScriptTool`] for the session of a [`SessionHost`]. `yuke:internal/builtins` defines the tools `read`, `write`, `edit`,
//! `exec`, and `stop`. [`Processes`] runs the commands and the background jobs on the tokio runtime of the consumer,
//! so a job outlives a reload of the JavaScript.

mod baked;
mod bytes;
mod error;
mod loader;
mod native;
mod plugins;
mod processes;
mod runtime;
mod strip;
#[cfg(test)]
mod tests;
mod timers;
mod tools;
mod typescript;

pub use error::{Error, Report, ScriptError};
pub use plugins::{Plugin, PluginError, PluginFailure};
pub use processes::{JobEnded, Processes, shell};
pub use runtime::{Options, Runtime};
pub use tools::{ScriptTool, SessionHost};
