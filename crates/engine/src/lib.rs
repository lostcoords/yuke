//! Assistant turns through model and tool calls. A [`Driver`] runs one turn on the caller's context. It
//! carries out each step over the caller's [`yuke_ai::transport::Transport`] and [`Toolset`], and asks the caller's
//! [`Hooks`] for decisions. When the caller sets a [`Journal`] on a [`Turn`], the driver gives it each commit. A private
//! state machine decides each step without I/O. The crate creates no async runtime.
//!
//! The engine sets no cap on the size of a tool result. A caller bounds a large result in [`Hooks::after_tool`]. A
//! result that no caller bounds enters the context whole.

mod drive;
mod hooks;
mod model;
mod search;
mod tool;
mod turn_state;

pub use drive::{Driver, Inbox, Journal, NoWait, Observer, Timer, Turn, TurnError, TurnEvent};
pub use hooks::{Hooks, RoundDecision, RoundPlan, RoundStart, ToolDecision};
pub use model::{CredentialSource, Model, RoundError};
pub use tokio_util::sync::CancellationToken;
pub use tool::{
    Concurrency, DisplayBlock, MediaStore, Preview, Subject, SubjectKind, TOOL_NAME_MAX, Tool, ToolContent,
    ToolContext, ToolHints, ToolNameError, ToolOutcome, Toolset, check_tool_name, parse_arguments, tool_name_character,
};
pub use turn_state::{
    Answer, CallDisplay, Commit, CommitDisplay, Outcome, Replaced, ResultDisplay, TurnEnd, chain_text,
};
