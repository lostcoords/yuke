//! What a call says: the target, the request, its blocks and tools, and the wire facts of each protocol.
//! A block owns its bytes, so a conversation is a `Vec<Block>`. A request borrows its parts only for one encode.

use std::borrow::Cow;
use std::fmt;

use crate::encoder::EncodeError;
use crate::route::{Credential, Route};

/// The wire protocol of one endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ReasoningReplay {
    /// The model and host that produced the state.
    pub origin: Origin,
    /// Which provider state `data` holds.
    pub kind: ReplayKind,
    /// The state bytes.
    pub data: String,
}

impl ReasoningReplay {
    /// The same replay, borrowed.
    pub fn as_borrowed(&self) -> ReasoningReplayRef<'_> {
        ReasoningReplayRef {
            origin: self.origin.as_borrowed(),
            kind: self.kind,
            data: &self.data,
        }
    }
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
#[non_exhaustive]
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

/// Bytes in the caller's store, named by the digest of their content. Equal digests name equal bytes. Thus a resumed
/// history reads no blob that the encoder kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Blob {
    /// The digest of the content, such as its SHA-256.
    pub digest: [u8; 32],
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
    fn read(&self, digest: &[u8; 32]) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>>;
}

/// Answer the bytes of `blob` from `store`. Bytes of another length fail: the store holds other content.
pub(crate) fn read_blob<'s>(store: Option<&'s dyn BlobStore>, blob: &Blob) -> Result<Cow<'s, [u8]>, EncodeError> {
    let digest = blob.digest;
    let bytes = match store {
        Some(store) => store.read(&digest).map_err(|source| EncodeError::BlobRead {
            digest,
            source: source.into(),
        })?,
        None => None,
    };
    bytes
        .filter(|bytes| bytes.len() == blob.len)
        .ok_or(EncodeError::UnresolvedBlob { digest })
}

/// Which side of the conversation a block belongs to.
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

/// One block of the conversation. Its kind fixes its role ([`Block::role`]), so it holds only content of that role.
/// The serializer groups the blocks into the messages of each protocol.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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

impl From<Media> for Block {
    fn from(media: Media) -> Self {
        Block::Media(media)
    }
}

impl From<ToolResult> for Block {
    fn from(result: ToolResult) -> Self {
        Block::ToolResult(result)
    }
}

impl From<Reasoning> for Block {
    fn from(reasoning: Reasoning) -> Self {
        Block::Reasoning(reasoning)
    }
}

impl From<ToolCall> for Block {
    fn from(call: ToolCall) -> Self {
        Block::ToolCall(call)
    }
}

