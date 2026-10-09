//! Conversation execution through model and tool calls. A [`Driver`] runs one turn on the caller's history. It
//! carries out each step over the caller's [`yuke_ai::transport::Transport`] and [`Toolset`], and asks the caller's
//! [`Hooks`] for decisions. A private state machine decides each step without I/O. The crate creates no async runtime.
//!
//! The engine sets no cap on the size of a tool result. A caller bounds a large result in [`Hooks::after_tool`]. A
//! result that no caller bounds enters the history whole.

mod conversation;
mod drive;
mod hooks;
mod search;
mod tool;

pub use conversation::Outcome;
pub use drive::{Driver, Inbox, Observer, Timer, Turn, TurnEvent};
pub use hooks::{Hooks, RoundDecision, RoundPlan, ToolDecision};
pub use search::{Bm25, ToolSearch};
pub use tokio_util::sync::CancellationToken;
pub use tool::{Concurrency, TOOL_CALL_NAME, Tool, ToolContent, ToolContext, ToolNameError, Toolset, parse_arguments};
