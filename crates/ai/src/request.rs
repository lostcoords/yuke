//! What a call says: the target, the request, its blocks and tools, and the wire facts of each protocol.
//! A block owns its bytes, so a context is a `Vec<Block>`. A request borrows its parts only for one encode.

use std::borrow::Cow;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::encoder::EncodeError;
use crate::route::Route;

/// The wire protocol of one endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    /// Anthropic Messages.
    AnthropicMessages,
    /// OpenAI Chat Completions.
    OpenaiChat,
    /// OpenAI Responses.
    OpenaiResponses,
}

/// The kind of provider state that a reasoning block must return verbatim. Each kind names the protocol that
/// produced the state. Only the encoder of that protocol writes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum ReplayKind {
    /// The `signature` of an Anthropic thinking block. A compatible host may send an empty one.
    AnthropicSignature,
    /// The opaque `data` of an Anthropic redacted thinking block, which has no text.
    AnthropicRedacted,
    /// The `encrypted_content` of an OpenAI Responses reasoning item.
    ResponsesEncrypted,
    /// The merged `reasoning_details` JSON array of an OpenRouter Chat Completions message.
    OpenrouterDetails,
}

/// The model and host that answered a request. Provider state returns only to the same model at the same host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Origin {
    /// The upstream model ID.
    pub model: String,
    /// The route base URL without its final slashes, so `https://h/v1/` and `https://h/v1` are one origin.
    pub base_url: String,
}

impl Origin {
    /// The same origin, borrowed.
    pub fn as_borrowed(&self) -> OriginRef<'_> {
        OriginRef {
            model: &self.model,
            base_url: &self.base_url,
        }
    }

    /// Report whether `target` names this model at this host.
    pub fn matches(&self, target: &Target) -> bool {
        self.as_borrowed() == OriginRef::of(target)
    }
}

/// A borrowed [`Origin`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OriginRef<'a> {
    /// The upstream model ID.
    pub model: &'a str,
    /// The route base URL without its final slashes.
    pub base_url: &'a str,
}

impl<'a> OriginRef<'a> {
    /// The origin of an answer to `target`. It borrows the target bytes.
    pub fn of(target: &'a Target) -> Self {
        OriginRef {
            model: &target.model,
            base_url: target.route.base_url.trim_end_matches('/'),
        }
    }
}

impl From<OriginRef<'_>> for Origin {
    fn from(origin: OriginRef<'_>) -> Self {
        Origin {
            model: origin.model.to_owned(),
            base_url: origin.base_url.to_owned(),
        }
    }
}

/// Provider state, and the origin that may receive it again. The state must return to its provider verbatim.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ReasoningReplay {
    /// The model and host that produced the state.
    pub origin: Origin,
    /// Which provider state `data` holds.
    pub kind: ReplayKind,
    /// The state bytes.
    pub data: String,
}

/// A borrowed [`ReasoningReplay`] that a stream event returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ReasoningReplayRef<'a> {
    /// The model and host that produced the state.
    pub origin: OriginRef<'a>,
    /// Which provider state `data` holds.
    pub kind: ReplayKind,
    /// The state bytes.
    pub data: &'a str,
}

impl From<ReasoningReplayRef<'_>> for ReasoningReplay {
    fn from(replay: ReasoningReplayRef<'_>) -> Self {
        ReasoningReplay {
            origin: replay.origin.into(),
            kind: replay.kind,
            data: replay.data.to_owned(),
        }
    }
}

/// A kind of content: what an attachment holds, and what a model reads or writes. `Other` is a media type that no
/// protocol names, and no model lists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Modality {
    /// Text.
    Text,
    /// An image.
    Image,
    /// Sound.
    Audio,
    /// A moving picture.
    Video,
    /// A PDF document.
    Pdf,
    /// A media type no protocol names.
    Other,
}

/// The digest of the content of a blob, such as its SHA-256.
pub type Digest = [u8; 32];

/// Bytes in the caller's store, named by the digest of their content. Equal digests name equal bytes. Thus the request
/// of a resumed context reads no blob that the encoder kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Blob {
    /// The digest of the content, such as its SHA-256. JSON holds it as 64 lowercase hex characters.
    #[serde(with = "digest_hex")]
    #[cfg_attr(feature = "ts", ts(type = "string"))]
    pub digest: Digest,
    /// The byte count of the content. [`BlobStore`] answers are checked against it.
    pub len: usize,
}