/// One attachment. Its media type selects the block each protocol writes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Media {
    /// The bytes in the caller's store. The encoder reads them through [`Request::blobs`] only when it writes the
    /// element.
    pub blob: Blob,
    /// The IANA media type, such as `image/png` or `application/pdf`.
    pub mime: String,
    /// The name a provider requires beside file bytes. An image needs none.
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

    /// The same attachment with the file name a provider requires beside file bytes.
    #[must_use]
    pub fn with_filename(self, filename: impl Into<String>) -> Self {
        Media {
            filename: filename.into(),
            ..self
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Reasoning {
    /// The reasoning text.
    pub text: String,
    /// `None` for text alone: a block that never finished, or one whose provider sent no state.
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolCall {
    /// The provider's call id.
    pub call_id: String,
    /// The tool name.
    pub name: String,
    /// A JSON object text, written verbatim. An empty text writes `{}`. The caller checks it.
    pub arguments: String,
}

impl ToolCall {
    /// A call of the tool `name` with the provider's `call_id` and the JSON object text `arguments`.
    pub fn new(call_id: impl Into<String>, name: impl Into<String>, arguments: impl Into<String>) -> Self {
        ToolCall {
            call_id: call_id.into(),
            name: name.into(),
            arguments: arguments.into(),
        }
    }

    /// The same call, borrowed.
    pub fn as_borrowed(&self) -> ToolCallRef<'_> {
        ToolCallRef {
            call_id: &self.call_id,
            name: &self.name,
            arguments: &self.arguments,
        }
    }
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolResult {
    /// The call this result answers.
    pub call_id: String,
    /// The result text.
    pub content: String,
    /// The call failed.
    pub is_error: bool,
    /// Attachments beside the text. Each protocol places them where its result shape allows.
    pub media: Vec<Media>,
    /// The deferred tools this result loads. Anthropic references each one by name. Responses answers its search
    /// with the declarations.
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolDefinition {
    /// The tool name.
    pub name: String,
    /// What the tool does, for the model.
    pub description: String,
    /// A JSON Schema object text, written verbatim. The caller checks it.
    pub input_schema: String,
    /// Exclude the definition from the prompt until a tool search names it.
    pub defer_loading: bool,
    /// Constrain the arguments to `input_schema`, as OpenAI and Anthropic both offer. A schema that strict mode does
    /// not admit returns 400 when it is on.
    pub strict: bool,
}

impl ToolDefinition {
    /// A tool with a name, a description for the model, and a JSON Schema object text for its arguments.
    pub fn new(name: impl Into<String>, description: impl Into<String>, input_schema: impl Into<String>) -> Self {
        ToolDefinition {
            name: name.into(),
            description: description.into(),
            input_schema: input_schema.into(),
            defer_loading: false,
            strict: false,
        }
    }

    /// The same tool, left out of the prompt until a tool search names it.
    #[must_use]
    pub fn deferred(self) -> Self {
        ToolDefinition {
            defer_loading: true,
            ..self
        }
    }

    /// The same tool, with its arguments constrained to its schema.
    #[must_use]
    pub fn strict(self) -> Self {
        ToolDefinition { strict: true, ..self }
    }
}

/// Constrain the response to a JSON Schema. The provider enforces it while it samples.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OutputSchema<'a> {
    /// The schema name OpenAI requires. Anthropic takes no name.
    pub name: &'a str,
    /// A JSON Schema object text, written verbatim. The caller checks it.
    pub schema: &'a str,
    /// OpenAI strict mode. A non-strict schema gives no guarantee.
    pub strict: bool,
}

impl<'a> OutputSchema<'a> {
    /// A strict schema named `response`.
    pub fn new(schema: &'a str) -> Self {
        OutputSchema {
            name: "response",
            schema,
            strict: true,
        }
    }
}

/// A named reasoning effort from the closed portable set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

/// Select the Responses endpoint shape. The Codex backend refuses the sampling members and the output limit, and
/// requires instructions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ResponsesDialect {
    /// The OpenAI API.
    #[default]
    Standard,
    /// The ChatGPT Codex backend.
    Codex,
}

/// Select the Chat Completions body shape a host accepts. Mistral refuses any member its schema does not name,
/// `stream_options` among them, and reports the usage of a stream without a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ChatDialect {
    /// The OpenAI shape.
    #[default]
    Standard,
    /// The Mistral shape.
    Mistral,
}

/// Select the output-token member an OpenAI-chat host accepts. Only OpenAI itself renamed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum MaxTokensField {
    /// `max_tokens`.
    #[default]
    MaxTokens,
    /// `max_completion_tokens`.
    MaxCompletionTokens,
}

/// Select how a prior assistant turn returns its reasoning, which DeepSeek requires.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ReasoningReplayMode {
    /// Return no reasoning.
    #[default]
    None,
    /// Return the text as `reasoning`.
    Reasoning,
    /// Return the text as `reasoning_content`.
    ReasoningContent,
    /// Return the OpenRouter `reasoning_details` array.
    ReasoningDetails,
}

/// Select the reasoning control an OpenAI-chat host accepts. The dialects disagree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
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
    Together,
    AntLing,
}

/// Whether and how the model thinks before it answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
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
#[non_exhaustive]
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

/// Where and how one model is called. The caller supplies valid route and credential configuration.
/// The library applies every field as given: it reads no model capability and chooses no policy.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Target {
    /// Upstream model ID, not the catalog selector.
    pub model: Cow<'static, str>,
    /// Where the request goes.
    pub route: Route,
    /// The secret the route presents.
    pub credential: Credential,
    /// How the request is written for this host and model. Its variant selects the protocol.
    /// [`crate::catalog::Entry::wire`] derives it from the catalog.
    pub wire: Wire,
}

/// One request: the conversation, its generation settings, and its call settings. [`crate::Encoder::encode`] borrows
/// it only until it returns. [`Request::new`] takes the conversation, and each setter changes one setting.
#[derive(Clone, Copy)]
pub struct Request<'a> {
    pub(crate) blocks: &'a [Block],
    pub(crate) system: &'a str,
    pub(crate) tools: &'a [ToolDefinition],
    pub(crate) blobs: Option<&'a dyn BlobStore>,
    pub(crate) max_output_tokens: Option<u32>,
    pub(crate) reasoning: ReasoningSettings,
    pub(crate) output_schema: Option<OutputSchema<'a>>,
    pub(crate) temperature: Option<f64>,
    pub(crate) top_p: Option<f64>,
    pub(crate) tool_choice: ToolChoice,
    pub(crate) session_id: &'a str,
}

