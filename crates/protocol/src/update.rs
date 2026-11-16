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

/// A live fact of a session. Saved events remain authoritative after reconnect. Each variant holds a type of the same
/// name, apart from `state`, `job`, and `model`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LiveUpdate {
    /// The session starts or ends a turn.
    State(StateUpdate),
    /// A background job of the session started or ended.
    Job(JobUpdate),
    /// The session accepted an input.
    InputAccepted(InputAccepted),
    /// A plugin or yuke asks the user a question.
    InteractionRequested(InteractionRequested),
    /// A question ended.
    InteractionClosed(InteractionClosed),
    /// An MCP server of the session started, failed, or stopped. The update holds its whole state, so a client replaces
    /// its copy.
    McpServer(McpServer),
    /// A pending input was removed.
    InputRemoved(InputRemoved),
    /// The turn stopped without a confirmed terminal commit. Discard provisional tool state and reload the journal.
    /// Saved events remain authoritative, including any tool results they confirm.
    TurnUnconfirmed,
    /// A provider attempt starts a new draft.
    DraftStarted(DraftStarted),
    /// One fact of the model in a draft.
    Model(DraftModelUpdate),
    /// Replace a draft with blocks from a saved commit.
    DraftCommitted(DraftCommitted),
    /// Remove a draft.
    DraftDiscarded(DraftDiscarded),
    /// The driver handles a saved call.
    ToolStarted(ToolStarted),
    /// A tool emits temporary output.
    ToolOutput(ToolOutput),
    /// A tool ends.
    ToolFinished(ToolFinished),
    /// An attempt failed, and the same request follows after a wait.
    RetryScheduled(RetryScheduled),
    /// A round failed after its retries.
    RoundFailed(RoundFailed),
}

/// A `state` update: the session starts or ends a turn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct StateUpdate {
    /// Whether a turn runs.
    pub state: SessionState,
}

/// A `job` update: a background job of the session started or ended. The update holds the whole job, so a client
/// replaces its copy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct JobUpdate {
    /// The job.
    pub job: Job,
}

/// The session accepted an input. It is pending until a saved commit names it in `consumed`, or until an
/// `inputRemoved` update names it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InputAccepted {
    /// The id of the input.
    pub input_id: InputId,
    /// The input.
    pub input: Input,
}

/// A plugin or yuke asks the user a question. The client answers with `interaction/respond`. The question stays open
/// until an `interactionClosed` update names it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InteractionRequested {
    /// The id that the answer names.
    pub interaction_id: InteractionId,
    /// The plugin that asks, or a part of yuke with a name that starts with `host:`.
    pub source: String,
    /// The question.
    pub request: InteractionRequest,
}

/// A question ended: the user answered it, its asker stopped waiting, or its session closed. The client removes it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InteractionClosed {
    /// The question.
    pub interaction_id: InteractionId,
}

/// A pending input was removed. The model never reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InputRemoved {
    /// The id of the input.
    pub input_id: InputId,
}

/// A provider attempt starts a new draft.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct DraftStarted {
    /// The identity of this attempt, distinct across turns and process restarts.
    pub draft_id: DraftId,
}

/// A `model` update: one fact of the model in a draft. It holds no provider replay state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct DraftModelUpdate {
    /// The draft of this fact.
    pub draft_id: DraftId,
    /// The model fact.
    pub event: ModelUpdate,
}

/// Replace the draft with blocks from the named saved commit. The array supplies source ids in destination order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct DraftCommitted {
    /// The draft to replace, including any blocks absent from `blocks`.
    pub draft_id: DraftId,
    /// The saved commit that holds every retained block.
    pub event_number: EventNumber,
    /// Original draft block ids in saved block order. Array index `i` maps to commit block index `i`.
    /// Draft blocks absent from this array do not enter history.
    pub blocks: Vec<yuke_ai::BlockId>,
}

/// Remove a draft. This does not remove any saved history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct DraftDiscarded {
    /// The draft to remove.
    pub draft_id: DraftId,
    /// Why the draft has no confirmed replacement.
    pub reason: DraftDiscardReason,
}

/// The driver handles a saved call. A denied call also has this update.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolStarted {
    /// The position of the saved call, even when the provider repeats its call id.
    pub position: BlockPosition,
    /// The call after yuke resolves a deferred tool. Its call id stays the id of the provider.
    pub call: yuke_ai::ToolCall,
}

/// A tool emits temporary output that the model does not receive.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolOutput {
    /// The position of the saved call.
    pub position: BlockPosition,
    /// The new output text.
    pub text: String,
}