/// The caller's store of blob bytes. The encoder reads a blob only when it writes that element.
pub trait BlobStore: Sync {
    /// Answer the bytes of `digest`, or `None` when the store lacks them. The store can return borrowed bytes or an
    /// owned copy.
    ///
    /// # Errors
    ///
    /// Returns the store error when the read fails. The encode then fails with [`EncodeError::BlobRead`].
    fn read(&self, digest: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>>;
}

/// Answer the bytes of `blob` from `store`. Bytes of another length fail: the store holds other content.
pub(crate) fn read_blob<'s>(store: Option<&'s dyn BlobStore>, blob: &Blob) -> Result<Cow<'s, [u8]>, EncodeError> {
    let digest = blob.digest;
    let bytes = match store {
        Some(store) => store
            .read(&digest)
            .map_err(|source| EncodeError::BlobRead { digest, source })?,
        None => None,
    };
    bytes
        .filter(|bytes| bytes.len() == blob.len)
        .ok_or(EncodeError::UnresolvedBlob { digest })
}

/// Write a blob digest to JSON as 64 lowercase hex characters, the text that also names a stored file. Read either
/// case.
mod digest_hex {
    use serde::de::{Error, Unexpected};
    use serde::{Deserialize, Deserializer, Serializer};

    use super::{Digest, hex};

    pub(super) fn serialize<S: Serializer>(digest: &Digest, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&hex(digest))
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Digest, D::Error> {
        let text = String::deserialize(deserializer)?;
        let invalid = || D::Error::invalid_value(Unexpected::Str(&text), &"64 hex characters");
        if text.len() != 64 {
            return Err(invalid());
        }
        let digit = |byte: u8| match byte {
            b'0'..=b'9' => Ok(byte - b'0'),
            b'a'..=b'f' => Ok(byte - b'a' + 10),
            b'A'..=b'F' => Ok(byte - b'A' + 10),
            _ => Err(invalid()),
        };
        let mut digest = [0; 32];
        for (byte, &[high, low]) in digest.iter_mut().zip(text.as_bytes().as_chunks::<2>().0) {
            *byte = digit(high)? << 4 | digit(low)?;
        }
        Ok(digest)
    }
}

/// Which side a block belongs to: the user or the assistant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Role {
    /// The user's side.
    User,
    /// The assistant's side.
    Assistant,
}

impl Role {
    /// The wire name of the role.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

/// One block of the context. Its kind fixes its role ([`Block::role`]), so it holds only content of that role.
/// The serializer groups the blocks into the messages of each protocol.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum Block {
    /// User text.
    UserText(String),
    /// A user attachment.
    Media(Media),
    /// The result of a tool call.
    ToolResult(ToolResult),
    /// Assistant text.
    AssistantText(String),
    /// Assistant reasoning.
    Reasoning(Reasoning),
    /// A tool call of the assistant.
    ToolCall(ToolCall),
}

impl Block {
    /// A block of user text.
    pub fn user_text(text: impl Into<String>) -> Self {
        Block::UserText(text.into())
    }

    /// A block of assistant text.
    pub fn assistant_text(text: impl Into<String>) -> Self {
        Block::AssistantText(text.into())
    }

    /// The role the kind fixes.
    pub fn role(&self) -> Role {
        match self {
            Self::UserText(_) | Self::Media(_) | Self::ToolResult(_) => Role::User,
            Self::AssistantText(_) | Self::Reasoning(_) | Self::ToolCall(_) => Role::Assistant,
        }
    }
}

impl From<ToolResult> for Block {
    fn from(result: ToolResult) -> Self {
        Block::ToolResult(result)
    }
}

