//! What a call answers: the streamed events, the collected response, and the facts of the attempt.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::encoder::EncodeError;
use crate::failure::{Failure, detail_text};
use crate::request::{Block, Reasoning, ReasoningReplayRef, ToolCall, ToolCallRef};

/// Why a response ended. At `Length` a tool call can hold cut-off arguments, so do not run such a call.
/// `Pause` marks an Anthropic server-tool loop at its iteration cap. The same content resumes the loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    /// The model finished its answer.
    Stop,
    /// The output reached its limit.
    Length,
    /// A content filter stopped the output.
    ContentFilter,
    /// The model declined.
    Refusal,
    /// The model asks for tool calls.
    ToolCalls,
    /// An Anthropic server-tool loop stopped at its iteration cap.
    Pause,
    /// A reason the library does not name. The raw reason keeps the provider value.
    Unknown,
}

impl FinishReason {
    /// The snake-case name of the reason.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stop => "stop",
            Self::Length => "length",
            Self::ContentFilter => "content_filter",
            Self::Refusal => "refusal",
            Self::ToolCalls => "tool_calls",
            Self::Pause => "pause",
            Self::Unknown => "unknown",
        }
    }

    /// The reason that [`FinishReason::as_str`] names, or `None` for another name.
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "stop" => Self::Stop,
            "length" => Self::Length,
            "content_filter" => Self::ContentFilter,
            "refusal" => Self::Refusal,
            "tool_calls" => Self::ToolCalls,
            "pause" => Self::Pause,
            "unknown" => Self::Unknown,
            _ => return None,
        })
    }
}

/// Token counts of one attempt, in the convention of OpenAI: a total includes the parts named after it. A provider can
/// leave out a count. Then the count is `None`, not `Some(0)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    /// Every prompt token, `cache_read` and `cache_write` among them.
    pub input: Option<u64>,
    /// Every generated token, `reasoning` among them.
    pub output: Option<u64>,
    /// The output tokens the model spent on reasoning.
    pub reasoning: Option<u64>,
    /// The input tokens read from the prompt cache.
    pub cache_read: Option<u64>,
    /// The input tokens written to the prompt cache.
    pub cache_write: Option<u64>,
}

/// Bounds on what an untrusted response can make the library hold. A response past one fails with
/// [`Failure::ResponseTooLarge`]. A zero bound admits nothing. The defaults fit the largest output, about 0.5 MB.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ResponseLimits {
    /// Every byte the response body carries. Each streamed delta adds an SSE and JSON envelope of 100 to 200 bytes
    /// for a few tokens, so a maximal answer reaches about 20 MB.
    pub max_response_bytes: usize,
    /// One SSE line, and the joined `data` of one event. Responses repeats the whole output, JSON-escaped, in
    /// `response.output_item.done` and `response.completed`.
    pub max_event_bytes: usize,
    /// The joined arguments of one tool call. No model emits more than its output limit.
    pub max_tool_arg_bytes: usize,
    /// The blocks of one response, with the provider blocks and output items that the library ignores.
    pub max_blocks: u32,
    /// The bytes of an error answer that [`AttemptInfo::error_body`] keeps.
    pub max_error_body_bytes: usize,
}

impl Default for ResponseLimits {
    fn default() -> Self {
        ResponseLimits {
            max_response_bytes: 64 << 20,
            max_event_bytes: 4 << 20,
            max_tool_arg_bytes: 1 << 20,
            max_blocks: 1024,
            max_error_body_bytes: 4096,
        }
    }
}

/// The facts of one attempt: the response head, the failure bytes, and whether the caller saw output.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct AttemptInfo {
    /// A parsed `retry-after-ms`, or `retry-after` converted to milliseconds.
    pub retry_after_ms: Option<u64>,
    /// The provider's `x-should-retry`: false vetoes a repeat, and true asks for one, as both SDKs obey it.
    pub should_retry: Option<bool>,
    /// The HTTP status, 200 included. `None` when the transport opened no body.
    pub status: Option<u16>,
    /// The provider request id from `request-id` or `x-request-id`, when the answer names one.
    pub request_id: Option<String>,
    /// The first bytes of the error answer, at most [`ResponseLimits::max_error_body_bytes`]: a non-200 body, or the
    /// stream event that failed a 200 response.
    pub error_body: Option<Vec<u8>>,
    /// The stream returned an event that a caller can show: a block start or stop, a delta with text, or the end. The
    /// flag tells what reached the library caller, not what a user saw.
    pub output_seen: bool,
}