/// A tool ends. Its result stays provisional until a saved commit confirms it. A `turnUnconfirmed` update discards it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct ToolFinished {
    /// The position of the saved call.
    pub position: BlockPosition,
    /// The result of the call.
    pub result: yuke_ai::ToolResult,
    /// What a frontend shows in place of the result text. The model never sees it.
    pub display: Vec<yuke_engine::DisplayBlock>,
    /// The duration of the tool in milliseconds, without the hooks. A call that did not run has no duration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

/// An attempt failed. The same request follows after a wait.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RetryScheduled {
    /// The wait in milliseconds.
    pub after_ms: u64,
    /// The failure text.
    pub error: String,
}

/// A round failed after its retries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RoundFailed {
    /// The failure text with each cause.
    pub error: String,
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

/// A fact of the model in a draft. Block ids belong to one draft and follow block start order. Each variant holds a
/// type of the same name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ModelUpdate {
    /// A block starts.
    BlockStarted(BlockStarted),
    /// Answer text arrives.
    TextDelta(TextDelta),
    /// Refusal text arrives.
    RefusalDelta(RefusalDelta),
    /// Reasoning text arrives.
    ReasoningDelta(ReasoningDelta),
    /// A reasoning section starts.
    ReasoningSectionStarted(ReasoningSectionStarted),
    /// A fragment of tool arguments arrives.
    ToolInputDelta(ToolInputDelta),
    /// A block stops.
    BlockStopped(BlockStopped),
    /// The response completes.
    ResponseCompleted(ResponseCompleted),
}

/// A block starts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct BlockStarted {
    /// The block id.
    pub block_id: u32,
    /// What the block holds.
    pub content: StartedBlock,
}

/// Answer text arrives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct TextDelta {
    /// The block id.
    pub block_id: u32,
    /// The new text.
    pub text: String,
}

/// Refusal text arrives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RefusalDelta {
    /// The block id.
    pub block_id: u32,
    /// The new text.
    pub text: String,
}

/// Reasoning text arrives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ReasoningDelta {
    /// The block id.
    pub block_id: u32,
    /// The new text.
    pub text: String,
}

/// A reasoning section starts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ReasoningSectionStarted {
    /// The block id.
    pub block_id: u32,
}

/// A fragment of tool arguments arrives. The final arguments come with the block stop.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolInputDelta {
    /// The block id.
    pub block_id: u32,
    /// The argument fragment, which need not be valid JSON alone.
    pub text: String,
}

/// A block stops. Reasoning signatures and encrypted replay data stay outside this update.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct BlockStopped {
    /// The block id.
    pub block_id: u32,
    /// The complete call of a tool block. Another block has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call: Option<yuke_ai::ToolCall>,
}

/// The response completes. This does not end its turn or confirm a durable save.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ResponseCompleted {
    /// The normalized finish reason.
    pub finish_reason: yuke_ai::FinishReason,
    /// The finish reason of the provider.
    pub raw_finish_reason: String,
    /// The token counts of the provider.
    pub usage: yuke_ai::Usage,
}

impl ModelUpdate {
    /// The owned update of `event`.
    pub fn from_event(event: yuke_ai::Event<'_>) -> Self {
        match event {
            yuke_ai::Event::BlockStarted(started) => Self::BlockStarted(BlockStarted {
                block_id: started.block,
                content: match started.content {
                    yuke_ai::StartedBlock::Text => StartedBlock::Text,
                    yuke_ai::StartedBlock::Refusal => StartedBlock::Refusal,
                    yuke_ai::StartedBlock::Reasoning => StartedBlock::Reasoning,
                    yuke_ai::StartedBlock::ToolCall { name } => StartedBlock::ToolCall { name: name.to_owned() },
                },
            }),
            yuke_ai::Event::TextDelta(delta) => Self::TextDelta(TextDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            }),
            yuke_ai::Event::RefusalDelta(delta) => Self::RefusalDelta(RefusalDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            }),
            yuke_ai::Event::ReasoningDelta(delta) => Self::ReasoningDelta(ReasoningDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            }),
            yuke_ai::Event::ToolInputDelta(delta) => Self::ToolInputDelta(ToolInputDelta {
                block_id: delta.block,
                text: delta.text.to_owned(),
            }),
            yuke_ai::Event::ReasoningSectionStarted(block) => {
                Self::ReasoningSectionStarted(ReasoningSectionStarted { block_id: block })
            }
            yuke_ai::Event::BlockStopped(stopped) => Self::BlockStopped(BlockStopped {
                block_id: stopped.block,
                call: match stopped.result {
                    yuke_ai::BlockResult::ToolCall(call) => Some(call.into()),
                    _ => None,
                },
            }),
            yuke_ai::Event::Done(done) => Self::ResponseCompleted(ResponseCompleted {
                finish_reason: done.finish_reason,
                raw_finish_reason: done.raw_finish_reason.to_owned(),
                usage: done.usage,
            }),
        }
    }
}
