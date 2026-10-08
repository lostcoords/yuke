//! Caller decisions during a turn. The driver awaits each hook, and the answer decides the next step. An observer
//! only watches.

use ai::{Block, ToolCall, ToolResult};
use async_trait::async_trait;

/// The decisions of a caller at the boundaries of a turn. Each method has a default that changes nothing, so a
/// caller implements only the hooks that it needs.
#[async_trait]
pub trait Hooks: Send + Sync {
    /// Decide whether `call` runs. The driver asks before each call.
    async fn before_tool(&self, _call: &ToolCall) -> ToolDecision {
        ToolDecision::Run
    }

    /// Return a replacement for the `result` of `call`, or `None` to keep it. The driver asks after each call that
    /// [`Hooks::before_tool`] lets run. A replacement keeps the call id. A cancel during this hook keeps the result.
    /// The engine sets no cap on a result, so a caller bounds a large result here.
    async fn after_tool(&self, _call: &ToolCall, _result: &ToolResult) -> Option<ToolResult> {
        None
    }

    /// Decide whether the turn continues. The driver asks after each answer, when the answer and its tool results are
    /// in `history`. After an answer that needs no other request, `Proceed` continues only when new input waits.
    async fn after_round(&self, _history: &[Block]) -> RoundDecision {
        RoundDecision::Proceed
    }
}

/// The answer of [`Hooks::before_tool`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolDecision {
    /// Run the call.
    Run,
    /// Do not run the call. The reason reaches the model as an error result, and the turn continues.
    Block(String),
}

/// The answer of [`Hooks::after_round`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoundDecision {
    /// Continue the turn.
    Proceed,
    /// End the turn. A turn that asked for another request ends as [`crate::Outcome::Stopped`]. After an answer
    /// that needs no other request, the turn ends as [`crate::Outcome::Completed`].
    Stop,
}

/// The hooks of a driver without hooks: each call runs, and each turn continues.
pub(crate) struct NoHooks;

impl Hooks for NoHooks {}