/// A dense identifier that a reducer assigns to a block of one stream.
pub type BlockId = u32;

/// The kind of a streamed block. A refusal is the text of a model that declined the request. The library keeps the
/// refusal apart from the answer text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum BlockKind {
    /// Answer text.
    Text,
    /// The text of a model that declined.
    Refusal,
    /// Reasoning text.
    Reasoning,
    /// A tool call.
    ToolCall,
}

/// One event of a stream. Its text borrows the stream until the next call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event<'a> {
    /// A block starts. Ids are dense from 0, in start order.
    BlockStarted(BlockStarted),
    /// Answer text of a block.
    TextDelta(Delta<'a>),
    /// Refusal text of a block.
    RefusalDelta(Delta<'a>),
    /// Reasoning text of a block.
    ReasoningDelta(Delta<'a>),
    /// A reasoning block starts a new section. The next delta of the block opens the section.
    ReasoningSectionStarted(BlockId),
    /// A fragment of tool arguments, which is not valid JSON alone.
    ToolInputDelta(Delta<'a>),
    /// A block finishes, with what deltas cannot carry.
    BlockStopped(BlockStopped<'a>),
    /// The response ends. The stream reads nothing after it.
    Done(Done<'a>),
}

impl Event<'_> {
    /// Report whether a caller can show the event. An empty delta and a section start show nothing.
    pub(crate) fn carries_output(&self) -> bool {
        match self {
            Event::TextDelta(delta)
            | Event::RefusalDelta(delta)
            | Event::ReasoningDelta(delta)
            | Event::ToolInputDelta(delta) => !delta.text.is_empty(),
            Event::ReasoningSectionStarted(_) => false,
            Event::BlockStarted(_) | Event::BlockStopped(_) | Event::Done(_) => true,
        }
    }
}

/// The block that an event names, and its kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BlockStarted {
    /// The block.
    pub block: BlockId,
    /// Its kind.
    pub kind: BlockKind,
}

/// Borrowed text for one block. The event variant tells answer, refusal, reasoning, and argument bytes apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Delta<'a> {
    /// The block.
    pub block: BlockId,
    /// The text.
    pub text: &'a str,
}

/// A block that finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BlockStopped<'a> {
    /// The block.
    pub block: BlockId,
    /// What deltas cannot carry.
    pub result: BlockResult<'a>,
}

/// The end of the response. `finish_reason` uses the closed set. `raw_finish_reason` keeps the provider value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Done<'a> {
    /// The reason in the closed set.
    pub finish_reason: FinishReason,
    /// The provider value.
    pub raw_finish_reason: &'a str,
    /// The token counts.
    pub usage: Usage,
}

/// The block-stop result carries provider-only state that deltas cannot carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockResult<'a> {
    /// A text block.
    Text,
    /// A refusal block.
    Refusal,
    /// The provider state of a reasoning block, or `None` when it sent none. Its text came in the deltas.
    Reasoning(Option<ReasoningReplayRef<'a>>),
    /// The complete call. Its arguments come from the provider or from the joined fragments. The caller checks them.
    ToolCall(ToolCallRef<'a>),
}

/// One part of a completed answer: a block that stopped.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Content {
    /// Answer text.
    Text(String),
    /// The text of a model that declined the request. It replays as assistant text.
    Refusal(String),
    /// Reasoning text and the provider state that returns with it.
    Reasoning(Reasoning),
    /// A tool call. The caller validates the arguments.
    ToolCall(ToolCall),
}

impl From<Content> for Block {
    /// The assistant block that replays this part in the next request.
    fn from(content: Content) -> Self {
        match content {
            Content::Text(text) | Content::Refusal(text) => Block::AssistantText(text),
            Content::Reasoning(reasoning) => Block::Reasoning(reasoning),
            Content::ToolCall(call) => Block::ToolCall(call),
        }
    }
}

/// A retained block of a cancelled reply, with its original stream identity.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PartialBlock {
    /// The block id assigned when this block started.
    pub block: BlockId,
    /// The retained text or complete call, without provider replay state.
    pub content: Partial,
}

