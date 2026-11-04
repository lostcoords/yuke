//! The JavaScript runtime of yuke. The host enters the engine directly, and a local task drives its pending work.
//!
//! A module is a built-in module with a `yuke:` name, or a `.ts` or a `.js` file. The built-in modules are bytecode in
//! the binary. The runtime removes the types of a `.ts` file and keeps the JavaScript in a cache folder. The globals
//! add web APIs to the language: timers, `reportError`, events and abort signals, `TextEncoder` and `TextDecoder`,
//! `URL` and `URLSearchParams`, `ReadableStream`, `fetch` with `Headers`, `Request`, and `Response`, `console`, and
//! `performance`. The public modules are `yuke:tools`, `yuke:plugins`, `yuke:fs` (files), `yuke:process` (programs),
//! `yuke:net` (Unix sockets), and `yuke:ai` (model requests). Three more public modules serve frontends: `yuke:tui`
//! (the terminal interface), `yuke:transcript` (the conversation of a session as data), and `yuke:chat` (the blocks of
//! a chat). The runtime sets no heap limit and no default time limit. It checks the stack of the JavaScript, so a deep
//! recursion throws and does not crash the thread. The thread needs [`THREAD_STACK`]. A shutdown stops the JavaScript
//! and its commands. Process jobs need [`Processes::shutdown`].
//!
//! A plugin runs `apply` once per runtime and `session` once per session. [`Handle::open_session`] opens the session
//! of a [`SessionHost`]. [`ScriptSession::tools`] gives each tool of that session as a [`ScriptTool`]: the tools of
//! yuke and the tools that the `session` exports define. `yuke:internal/builtins` defines the tools `read`, `write`,
//! `edit`, `exec`, and `stop`. [`Processes`] runs the commands and the background jobs as local tasks of the host
//! runtime, so a process job outlives a reload of the JavaScript. The consumer gives the [`Models`] that the plugins
//! call.

mod baked;
mod bytes;
mod display;
mod error;
mod jobs;
mod loader;
mod models;
mod native;
mod plugins;
mod processes;
mod runtime;
mod session;
mod sessions;
mod settled;
mod strip;
mod test_drive;
mod test_host;
mod test_runner;
#[cfg(test)]
mod tests;
mod timers;
mod tools;
mod typescript;

pub use display::{Display, Input, Interface, Request, Startup};
pub use error::{Error, Report, ScriptError};
pub use jobs::Jobs;
pub use models::{Attachment, CompleteAnswer, CompleteRequest, Models, SideRequest};
pub use plugins::{Origin, Plugin, PluginFailure};
pub use processes::{Processes, shell};
pub use runtime::{Handle, Options, Runtime, THREAD_STACK};
pub use session::{ScriptHooks, ScriptSession};
pub use sessions::{Fact, FactSink, SessionInspection, Sessions, SessionsError, ViewEvent, ViewSink};
pub use settled::settled;
pub use test_host::TestHost;
pub use test_runner::{
    TestError, TestFileError, TestOutcome, TestRuntime, TestStatus, TestSummary, find_test_files, run_test_file,
    run_test_files,
};
pub use tools::{RequestFailure, ScriptTool, SessionHost};