/// The text of the last answer in `context`: the text blocks of the assistant blocks before the tool results at the end,
/// one per line. A context that ends with other user input has no answer after it, so its text is empty.
pub fn answer_text(context: &[Block]) -> String {
    // The results of the calls of an answer come after it, also the error results of a cancel.
    let end = context
        .iter()
        .rposition(|block| !matches!(block, Block::ToolResult(_)))
        .map_or(0, |last| last + 1);
    let start = context[..end]
        .iter()
        .rposition(|block| block.role() != Role::Assistant)
        .map_or(0, |last| last + 1);
    let texts: Vec<&str> = context[start..end]
        .iter()
        .filter_map(|block| match block {
            Block::AssistantText(text) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    texts.join("\n")
}

/// The lowercase hex text of `bytes`. The text of a [`Digest`] is also the name of its stored file.
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    text
}

/// The largest attachment, in bytes: 5 MiB as base64. Anthropic on Bedrock and Google Cloud, which OpenRouter can use,
/// has this limit per image. A provider refuses a larger one in each later request, so the session could not go on.
pub const MAX_MEDIA_BYTES: u64 = 5 * 1024 * 1024 / 4 * 3;

/// One attachment. Its media type selects the block each protocol writes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Media {
    /// The bytes in the caller's store. The encoder reads them through [`Request::blobs`] only when it writes the
    /// element.
    pub blob: Blob,
    /// The IANA media type, such as `image/png` or `application/pdf`.
    pub mime: String,
    /// The name a provider requires beside file bytes. An image needs none.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub filename: String,
}

impl Media {
    /// An attachment of `blob` with the media type `mime` and no file name.
    pub fn new(blob: Blob, mime: impl Into<String>) -> Self {
        Media {
            blob,
            mime: mime.into(),
            filename: String::new(),
        }
    }

    /// The kind its media type names. A protocol writes a different part for each kind.
    pub fn kind(&self) -> Modality {
        let mime = self.mime.as_str();
        if mime.starts_with("image/") {
            Modality::Image
        } else if mime.starts_with("audio/") {
            Modality::Audio
        } else if mime.starts_with("video/") {
            Modality::Video
        } else if mime.starts_with("text/") {
            Modality::Text
        } else if mime == "application/pdf" {
            Modality::Pdf
        } else {
            Modality::Other
        }
    }
}

/// Reasoning text, and the provider state that returns with it. A request carries the state only to the origin that
/// produced it, in that protocol. Elsewhere the block drops, except where a dialect replays the text.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Reasoning {
    /// The reasoning text.
    pub text: String,
    /// `None` for text alone: a block that never finished, or one whose provider sent no state.
    // ts-rs marks the field optional only with `default` beside `skip_serializing_if`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay: Option<ReasoningReplay>,
}

impl Reasoning {
    /// The state a request to `target` may carry: the state of the same model at the same host, or `None`.
    pub fn replay_to(&self, target: &Target) -> Option<(ReplayKind, &str)> {
        let replay = self.replay.as_ref()?;
        replay
            .origin
            .matches(target)
            .then_some((replay.kind, replay.data.as_str()))
    }
}

/// A tool call of the assistant.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    /// The provider's call id.
    pub call_id: String,
    /// The tool name.
    pub name: String,
    /// A JSON object text, written verbatim. An empty text writes `{}`. The caller checks it.
    pub arguments: String,
}

/// A borrowed [`ToolCall`] that a stream event returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ToolCallRef<'a> {
    /// The provider's call id.
    pub call_id: &'a str,
    /// The tool name.
    pub name: &'a str,
    /// A JSON object text. The caller checks it.
    pub arguments: &'a str,
}

impl From<ToolCallRef<'_>> for ToolCall {
    fn from(call: ToolCallRef<'_>) -> Self {
        ToolCall {
            call_id: call.call_id.to_owned(),
            name: call.name.to_owned(),
            arguments: call.arguments.to_owned(),
        }
    }
}

/// The result of one tool call.
// Most results have no media and no loaded tools, so the JSON leaves out both empty lists.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolResult {
    /// The call this result answers.
    pub call_id: String,

    /// The result text.
    pub content: String,

    /// The call failed.
    pub is_error: bool,

    /// Attachments beside the text. Each protocol places them where its result shape allows.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<Media>,

    /// The deferred tools this result loads. Anthropic references each one by name. Responses answers its search
    /// with the declarations. A request that defers no tool writes only the text of the result.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub loaded: Vec<ToolDefinition>,
}

impl ToolResult {
    /// The result of a call that succeeded.
    pub fn success(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        ToolResult {
            call_id: call_id.into(),
            content: content.into(),
            is_error: false,
            media: Vec::new(),
            loaded: Vec::new(),
        }
    }

