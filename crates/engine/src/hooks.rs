//! Caller decisions during a turn. The driver awaits each hook, and the answer decides the next step. An observer
//! only watches.

use ai::{Block, Settings, Target, ToolCall, ToolResult};
use async_trait::async_trait;

/// The decisions of a caller at the boundaries of a turn. Each method has a default that changes nothing, so a
/// caller implements only the hooks that it needs.
#[async_trait]
pub trait Hooks: Send + Sync {
    /// Prepare the request of a round. The driver asks before the first attempt of each round, not before a retry.
    /// After a round fails and its retries end, the driver asks again with the `failure`. A plan with a target then
    /// sends the round again in the same turn. A plan without a target ends the turn with the failure.
    async fn before_round(&self, _history: &[Block], _failure: Option<&ai::Error>) -> RoundPlan {
        RoundPlan::default()
    }

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

/// The answer of [`Hooks::before_round`]. A `None` history keeps the history. A `None` target or settings keeps the
/// driver's value.
#[derive(Debug, Clone, Default)]
pub struct RoundPlan {
    /// The new history of the conversation, for example a summary and the recent blocks. It replaces the history before
    /// the request, and the replacement stays after the round.
    pub history: Option<Vec<Block>>,
    /// The model of this round. The next round uses the driver's target again.
    pub target: Option<Target>,
    /// The settings of this round. The next round uses the driver's settings again.
    pub settings: Option<Settings>,
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
