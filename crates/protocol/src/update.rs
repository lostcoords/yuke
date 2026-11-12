//! Saved session events and draft-scoped live facts.

use serde::{Deserialize, Serialize};

use crate::{
    DraftId, EventNumber, Input, InputId, InteractionId, InteractionRequest, Job, McpServer, SessionId,
    SessionSettings, StoredEvent,
};

/// A session for a new viewer: its settings, and the updates that show it. The updates are its last saved events, its
/// state, its pending inputs, its running jobs, its MCP servers, and its open questions. The later updates follow it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionSnapshot {
    /// The settings of the session when the snapshot starts. A later change comes as a saved event.
    pub settings: SessionSettings,
    /// The updates that show the session, in order.
    pub updates: Vec<SessionUpdate>,
}

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
#[serde(rename_all = "camelCase")]
pub enum DraftDiscardReason {
    /// The provider attempt failed. None of its blocks enter the context.
    Failed,
    /// The turn ended without confirmation of the draft's save. Reload the journal to resolve an uncertain write.
    Unconfirmed,
}

/// Whether a session is open in the server, and whether a turn runs in it. A `state` update of an open session is
/// `idle` or `running`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub enum SessionState {
    /// The session is not open in this server.
    Closed,
    /// The session is open, and no turn runs.
    Idle,
    /// A turn runs.
    Running,
}

/// A live fact of a session. Saved events remain authoritative after reconnect.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(tag = "sessionUpdate", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum LiveUpdate {
    /// The session starts or ends a turn.
    State {
        /// Whether a turn runs.
        state: SessionState,
    },
    /// A background job of the session started or ended. The update holds the whole job, so a client replaces its
    /// copy.
    Job {
        /// The job.
        job: Job,
    },
    /// The session accepted an input. It is pending until a saved commit names it in `consumed`, or until a removal.
    InputAccepted {
        /// The id of the input.
        input_id: InputId,
        /// The input.
        input: Input,
    },
    /// A plugin or yuke asks the user a question. The client answers with `interaction/respond`. The question stays
    /// open until an `interaction_closed` update names it.
    InteractionRequested {
        /// The id that the answer names.
        interaction_id: InteractionId,
        /// The plugin that asks, or a part of yuke with a name that starts with `host:`.
        source: String,
        /// The question.
        request: InteractionRequest,
    },
    /// A question ended: the user answered it, its asker stopped waiting, or its session closed. The client removes it.
    InteractionClosed {
        /// The question.
        interaction_id: InteractionId,
    },
    /// An MCP server of the session started, failed, or stopped. The update holds its whole state, so a client replaces
    /// its copy.
    McpServer {
        /// The server.
        #[serde(flatten)]
        server: McpServer,
    },
    /// A pending input was removed.
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
    /// The driver handles a saved call. A denied call also has this event.
    ToolStarted {
        /// The position of the saved call, even when the provider repeats its call id.
        position: BlockPosition,
        /// The resolved call after the deferred-tool bridge. Its call id remains provider data.
        call: yuke_ai::ToolCall,
    },
    /// A tool emits temporary output that the model does not receive.
    ToolOutput {
        /// The position of the saved call.
        position: BlockPosition,
        /// The new output text.
        text: String,
    },
    /// A tool ends. Its result remains provisional until a saved commit confirms it.
    /// `TurnUnconfirmed` invalidates the provisional result.
    ToolFinished {
        /// The position of the saved call.
        position: BlockPosition,
        /// The result of the call.
        result: yuke_ai::ToolResult,
        /// What a frontend shows in place of the result text. The model never sees it.
        display: Vec<yuke_engine::DisplayBlock>,
        /// The duration of the tool in milliseconds, without the hooks. A call that did not run has no duration.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration_ms: Option<u64>,
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
        /// The failure text with each cause.
        error: String,
    },
}

/// What a block holds when it starts. A refusal is the text of a model that declined the request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StartedBlock {
    /// Answer text.
    Text,
    /// The text of a model that declined.
    Refusal,
    /// Reasoning text.
    Reasoning,
    /// A tool call.
    ToolCall {
        /// The name of the tool, or an empty name when the provider has not named it yet. The block stop gives
        /// the final call.
        name: String,
    },
}

/// An owned model event for clients. Block ids belong to one draft and follow block start order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ModelUpdate {
    /// A block starts.
    BlockStarted {
        /// The block id.
        block_id: u32,
        /// What the block holds.
        content: StartedBlock,
    },
    /// Answer text arrives.
    TextDelta {
        /// The block id.
        block_id: u32,
        /// The new text.
        text: String,
    },
    /// Refusal text arrives.
    RefusalDelta {
        /// The block id.
        block_id: u32,
        /// The new text.
        text: String,
    },
    /// Reasoning text arrives.
    ReasoningDelta {
        /// The block id.
        block_id: u32,
        /// The new text.
        text: String,
    },
    /// A reasoning section starts.
    ReasoningSectionStarted {
        /// The block id.
        block_id: u32,
    },
    /// A fragment of tool arguments arrives. Final arguments come with the block stop.
    ToolInputDelta {
        /// The block id.
        block_id: u32,
        /// The argument fragment, which need not be valid JSON alone.
        text: String,
    },
    /// A block stops. Reasoning signatures and encrypted replay data stay outside this payload.
    BlockStopped {
        /// The block id.
        block_id: u32,
        /// The authoritative complete call for a tool block, otherwise `None`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
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

impl ModelUpdate {
    /// The owned update of `event`, or `None` for an event that the protocol has no update for.
    pub fn from_event(event: yuke_ai::Event<'_>) -> Option<Self> {
        Some(match event {
            yuke_ai::Event::BlockStarted(started) => Self::BlockStarted {
                block_id: started.block,
                content: match started.content {
                    yuke_ai::StartedBlock::Text => StartedBlock::Text,
                    yuke_ai::StartedBlock::Refusal => StartedBlock::Refusal,
                    yuke_ai::StartedBlock::Reasoning => StartedBlock::Reasoning,
                    yuke_ai::StartedBlock::ToolCall { name } => StartedBlock::ToolCall { name: name.to_owned() },
                    _ => return None,
                },
            },
            yuke_ai::Event::TextDelta(delta) => Self::TextDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::RefusalDelta(delta) => Self::RefusalDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::ReasoningDelta(delta) => Self::ReasoningDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::ToolInputDelta(delta) => Self::ToolInputDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            },
            yuke_ai::Event::ReasoningSectionStarted(block) => Self::ReasoningSectionStarted { block_id: block },
            yuke_ai::Event::BlockStopped(stopped) => Self::BlockStopped {
                block_id: stopped.block,
                call: match stopped.result {
                    yuke_ai::BlockResult::ToolCall(call) => Some(call.into()),
                    _ => None,
                },
            },
            yuke_ai::Event::Done(done) => Self::ResponseCompleted {
                finish_reason: done.finish_reason,
                raw_finish_reason: done.raw_finish_reason.to_owned(),
                usage: done.usage,
            },
            _ => return None,
        })
    }
}