    /// The result of a call that failed. `content` tells the model what went wrong.
    pub fn error(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        ToolResult {
            is_error: true,
            ..ToolResult::success(call_id, content)
        }
    }

    /// The same result with attachments beside its text.
    #[must_use]
    pub fn with_media(self, media: Vec<Media>) -> Self {
        ToolResult { media, ..self }
    }

    /// The same result with the deferred tools that it loads.
    #[must_use]
    pub fn with_loaded(self, loaded: Vec<ToolDefinition>) -> Self {
        ToolResult { loaded, ..self }
    }
}

/// The name of the client tool that loads deferred tools. Responses declares it as the native `tool_search`
/// when a request defers a tool, and streams its calls under this name.
pub const SEARCH_TOOL_NAME: &str = "tool_search";

/// A tool definition for the provider.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolDefinition {
    /// The tool name.
    pub name: String,
    /// What the tool does, for the model.
    pub description: String,
    /// A JSON Schema object text, written verbatim. The caller checks it.
    pub input_schema: String,
    /// Exclude the definition from the prompt until a tool search names it. A request with a deferred tool asks for
    /// the native tool search. The encoder refuses it for Chat Completions and for a target without
    /// [`Target::tool_search`].
    pub defer_loading: bool,
}

impl ToolDefinition {
    /// The same tool, left out of the prompt until a tool search names it.
    #[must_use]
    pub fn deferred(self) -> Self {
        ToolDefinition {
            defer_loading: true,
            ..self
        }
    }
}

/// Ask for a response that matches a JSON Schema. Anthropic, and OpenAI with a strict schema, enforce it while
/// they sample.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct OutputSchema {
    /// The schema name OpenAI requires. Anthropic takes no name.
    pub name: String,
    /// A JSON Schema object text, written verbatim. The caller checks it.
    pub schema: String,
    /// OpenAI strict mode. A non-strict schema gives no guarantee.
    pub strict: bool,
}

impl OutputSchema {
    /// A strict schema named `response`.
    pub fn new(schema: impl Into<String>) -> Self {
        OutputSchema {
            name: "response".to_owned(),
            schema: schema.into(),
            strict: true,
        }
    }
}

/// A named reasoning effort from the closed portable set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
#[expect(missing_docs, reason = "each variant is the wire name of one effort")]
pub enum Effort {
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl Effort {
    /// The wire name of the effort.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Minimal => "minimal",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Xhigh => "xhigh",
            Self::Max => "max",
        }
    }
}

/// Select the Responses endpoint shape. The Codex backend refuses the sampling members and the output limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResponsesDialect {
    /// The OpenAI API.
    #[default]
    Standard,
    /// The ChatGPT Codex backend.
    Codex,
}

/// Select the Chat Completions body shape a host accepts. Mistral refuses any member its schema does not name,
/// `stream_options` among them, and reports the usage of a stream without a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChatDialect {
    /// The OpenAI shape.
    #[default]
    Standard,
    /// The Mistral shape.
    Mistral,
}

/// Select the output-token member an OpenAI-chat host accepts. Only OpenAI itself renamed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MaxTokensField {
    /// `max_tokens`.
    #[default]
    MaxTokens,
    /// `max_completion_tokens`.
    MaxCompletionTokens,
}

/// Select how a prior assistant turn returns its reasoning, which DeepSeek requires.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningReplayMode {
    /// Return no reasoning.
    #[default]
    None,
    /// Return the text as `reasoning_content`.
    ReasoningContent,
    /// Return the OpenRouter `reasoning_details` array.
    ReasoningDetails,
}

/// Select the reasoning control an OpenAI-chat host accepts. The dialects disagree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
#[expect(
    missing_docs,
    reason = "each variant names the host whose reasoning control it writes"
)]
pub enum ThinkingFormat {
    #[default]
    None,
    Openai,
    Openrouter,
    Deepseek,
    Zai,
    Qwen,
}

/// Whether and how the model thinks before it answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum Thinking {
    /// Ask for no reasoning. Some hosts accept the field and reason again.
    Off,
    /// Let the model choose when and how much to think. `None` leaves the endpoint default display.
    /// Only thinking can carry a display: Anthropic rejects one on disabled thinking.
    Adaptive(Option<ThinkingDisplay>),
    /// A thinking-token budget, written as given. Anthropic requires it below the output limit.
    Budget(u64),
}

