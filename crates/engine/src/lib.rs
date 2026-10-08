//! Conversation execution through model and tool calls. A [`Conversation`] decides each step without I/O. A
//! [`Driver`] carries out the steps over the caller's [`yuke_ai::transport::Transport`] and [`Toolset`], and asks the caller's
//! [`Hooks`] for decisions. The crate creates no async runtime.
//!
//! The engine sets no cap on the size of a tool result. A caller bounds a large result in [`Hooks::after_tool`]. A
//! result that no caller bounds enters the history whole.

mod conversation;
mod drive;
mod hooks;
mod search;
mod tool;

pub use conversation::{Action, Conversation, Outcome, ToolCalls, ToolCallsIter};
pub use drive::{Driver, Inbox, Observer, Timer, Turn, TurnEvent};
pub use hooks::{Hooks, RoundDecision, RoundPlan, ToolDecision};
pub use search::{Bm25, ToolSearch};
pub use tokio_util::sync::CancellationToken;
pub use tool::{TOOL_CALL_NAME, Tool, ToolContent, ToolContext, ToolNameError, Toolset, parse_arguments};
