//! Conversation execution through model and tool calls. A [`Conversation`] decides each step without I/O. A
//! [`Driver`] carries out the steps over the caller's [`ai::transport::Transport`] and [`Toolset`], and asks the caller's
//! [`Hooks`] for decisions. The crate creates no async runtime.

mod conversation;
mod drive;
mod hooks;
mod tool;

pub use conversation::{Action, Conversation, Outcome, ToolCalls, ToolCallsIter};
pub use drive::{Driver, Inbox, Observer, Timer, Turn, TurnEvent};
pub use hooks::{Hooks, RoundDecision, ToolDecision};
pub use tokio_util::sync::CancellationToken;
pub use tool::{DuplicateToolName, Tool, Toolset};