/// One output part of a failed attempt, in start order. It holds text and complete tool calls, but no replay
/// state. A reasoning part replays as text only.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Partial {
    /// Answer text, cut off where the attempt failed when its block never stopped.
    Text(String),
    /// Refusal text.
    Refusal(String),
    /// Reasoning text, without the provider state a completed block would carry.
    Reasoning(String),
    /// A call that stopped before the failure. A call cut off in its arguments is not here.
    /// The next request must answer it with a tool result, as for any call.
    ToolCall(ToolCall),
}

impl From<Partial> for Block {
    /// The assistant block that replays this part in the next request.
    fn from(partial: Partial) -> Self {
        match partial {
            Partial::Text(text) | Partial::Refusal(text) => Block::AssistantText(text),
            Partial::Reasoning(text) => Block::Reasoning(Reasoning { text, replay: None }),
            Partial::ToolCall(call) => Block::ToolCall(call),
        }
    }
}

/// Generated content. A refusal or a length stop is still a completion.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Completion {
    /// The stopped blocks in start order.
    pub content: Vec<Content>,
    /// The reason in the closed set.
    pub finish_reason: FinishReason,
    /// The provider value.
    pub raw_finish_reason: String,
    /// The token counts.
    pub usage: Usage,
}

impl Completion {
    /// Join the `Content::Text` parts without separators. Refusals, reasoning, and tool calls are not in the result.
    pub fn text(&self) -> String {
        self.content
            .iter()
            .filter_map(|part| match part {
                Content::Text(text) => Some(text.as_str()),
                _ => None,
            })
            .collect()
    }

    /// Return the tool calls in start order. Run them only after a [`FinishReason::ToolCalls`] or
    /// [`FinishReason::Stop`] finish. After [`FinishReason::Length`], a call can hold cut-off arguments.
    pub fn tool_calls(&self) -> impl Iterator<Item = &ToolCall> {
        self.content.iter().filter_map(|part| match part {
            Content::ToolCall(call) => Some(call),
            _ => None,
        })
    }

    /// The assistant blocks that replay this answer in the next request. The text moves, so nothing is copied.
    pub fn into_blocks(self) -> impl Iterator<Item = Block> {
        self.content.into_iter().map(Block::from)
    }
}

/// A finished attempt: its facts and its completion.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Response {
    /// The attempt facts.
    pub info: AttemptInfo,
    /// The answer.
    pub completion: Completion,
}

/// An attempt that failed: why, the attempt facts, and what it produced before the failure.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AttemptError {
    /// Why the attempt failed.
    pub cause: Failure,
    /// The attempt facts, which the retry decision reads.
    pub info: AttemptInfo,
    /// What the attempt produced before it failed. The caller decides whether the context keeps it.
    // @todo(xyaman): No caller reads this yet. A failed turn could keep this text, as a cancelled turn does.
    pub partial: Vec<Partial>,
}

impl fmt::Display for AttemptError {
    // The facts of the provider tell the user why a request failed, so they follow the cause.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.cause, f)?;
        let status = self.info.status.filter(|&status| status != 200);
        match (status, &self.info.request_id) {
            (Some(status), Some(request_id)) => write!(f, " (status {status}, request {request_id})")?,
            (Some(status), None) => write!(f, " (status {status})")?,
            (None, Some(request_id)) => write!(f, " (request {request_id})")?,
            (None, None) => {}
        }
        match self.info.error_body.as_deref().and_then(detail_text) {
            Some(detail) => write!(f, ": {detail}"),
            None => Ok(()),
        }
    }
}

impl std::error::Error for AttemptError {
    // The text starts with the text of the cause, so the source is the source of the cause.
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.cause.source()
    }
}

/// The errors of [`crate::generate`]: a request that cannot be encoded, or an attempt that failed.
#[derive(Debug)]
pub enum Error {
    /// The request cannot be encoded. Nothing was sent.
    Encode(EncodeError),
    /// The attempt failed.
    Attempt(AttemptError),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Encode(error) => fmt::Display::fmt(error, f),
            Error::Attempt(error) => fmt::Display::fmt(error, f),
        }
    }
}

