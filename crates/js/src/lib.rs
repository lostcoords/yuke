//! The JavaScript runtime of yuke: the QuickJS engine on its own thread. Callers on any thread import modules through
//! a channel.
//!
//! A module is a built-in module with a `yuke:` name, or a `.ts` or a `.js` file. The built-in modules are bytecode in
//! the binary. The runtime removes the types of a `.ts` file and keeps the JavaScript in a cache folder. The globals
//! add web APIs to the language: timers, `reportError`, events and abort signals, `TextEncoder` and `TextDecoder`,
//! `URL` and `URLSearchParams`, `ReadableStream`, `fetch` with `Headers`, `Request`, and `Response`, `console`, and
//! `performance`. The public modules are `yuke:tools`, `yuke:plugins`, `yuke:fs` (files), `yuke:process` (programs),
//! and `yuke:ai` (model requests). The runtime sets no heap and no time limit. It checks the stack of the JavaScript,
//! so a deep recursion throws and does not crash the thread. A shutdown stops running JavaScript and each running
//! program.
//!
//! A plugin runs `apply` once per runtime and `session` once per session. [`Handle::open_session`] opens the session
//! of a [`SessionHost`]. [`ScriptSession::tools`] gives each tool of that session as a [`ScriptTool`]: the tools of
//! yuke and the tools that the `session` exports define. `yuke:internal/builtins` defines the tools `read`, `write`,
//! `edit`, `exec`, and `stop`. [`Processes`] runs the commands and the background jobs on the tokio runtime of the consumer,
//! so a job outlives a reload of the JavaScript. The consumer gives the [`Models`] that the plugins call.

mod baked;
mod bytes;
mod display;
mod error;
mod loader;
mod models;
mod native;
mod plugins;
mod processes;
mod runtime;
mod session;
mod strip;
#[cfg(test)]
mod tests;
mod timers;
mod tools;
mod typescript;

pub use display::{Display, Input, Request};
pub use error::{Error, Report, ScriptError};
pub use models::{Attachment, CompleteAnswer, CompleteRequest, Models, SideRequest};
pub use plugins::{Origin, Plugin, PluginFailure};
pub use processes::{Processes, shell};
pub use runtime::{Handle, Options, Runtime};
pub use session::{ScriptHooks, ScriptSession};
pub use tools::{ScriptTool, SessionHost};
