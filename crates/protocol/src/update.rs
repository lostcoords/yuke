//! Saved session events and draft-scoped live facts.

use serde::{Deserialize, Serialize};

use crate::{DraftId, EventNumber, Input, InputId, SessionId, StoredEvent};

/// The params of `session/update`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionUpdateParams {
    /// The session of the update. All positions in the update belong to this session.
    pub session_id: SessionId,
    /// What changed.
    pub update: SessionUpdate,
}

/// A saved event or a temporary fact of a turn.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(untagged)]
pub enum SessionUpdate {
    /// An event whose durable write succeeded.
    Saved(StoredEvent),
    /// A live fact. A draft contributes no history until a saved commit confirms it.
    Live(LiveUpdate),
}

/// A block position within one session. A tool execution uses the position of its call, not its result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct BlockPosition {
    /// The event that contains the block.
    pub event_number: EventNumber,
    /// The zero-based index within the commit's blocks, not within the current context.
    pub block_index: usize,
}

/// Why a client must remove a draft without a confirmed saved replacement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum DraftDiscardReason {
    /// The provider attempt failed. None of its blocks enter the context.
    Failed,
    /// The turn ended without confirmation of the draft's save. Reload the journal to resolve an uncertain write.
    Unconfirmed,
}

/// Whether a session runs a turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    /// A turn runs.
    Running,
    /// No turn runs.
    Idle,
}

/// A live fact of a session. Saved events remain authoritative after reconnect.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "sessionUpdate", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum LiveUpdate {
    /// The session starts or ends a turn.
    State {
        /// Whether a turn runs.
        state: SessionState,
    },
    /// The session accepted an input. It is pending until a saved commit names it in `consumed`, or until a removal.
    InputAccepted {
        /// The id of the input.
        input_id: InputId,
        /// The input.
        input: Input,
    },
    /// A pending input was removed. A turn that took it before the removal fails its next commit.
    InputRemoved {
        /// The id of the input.
        input_id: InputId,
    },
    /// The turn stopped without a confirmed terminal commit. Discard provisional tool state and reload the journal.
    /// Saved events remain authoritative, including any tool results they confirm.
    TurnUnconfirmed,
    /// A provider attempt starts a new draft.
    DraftStarted {
        /// The identity of this attempt, distinct across turns and process restarts.
        draft_id: DraftId,
    },
    /// One native fact of the draft. Provider replay state is not display content.
    Model {
        /// The draft of this fact.
        draft_id: DraftId,
        /// The model fact.
        event: ModelUpdate,
    },
    /// Replace the draft with blocks from the named saved commit. The array supplies source ids in destination order.
    DraftCommitted {
        /// The draft to replace, including any blocks absent from `blocks`.
        draft_id: DraftId,
        /// The saved commit that holds every retained block.
        event_number: EventNumber,
        /// Original draft block ids in saved block order. Array index `i` maps to commit block index `i`.
        /// Draft blocks absent from this array do not enter history.
        blocks: Vec<yuke_ai::BlockId>,
    },
    /// Remove a draft. This does not remove any saved history.
    DraftDiscarded {
        /// The draft to remove.
        draft_id: DraftId,
        /// Why the draft has no confirmed replacement.
        reason: DraftDiscardReason,
    },
    /// The driver handles a saved call. A blocked call also has this event.
    ToolStarted {
        /// The position of the saved call, even when the provider repeats its call id.
        execution: BlockPosition,
        /// The resolved call after the deferred-tool bridge. Its call id remains provider data.
        call: yuke_ai::ToolCall,
    },
    /// A tool emits temporary output that the model does not receive.
    ToolOutput {
        /// The position of the saved call.
        execution: BlockPosition,
        /// The new output text.
        text: String,
    },
    /// A tool ends. Its result remains provisional until a saved commit confirms it.
    /// `TurnUnconfirmed` invalidates the provisional result.
    ToolFinished {
        /// The position of the saved call.
        execution: BlockPosition,
        /// The result of the call.
        result: yuke_ai::ToolResult,
    },
    /// An attempt failed. The same request follows after a wait.
    RetryScheduled {
        /// The wait in milliseconds.
        after_ms: u64,
        /// The failure text.
        error: String,
    },
    /// A round failed after its retries.
    RoundFailed {
        /// The failure text.
        error: String,
    },
}

/// An owned model event for clients. Block ids belong to one draft and follow block start order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum ModelUpdate {
    /// A block starts.
    BlockStarted {
        /// The block id.
        block: u32,
        /// The content kind.
        block_kind: yuke_ai::BlockKind,
    },
    /// Answer text arrives.
    TextDelta {
        /// The block id.
        block: u32,
        /// The new text.
        text: String,
    },
    /// Refusal text arrives.
    RefusalDelta {
        /// The block id.
        block: u32,
        /// The new text.
        text: String,
    },
    /// Reasoning text arrives.
    ReasoningDelta {
        /// The block id.
        block: u32,
        /// The new text.
        text: String,
    },
    /// A reasoning section starts.
    ReasoningSectionStarted {
        /// The block id.
        block: u32,
    },
    /// A fragment of tool arguments arrives. Final arguments come with the block stop.
    ToolInputDelta {
        /// The block id.
        block: u32,
        /// The argument fragment, which need not be valid JSON alone.
        text: String,
    },
    /// A block stops. Reasoning signatures and encrypted replay data stay outside this payload.
    BlockStopped {
        /// The block id.
        block: u32,
        /// The authoritative complete call for a tool block, otherwise `None`.
        call: Option<yuke_ai::ToolCall>,
    },
    /// The response completes. This does not end its turn or confirm a durable save.
    ResponseCompleted {
        /// The normalized finish reason.
        finish_reason: yuke_ai::FinishReason,
        /// The provider's finish reason.
        raw_finish_reason: String,
        /// The provider's token counts.
        usage: yuke_ai::Usage,
    },
}

impl From<yuke_ai::Event<'_>> for ModelUpdate {
    fn from(event: yuke_ai::Event<'_>) -> Self {
        match event {
            yuke_ai::Event::BlockStarted(started) => Self::BlockStarted {
                block: started.block,
                block_kind: started.kind,
            },
            yuke_ai::Event::TextDelta(delta) => Self::TextDelta {
                block: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::RefusalDelta(delta) => Self::RefusalDelta {
                block: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::ReasoningDelta(delta) => Self::ReasoningDelta {
                block: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::ToolInputDelta(delta) => Self::ToolInputDelta {
                block: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::ReasoningSectionStarted(block) => Self::ReasoningSectionStarted { block },
            yuke_ai::Event::BlockStopped(stopped) => Self::BlockStopped {
                block: stopped.block,
                call: match stopped.result {
                    yuke_ai::BlockResult::ToolCall(call) => Some(call.into()),
                    yuke_ai::BlockResult::Text | yuke_ai::BlockResult::Refusal | yuke_ai::BlockResult::Reasoning(_) => {
                        None
                    }
                },
            },
            yuke_ai::Event::Done(done) => Self::ResponseCompleted {
                finish_reason: done.finish_reason,
                raw_finish_reason: done.raw_finish_reason.to_owned(),
                usage: done.usage,
            },
        }
    }
}