impl std::error::Error for Error {
    // The text is the text of the inner error, so the source is the source of the inner error.
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Encode(error) => error.source(),
            Error::Attempt(error) => error.source(),
        }
    }
}

impl From<EncodeError> for Error {
    fn from(error: EncodeError) -> Self {
        Error::Encode(error)
    }
}

impl From<AttemptError> for Error {
    fn from(error: AttemptError) -> Self {
        Error::Attempt(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProviderKind;

    // The user reads why the provider refused a request, so the text keeps the facts of the provider.
    #[test]
    fn an_attempt_error_names_the_status_the_request_and_the_detail_of_the_provider() {
        let text = |status, request_id: Option<&str>, body: Option<&[u8]>| {
            AttemptError {
                cause: Failure::Provider(ProviderKind::BadStatus),
                info: AttemptInfo {
                    status,
                    request_id: request_id.map(str::to_owned),
                    error_body: body.map(<[u8]>::to_vec),
                    ..AttemptInfo::default()
                },
                partial: Vec::new(),
            }
            .to_string()
        };
        let cause = "the provider returned an unexpected status";
        let body = br#"{"error":{"message":"too long","type":"invalid_request_error"}}"#;

        assert_eq!(
            text(Some(400), Some("req_1"), Some(body)),
            format!("{cause} (status 400, request req_1): invalid_request_error: too long")
        );
        assert_eq!(text(Some(400), None, None), format!("{cause} (status 400)"));
        // A stream error has status 200, so the status tells the user nothing.
        assert_eq!(
            text(Some(200), Some("req_1"), Some(body)),
            format!("{cause} (request req_1): invalid_request_error: too long")
        );
        assert_eq!(text(None, None, Some(b" \n")), cause);
    }

    // A store saves a reason by its name and reads it back by that name.
    #[test]
    fn each_finish_reason_reads_back_from_its_name() {
        let reasons = [
            FinishReason::Stop,
            FinishReason::Length,
            FinishReason::ContentFilter,
            FinishReason::Refusal,
            FinishReason::ToolCalls,
            FinishReason::Pause,
            FinishReason::Unknown,
        ];
        for reason in reasons {
            assert_eq!(FinishReason::from_name(reason.as_str()), Some(reason));
        }
        assert_eq!(FinishReason::from_name("end_turn"), None);
    }

    // A retry is safe only before output reached the caller, so an empty event must not close that window.
    #[test]
    fn only_events_with_bytes_or_structure_carry_output() {
        let empty = Delta { block: 0, text: "" };
        let text = Delta { block: 0, text: "a" };
        let stopped = BlockStopped {
            block: 0,
            result: BlockResult::Text,
        };
        let done = Done {
            finish_reason: FinishReason::Stop,
            raw_finish_reason: "stop",
            usage: Usage::default(),
        };
        for (event, output) in [
            (Event::ReasoningSectionStarted(0), false),
            (Event::TextDelta(empty), false),
            (Event::RefusalDelta(empty), false),
            (Event::ReasoningDelta(empty), false),
            (Event::ToolInputDelta(empty), false),
            (Event::TextDelta(text), true),
            (Event::RefusalDelta(text), true),
            (Event::ReasoningDelta(text), true),
            (Event::ToolInputDelta(text), true),
            (Event::BlockStopped(stopped), true),
            (Event::Done(done), true),
            (
                Event::BlockStarted(BlockStarted {
                    block: 0,
                    kind: BlockKind::Text,
                }),
                true,
            ),
        ] {
            assert_eq!(event.carries_output(), output, "{event:?}");
        }
    }

    fn completion(content: Vec<Content>) -> Completion {
        Completion {
            content,
            finish_reason: FinishReason::Stop,
            raw_finish_reason: String::new(),
            usage: Usage::default(),
        }
    }

    #[test]
    fn text_joins_only_the_text_parts() {
        assert_eq!(completion(Vec::new()).text(), "");
        let several = completion(vec![
            Content::Refusal("no".into()),
            Content::Text("A".into()),
            Content::Reasoning(Reasoning {
                text: "r".into(),
                replay: None,
            }),
            Content::Text("B".into()),
            Content::Text("C".into()),
        ]);
        assert_eq!(several.text(), "ABC");
    }
}