impl<'a> Request<'a> {
    /// A request of the whole conversation `blocks`, with every setting at its endpoint default. The provider
    /// judges an explicitly empty conversation.
    pub fn new(blocks: &'a [Block]) -> Self {
        Request {
            blocks,
            system: "",
            tools: &[],
            blobs: None,
            max_output_tokens: None,
            reasoning: ReasoningSettings::default(),
            output_schema: None,
            temperature: None,
            top_p: None,
            tool_choice: ToolChoice::Auto,
            session_id: "",
        }
    }

    /// The system prompt. An empty prompt writes none.
    #[must_use]
    pub fn system(self, system: &'a str) -> Self {
        Request { system, ..self }
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

    /// The output limit. Without one, the endpoint default applies. For Anthropic, that is
    /// [`AnthropicWire::max_tokens`].
    #[must_use]
    pub fn max_output_tokens(self, tokens: u32) -> Self {
        Request {
            max_output_tokens: Some(tokens),
            ..self
        }
    }

    /// The reasoning settings, both at once.
    #[must_use]
    pub fn reasoning(self, reasoning: ReasoningSettings) -> Self {
        Request { reasoning, ..self }
    }

    /// Whether and how the model thinks. Without it, the endpoint default applies.
    #[must_use]
    pub fn thinking(self, thinking: Thinking) -> Self {
        Request {
            reasoning: ReasoningSettings {
                thinking: Some(thinking),
                ..self.reasoning
            },
            ..self
        }
    }

    /// How hard the model thinks. Without it, the endpoint default applies.
    #[must_use]
    pub fn effort(self, effort: Effort) -> Self {
        Request {
            reasoning: ReasoningSettings {
                effort: Some(effort),
                ..self.reasoning
            },
            ..self
        }
    }

    /// Constrain the response to a schema. Without one, the response is free.
    #[must_use]
    pub fn output_schema(self, schema: OutputSchema<'a>) -> Self {
        Request {
            output_schema: Some(schema),
            ..self
        }
    }

    /// The sampling temperature. Without it, the endpoint default applies. A NaN or an infinity fails the encode.
    #[must_use]
    pub fn temperature(self, temperature: f64) -> Self {
        Request {
            temperature: Some(temperature),
            ..self
        }
    }

    /// The nucleus sampling mass. Anthropic asks that a request set this or the temperature, not both. A NaN or an
    /// infinity fails the encode.
    #[must_use]
    pub fn top_p(self, top_p: f64) -> Self {
        Request {
            top_p: Some(top_p),
            ..self
        }
    }

    /// The tool control.
    #[must_use]
    pub fn tool_choice(self, tool_choice: ToolChoice) -> Self {
        Request { tool_choice, ..self }
    }

    /// A stable session ID for routing and the Responses cache key. A route can send it as a header, so it must be a
    /// valid header value. The ChatGPT host refuses a key longer than 64 bytes.
    #[must_use]
    pub fn session_id(self, session_id: &'a str) -> Self {
        Request { session_id, ..self }
    }
}

impl fmt::Debug for Request<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Request")
            .field("blocks", &self.blocks)
            .field("system", &self.system)
            .field("tools", &self.tools)
            .field("blobs", &self.blobs.map(|_| "BlobStore"))
            .field("max_output_tokens", &self.max_output_tokens)
            .field("reasoning", &self.reasoning)
            .field("output_schema", &self.output_schema)
            .field("temperature", &self.temperature)
            .field("top_p", &self.top_p)
            .field("tool_choice", &self.tool_choice)
            .field("session_id", &self.session_id)
            .finish()
    }
}

/// The tool controls every host understands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
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

    struct Store;

    impl BlobStore for Store {
        fn read(&self, _: &[u8; 32]) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
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

    #[test]
    fn origin_ignores_trailing_slash() {
        fn at(model: &str, base_url: &str) -> Target {
            Target {
                model: model.to_owned().into(),
                route: Route {
                    base_url: base_url.to_owned().into(),
                    ..Route::default()
                },
                credential: Credential::None,
                wire: Wire::OpenaiChat(ChatWire::default()),
            }
        }
        let origin = Origin::from(OriginRef::of(&at("m", "https://h/v1/")));
        assert_eq!("https://h/v1", origin.base_url);
        assert!(origin.matches(&at("m", "https://h/v1")));
        assert!(!origin.matches(&at("m", "https://h/v2")));
        assert!(!origin.matches(&at("n", "https://h/v1")));
    }
}
