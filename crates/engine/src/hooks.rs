//! Caller decisions during a turn. The driver awaits each hook, and the answer decides the next step. An observer
//! only watches.

use std::error::Error;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason, Settings, ToolCall, ToolDefinition};

use crate::model::{Model, RoundError};
use crate::tool::ToolOutcome;
use crate::turn_state::Replaced;

/// The decisions of a caller at the boundaries of a turn. Each method has a default that changes nothing, so a
/// caller implements only the hooks that it needs. A round hook can fail, and its error ends the turn as
/// [`RoundError::Hook`]. A tool hook cannot fail, so a caller answers a failed check with a block or an error result.
#[async_trait]
pub trait Hooks: Send + Sync {
    /// Prepare the request of a round. The driver asks before the first attempt of each round, not before a retry.
    ///
    /// # Errors
    ///
    /// Returns why the hook failed. The turn then ends with no request.
    async fn before_round(&self, _round: &RoundStart<'_>) -> Result<RoundPlan, Box<dyn Error + Send + Sync>> {
        Ok(RoundPlan::default())
    }

    /// Decide whether a failed round runs again in the same turn. The driver asks after the last attempt of the round
    /// fails, but not after a failed hook. `round` holds the context, the settings, and the model window of the failed
    /// round. A plan sends the round again. `None` ends the turn with the `failure`.
    ///
    /// # Errors
    ///
    /// Returns why the hook failed. The turn then ends with [`RoundError::Hook`], and its text ends with the `failure`.
    async fn retry_round(
        &self,
        _round: &RoundStart<'_>,
        _failure: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn Error + Send + Sync>> {
        Ok(None)
    }

    /// Decide whether `call` runs.
    /// The driver asks before each call, in call order, except a call that the deferred-tool bridge refuses.
    /// The hook parses the raw arguments if it needs them.
    /// In a parallel group, the driver asks before any call starts.
    async fn before_tool(&self, _call: &ToolCall) -> ToolDecision {
        ToolDecision::Run
    }

    /// Return a replacement for the `outcome` of `call`, or `None` to keep it.
    /// The driver asks after each call that started, at once when the call returns.
    /// A call to an unknown tool also starts.
    /// The driver can ask for the calls of a parallel group together.
    /// The hook must preserve the call id in a replacement.
    /// A cancel during this hook keeps the outcome.
    /// The engine sets no cap on a result, so a caller bounds a large result here.
    async fn after_tool(&self, _call: &ToolCall, _outcome: &ToolOutcome) -> Option<ToolOutcome> {
        None
    }

    /// Decide whether the turn continues. The driver asks after each answer, when the answer and its tool results are
    /// in `context`, and before it takes the input of the inbox. `finish_reason` is the reason of an answer that needs
    /// no other request, and `None` after a round that asks for another request. To continue after such an answer, the
    /// hook puts input in the inbox and answers `Proceed`. The engine sets no limit on that loop, so a caller bounds it.
    ///
    /// # Errors
    ///
    /// Returns why the hook failed. The turn then ends, and the context keeps the round. The input of the inbox stays
    /// for the next turn.
    async fn after_round(
        &self,
        _context: &[Block],
        _finish_reason: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn Error + Send + Sync>> {
        Ok(RoundDecision::Proceed)
    }
}

/// What [`Hooks::before_round`] and [`Hooks::retry_round`] know about the round.
#[derive(Debug, Clone, Copy)]
pub struct RoundStart<'a> {
    /// The context, oldest first.
    pub context: &'a [Block],
    /// The model of the round: the model of the driver, or the model of a plan for this round.
    pub model: &'a Model,
    /// The settings of the round: the settings of the turn, or the settings of a plan for this round.
    pub settings: &'a Settings,
    /// The system prompt of the round.
    pub system: &'a str,
    /// The tool definitions that the request of the round offers.
    pub tools: &'a [ToolDefinition],
    /// The input tokens of the newest answer. It is `None` before an answer, without a provider count, or after a newer
    /// replacement, because a count of the old context does not describe the new one.
    pub input_tokens: Option<u64>,
}

/// The plan of a round, from [`Hooks::before_round`] or [`Hooks::retry_round`]. A `None` replacement keeps the
/// context. A `None` model keeps the driver's model, and `None` settings keep the turn's settings.
#[derive(Debug, Clone, Default)]
pub struct RoundPlan {
    /// A new first part of the context and the number of old blocks that stay after it, for example a summary and the
    /// recent blocks. It replaces the context before the request, and the replacement stays after the round.
    pub replace: Option<Replaced<'static>>,
    /// The model of this round. The next round uses the driver's model again.
    pub model: Option<Model>,
    /// The settings of this round. The next round uses the turn's settings again.
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoundDecision {
    /// Send the next request with the input of the inbox. After an answer that needs no other request, an empty inbox
    /// ends the turn as [`crate::Outcome::Completed`].
    Proceed,
    /// End the turn, and leave the input of the inbox for the next turn. A turn that asked for another request ends as
    /// [`crate::Outcome::Stopped`]. After an answer that needs no other request, the turn ends as
    /// [`crate::Outcome::Completed`].
    Stop,
}

/// The hooks of a driver without hooks: each call runs, each round continues, and each turn ends when the model ends it.
pub(crate) struct NoHooks;

impl Hooks for NoHooks {}