/// Whether a thinking block returns its summary text. Anthropic bills the full thinking either way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum ThinkingDisplay {
    /// `summarized`.
    Summarized,
    /// `omitted`.
    Omitted,
}

impl ThinkingDisplay {
    /// The wire name of the display.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Summarized => "summarized",
            Self::Omitted => "omitted",
        }
    }
}

/// The reasoning one request asks for, as the caller chose it for the model. Each serializer writes the settings its
/// protocol has.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ReasoningSettings {
    /// Whether and how the model thinks. `None` leaves the endpoint default.
    pub thinking: Option<Thinking>,
    /// How hard the model thinks. `None` leaves the endpoint default.
    pub effort: Option<Effort>,
}

impl ReasoningSettings {
    /// The request asks for no reasoning.
    pub fn off(&self) -> bool {
        self.thinking == Some(Thinking::Off)
    }
}

/// The wire facts of one protocol. Its variant selects the serializer. The model and the route fill it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Wire {
    /// Anthropic Messages.
    AnthropicMessages(AnthropicWire),
    /// OpenAI Chat Completions.
    OpenaiChat(ChatWire),
    /// OpenAI Responses.
    OpenaiResponses(ResponsesWire),
}

impl Wire {
    /// The protocol this wire speaks.
    pub fn protocol(&self) -> Protocol {
        match self {
            Self::AnthropicMessages(_) => Protocol::AnthropicMessages,
            Self::OpenaiChat(_) => Protocol::OpenaiChat,
            Self::OpenaiResponses(_) => Protocol::OpenaiResponses,
        }
    }
}

/// The wire facts of an Anthropic Messages endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AnthropicWire {
    /// The default output limit. This API has none, so the target names one. A request limit replaces it.
    pub max_tokens: u32,
    /// Write the breakpoints the route cache policy asks for.
    pub cache: bool,
}

/// The wire facts of an OpenAI Chat Completions endpoint and model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ChatWire {
    /// The endpoint selects it, not the model.
    pub dialect: ChatDialect,
    /// The reasoning control the host accepts.
    pub thinking_format: ThinkingFormat,
    /// How a prior assistant turn returns its reasoning.
    pub reasoning_replay: ReasoningReplayMode,
    /// A compatible host keeps the original member.
    pub max_tokens_field: MaxTokensField,
}

/// The wire facts of an OpenAI Responses endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ResponsesWire {
    /// The endpoint selects it, not the model.
    pub dialect: ResponsesDialect,
    /// Write the breakpoint the route cache policy asks for.
    pub cache: bool,
}

/// Where and how one model is called. The caller supplies a valid route, and the credential at each encode.
/// The library applies every field as given: it reads no model capability and chooses no policy.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Target {
    /// Upstream model ID, not the catalog selector.
    pub model: Cow<'static, str>,
    /// Where the request goes.
    pub route: Route,
    /// How the request is written for this host and model. Its variant selects the protocol.
    /// [`crate::catalog::Entry::bind`] derives it from the catalog.
    pub wire: Wire,
    /// The model has a native tool search: Anthropic tool references, or the Responses client search. Chat Completions
    /// has none. Without a native tool search, the encoder refuses a request with a deferred tool.
    pub tool_search: bool,
}

/// The settings of a request apart from its system prompt, its context, its tools, and its blobs. A caller can store
/// one for each session, and [`Request::settings`] applies it. It names no model and holds no secret.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// The output limit. `None` leaves the endpoint default.
    pub max_output_tokens: Option<u32>,
    /// The reasoning settings.
    pub reasoning: ReasoningSettings,
    /// The sampling temperature. `None` leaves the endpoint default.
    pub temperature: Option<f64>,
    /// The nucleus sampling mass. `None` leaves the endpoint default.
    pub top_p: Option<f64>,
    /// The tool control.
    pub tool_choice: ToolChoice,
    /// The schema of the response. `None` leaves the response free.
    pub output_schema: Option<OutputSchema>,
}

