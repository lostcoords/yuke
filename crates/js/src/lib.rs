//! The JavaScript runtime of yuke: the QuickJS engine on its own thread. Callers on any thread import modules through
//! a channel.
//!
//! A module is a `.ts` or a `.js` file. The runtime removes the types of a `.ts` file and keeps the JavaScript in a
//! cache folder. The globals add the web timers to the language. The [`Limits`] bound the heap, the stack, and the time
//! of each uninterrupted stretch of JavaScript.

mod error;
mod loader;
mod runtime;
mod strip;
#[cfg(test)]
mod tests;
mod timers;

pub use error::{Error, Fault, ScriptError};
pub use runtime::{Limits, Options, Runtime};
