//! The JavaScript runtime of yuke: the QuickJS engine on its own thread. Callers on any thread import modules through
//! a channel.
//!
//! A module is a built-in module with a `yuke:` name, or a `.ts` or a `.js` file. The built-in modules are bytecode in
//! the binary. The runtime removes the types of a `.ts` file and keeps the JavaScript in a cache folder. The globals
//! add the web timers and `reportError` to the language. The [`Limits`] bound the heap, the stack, and the time of
//! each uninterrupted stretch of JavaScript.
//!
//! A tool that the JavaScript defines with `yuke:tools` is an engine tool: [`Runtime::tools`] gives each one as a
//! [`ScriptTool`] for the session of a [`SessionHost`]. `yuke:builtins` defines the tools `read`, `write`, and `edit`.

mod baked;
mod error;
mod loader;
mod native;
mod runtime;
mod strip;
#[cfg(test)]
mod tests;
mod timers;
mod tools;
mod typescript;

pub use error::{Error, Fault, ScriptError};
pub use runtime::{Limits, Options, Runtime};
pub use tools::{ScriptTool, SessionHost};