impl Settings {
    /// Settings that leave every value at its endpoint default.
    pub const fn new() -> Self {
        Settings {
            max_output_tokens: None,
            reasoning: ReasoningSettings {
                thinking: None,
                effort: None,
            },
            temperature: None,
            top_p: None,
            tool_choice: ToolChoice::Auto,
            output_schema: None,
        }
    }

    /// The output limit. Without one, the endpoint default applies. For Anthropic, that is
    /// [`AnthropicWire::max_tokens`].
    #[must_use]
    pub fn max_output_tokens(self, tokens: u32) -> Self {
        Settings {
            max_output_tokens: Some(tokens),
            ..self
        }
    }

    /// The reasoning settings, both at once.
    #[must_use]
    pub fn reasoning(self, reasoning: ReasoningSettings) -> Self {
        Settings { reasoning, ..self }
    }

    /// Whether and how the model thinks.
    #[must_use]
    pub fn thinking(self, thinking: Thinking) -> Self {
        Settings {
            reasoning: ReasoningSettings {
                thinking: Some(thinking),
                ..self.reasoning
            },
            ..self
        }
    }

    /// How hard the model thinks.
    #[must_use]
    pub fn effort(self, effort: Effort) -> Self {
        Settings {
            reasoning: ReasoningSettings {
                effort: Some(effort),
                ..self.reasoning
            },
            ..self
        }
    }

    /// The sampling temperature. A NaN or an infinity fails the encode.
    #[must_use]
    pub fn temperature(self, temperature: f64) -> Self {
        Settings {
            temperature: Some(temperature),
            ..self
        }
    }

    /// The nucleus sampling mass. Anthropic asks that a request set this or the temperature, not both. A NaN or an
    /// infinity fails the encode.
    #[must_use]
    pub fn top_p(self, top_p: f64) -> Self {
        Settings {
            top_p: Some(top_p),
            ..self
        }
    }

    /// The tool control.
    #[must_use]
    pub fn tool_choice(self, tool_choice: ToolChoice) -> Self {
        Settings { tool_choice, ..self }
    }

    /// The schema of the response.
    #[must_use]
    pub fn output_schema(self, schema: OutputSchema) -> Self {
        Settings {
            output_schema: Some(schema),
            ..self
        }
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self::new()
    }
}

/// One request: the system prompt, the context, its tools, its blob store, and its settings.
/// [`crate::Encoder::encode`] borrows it only until it returns. [`Request::new`] takes the context, and each setter
/// changes one part.
#[derive(Clone, Copy)]
pub struct Request<'a> {
    pub(crate) blocks: &'a [Block],
    pub(crate) tools: &'a [ToolDefinition],
    pub(crate) blobs: Option<&'a dyn BlobStore>,
    pub(crate) system: &'a str,
    pub(crate) settings: &'a Settings,
    pub(crate) session_id: Option<&'a str>,
}

/// The settings of a request without [`Request::settings`]: each value at its endpoint default.
static DEFAULT_SETTINGS: Settings = Settings::new();

impl<'a> Request<'a> {
    /// A request of the whole context `blocks`, with every setting at its endpoint default. The provider
    /// judges an explicitly empty context.
    pub fn new(blocks: &'a [Block]) -> Self {
        Request {
            blocks,
            tools: &[],
            blobs: None,
            system: "",
            settings: &DEFAULT_SETTINGS,
            session_id: None,
        }
    }

    /// The system prompt. With an empty prompt, the request carries no system prompt.
    #[must_use]
    pub fn system(self, system: &'a str) -> Self {
        Request { system, ..self }
    }

    /// The settings of the request.
    #[must_use]
    pub fn settings(self, settings: &'a Settings) -> Self {
        Request { settings, ..self }
    }

    /// The session id of this request, for routing and the Responses cache key. A route can send the session id as a
    /// header, so it must be a valid header value. The ChatGPT host refuses a key longer than 64 bytes.
    #[must_use]
    pub fn session_id(self, session_id: &'a str) -> Self {
        Request {
            session_id: Some(session_id),
            ..self
        }
    }

    /// The tool declarations.
    #[must_use]
    pub fn tools(self, tools: &'a [ToolDefinition]) -> Self {
        Request { tools, ..self }
    }

    /// The store of every media blob. Without one, the request resolves no blob.
    #[must_use]
    pub fn blobs(self, blobs: &'a dyn BlobStore) -> Self {
        Request {
            blobs: Some(blobs),
            ..self
        }
    }
}

