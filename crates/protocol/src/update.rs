//! The `session/update` notification: a saved event with its number, or a live update of a running turn.

use serde::{Deserialize, Serialize};
use yuke_engine::TurnEvent;

use crate::{SessionId, StoredEvent};

/// The params of `session/update`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionUpdateParams {
    /// The session of the update.
    pub session_id: SessionId,
    /// What changed.
    pub update: SessionUpdate,
}

/// A saved event with its event number, or a live update with none. The `sessionUpdate` field of each names its kind.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(untagged)]
pub enum SessionUpdate {
    /// A change that the store saved.
    Saved(StoredEvent),
    /// A part of a running turn that the store does not save. The next saved commit holds the result.
    Live(LiveUpdate),
}

/// A part of a running turn that a client shows as it happens. It is for display only: a text chunk names no block,
/// and the next saved commit holds the whole answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "sessionUpdate", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum LiveUpdate {
    /// New text of the answer.
    AgentMessageChunk {
        /// The new text.
        text: String,
    },
    /// New text of the reasoning.
    AgentThoughtChunk {
        /// The new text.
        text: String,
    },
    /// A tool call starts.
    ToolCall(yuke_ai::ToolCall),
    /// A running tool call shows output.
    ToolCallOutput {
        /// The id of the call.
        call_id: String,
        /// The output text.
        text: String,
    },
    /// A tool call ends with this result.
    ToolCallResult(yuke_ai::ToolResult),
    /// An attempt failed, and the same request goes out again after a wait.
    RetryScheduled {
        /// The wait in milliseconds.
        after_ms: u64,
        /// The text of the failure.
        error: String,
    },
    /// A round failed after its retries.
    RoundFailed {
        /// The text of the failure.
        error: String,
    },
}

impl LiveUpdate {
    /// The live update of the turn event `event`, or `None` for an event that a client does not show live: a block
    /// start or stop, a tool input delta, the end of a response. The next saved commit holds those. A refusal is answer
    /// text, as the saved context keeps it, and the finish reason of the turn marks it.
    pub fn from_turn_event(event: &TurnEvent<'_>) -> Option<Self> {
        match event {
            TurnEvent::Model(yuke_ai::Event::TextDelta(delta) | yuke_ai::Event::RefusalDelta(delta)) => {
                Some(LiveUpdate::AgentMessageChunk {
                    text: delta.text.to_owned(),
                })
            }
            TurnEvent::Model(yuke_ai::Event::ReasoningDelta(delta)) => Some(LiveUpdate::AgentThoughtChunk {
                text: delta.text.to_owned(),
            }),
            TurnEvent::ToolStarted(call) => Some(LiveUpdate::ToolCall((*call).clone())),
            TurnEvent::ToolOutput { call_id, text } => Some(LiveUpdate::ToolCallOutput {
                call_id: (*call_id).to_owned(),
                text: (*text).to_owned(),
            }),
            TurnEvent::ToolFinished(result) => Some(LiveUpdate::ToolCallResult((*result).clone())),
            TurnEvent::RetryScheduled { after, error } => Some(LiveUpdate::RetryScheduled {
                after_ms: u64::try_from(after.as_millis()).unwrap_or(u64::MAX),
                error: error.to_string(),
            }),
            TurnEvent::RoundFailed(error) => Some(LiveUpdate::RoundFailed {
                error: error.to_string(),
            }),
            // A client gets the blocks from the delta events, the calls from the tool events, and the end from the
            // turn.
            TurnEvent::Model(
                yuke_ai::Event::BlockStarted(_)
                | yuke_ai::Event::ReasoningSectionStarted(_)
                | yuke_ai::Event::ToolInputDelta(_)
                | yuke_ai::Event::BlockStopped(_)
                | yuke_ai::Event::Done(_),
            ) => None,
        }
    }
}