impl fmt::Debug for Request<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Request")
            .field("blocks", &self.blocks)
            .field("tools", &self.tools)
            .field("blobs", &self.blobs.map(|_| "BlobStore"))
            .field("settings", &self.settings)
            .finish()
    }
}

/// The tool controls every host understands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum ToolChoice {
    /// The model decides.
    #[default]
    Auto,
    /// The model calls no tool.
    None,
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::testing::assert_same;

    #[test]
    fn the_answer_text_is_the_text_of_the_last_run_of_assistant_blocks() {
        let context = [
            Block::user_text("Go."),
            Block::assistant_text("Early."),
            Block::ToolResult(ToolResult::error("call-1", "failed")),
            Block::assistant_text("One."),
            Block::assistant_text("Two."),
            Block::ToolCall(ToolCall {
                call_id: "call-2".to_owned(),
                name: "exec".to_owned(),
                arguments: "{}".to_owned(),
            }),
            Block::ToolResult(ToolResult::error("call-2", "not run")),
        ];

        assert_eq!(answer_text(&context), "One.\nTwo.");
        assert_eq!(answer_text(&context[..1]), "");
        // An empty answer adds no block, so the input of its round ends the context.
        assert_eq!(
            answer_text(&[Block::assistant_text("Old."), Block::user_text("New.")]),
            ""
        );
    }

    struct Store;

    impl BlobStore for Store {
        fn read(&self, _: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
            Ok(Some(Cow::Borrowed(b"ab")))
        }
    }

    #[test]
    fn blob_read_checks_length() {
        let blob = Blob {
            digest: [0; 32],
            len: 2,
        };
        let missing = || Err(EncodeError::UnresolvedBlob { digest: [0; 32] });
        assert_same(read_blob(None, &blob), missing());
        assert_same(read_blob(Some(&Store), &blob), Ok(Cow::Borrowed(&b"ab"[..])));
        // The store holds other content under this digest, so the request must not send it.
        assert_same(read_blob(Some(&Store), &Blob { len: 3, ..blob }), missing());
    }

    // The store keeps this JSON, so this test must catch a renamed field or variant.
    #[test]
    fn block_json_keeps_its_stored_shape() {
        let digest = "00ff".repeat(16);
        let blob = Blob {
            digest: [0x00, 0xff].repeat(16).try_into().unwrap(),
            len: 3,
        };
        let replay = ReasoningReplay {
            origin: Origin {
                model: "m".to_owned(),
                base_url: "https://h/v1".to_owned(),
            },
            kind: ReplayKind::AnthropicSignature,
            data: "sig".to_owned(),
        };
        let cases = [
            (Block::user_text("hi"), r#"{"user_text":"hi"}"#.to_owned()),
            (Block::assistant_text("ok"), r#"{"assistant_text":"ok"}"#.to_owned()),
            (
                Block::Media(Media::new(blob, "image/png")),
                format!(r#"{{"media":{{"blob":{{"digest":"{digest}","len":3}},"mime":"image/png"}}}}"#),
            ),
            (
                Block::Media(Media {
                    filename: "a.pdf".to_owned(),
                    ..Media::new(blob, "application/pdf")
                }),
                format!(
                    r#"{{"media":{{"blob":{{"digest":"{digest}","len":3}},"mime":"application/pdf","filename":"a.pdf"}}}}"#
                ),
            ),
            (
                Block::Reasoning(Reasoning {
                    text: "think".to_owned(),
                    replay: None,
                }),
                r#"{"reasoning":{"text":"think"}}"#.to_owned(),
            ),
            (
                Block::Reasoning(Reasoning {
                    text: "think".to_owned(),
                    replay: Some(replay),
                }),
                r#"{"reasoning":{"text":"think","replay":{"origin":{"model":"m","baseUrl":"https://h/v1"},"kind":"anthropic_signature","data":"sig"}}}"#.to_owned(),
            ),
            (
                Block::ToolCall(ToolCall { call_id: "c1".to_owned(), name: "read".to_owned(), arguments: r#"{"path":"a"}"#.to_owned() }),
                r#"{"tool_call":{"callId":"c1","name":"read","arguments":"{\"path\":\"a\"}"}}"#.to_owned(),
            ),
            (
                Block::ToolResult(ToolResult::success("c1", "text")),
                r#"{"tool_result":{"callId":"c1","content":"text","isError":false}}"#.to_owned(),
            ),
            (
                Block::ToolResult(
                    ToolResult::error("c1", "failed")
                        .with_media(vec![Media::new(blob, "image/png")])
                        .with_loaded(vec![ToolDefinition { name: "grep".to_owned(), description: "Search.".to_owned(), input_schema: "{}".to_owned(), defer_loading: false }.deferred()]),
                ),
                format!(
                    r#"{{"tool_result":{{"callId":"c1","content":"failed","isError":true,"media":[{{"blob":{{"digest":"{digest}","len":3}},"mime":"image/png"}}],"loaded":[{{"name":"grep","description":"Search.","inputSchema":"{{}}","deferLoading":true}}]}}}}"#
                ),
            ),
        ];
        for (block, json) in cases {
            assert_eq!(serde_json::to_string(&block).unwrap(), json);
            assert_eq!(serde_json::from_str::<Block>(&json).unwrap(), block);
        }
    }

    #[test]
    fn digest_json_needs_64_hex_characters() {
        let parse = |digest: &str| serde_json::from_str::<Blob>(&format!(r#"{{"digest":"{digest}","len":1}}"#));
        let mut expected = [0; 32];
        expected[0] = 0xab;
        expected[31] = 0x09;
        let text = format!("ab{}09", "0".repeat(60));
        assert_eq!(parse(&text).unwrap().digest, expected);
        assert_eq!(parse(&text.to_uppercase()).unwrap().digest, expected);
        assert!(parse(&text[..62]).is_err());
        assert!(parse(&format!("{text}00")).is_err());
        assert!(parse(&format!("zz{}", &text[2..])).is_err());
        assert!(parse(&format!("{}zz", &text[..62])).is_err());
    }

    // The store keeps the settings of each session as this JSON.
    #[test]
    fn settings_json_keeps_its_stored_shape() {
        let full = Settings::new()
            .max_output_tokens(1000)
            .thinking(Thinking::Adaptive(Some(ThinkingDisplay::Summarized)))
            .effort(Effort::Xhigh)
            .temperature(0.5)
            .top_p(0.9)
            .tool_choice(ToolChoice::None)
            .output_schema(OutputSchema::new(r#"{"type":"object"}"#));
        let cases = [
            (
                full,
                r#"{"maxOutputTokens":1000,"reasoning":{"thinking":{"adaptive":"summarized"},"effort":"xhigh"},"temperature":0.5,"topP":0.9,"toolChoice":"none","outputSchema":{"name":"response","schema":"{\"type\":\"object\"}","strict":true}}"#,
            ),
            (
                Settings::new().thinking(Thinking::Budget(2048)),
                r#"{"maxOutputTokens":null,"reasoning":{"thinking":{"budget":2048},"effort":null},"temperature":null,"topP":null,"toolChoice":"auto","outputSchema":null}"#,
            ),
            (
                Settings::new().thinking(Thinking::Off),
                r#"{"maxOutputTokens":null,"reasoning":{"thinking":"off","effort":null},"temperature":null,"topP":null,"toolChoice":"auto","outputSchema":null}"#,
            ),
        ];
        for (settings, json) in cases {
            assert_eq!(serde_json::to_string(&settings).unwrap(), json);
            assert_eq!(serde_json::from_str::<Settings>(json).unwrap(), settings);
        }
    }

    #[test]
    fn origin_ignores_trailing_slash() {
        fn at(model: &str, base_url: &str) -> Target {
            Target {
                model: model.to_owned().into(),
                route: Route {
                    base_url: base_url.to_owned().into(),
                    ..Route::default()
                },
                wire: Wire::OpenaiChat(ChatWire::default()),
                tool_search: false,
            }
        }
        let origin = Origin::from(OriginRef::of(&at("m", "https://h/v1/")));
        assert_eq!("https://h/v1", origin.base_url);
        assert!(origin.matches(&at("m", "https://h/v1")));
        assert!(!origin.matches(&at("m", "https://h/v2")));
        assert!(!origin.matches(&at("n", "https://h/v1")));
    }
}
