//! What one call asks for: the request, its settings, and its tools. A request borrows its parts only for one
//! encode.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

#[cfg(doc)]
use crate::{AnthropicWire, Target};
use crate::{BlobStore, Block, ParseError};

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

/// A named reasoning effort from the portable set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
#[expect(missing_docs, reason = "each variant is the wire name of one effort")]
#[non_exhaustive]
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

impl fmt::Display for Effort {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Parse the wire name that [`Effort::as_str`] gives.
impl FromStr for Effort {
    type Err = ParseError;

    fn from_str(text: &str) -> Result<Self, ParseError> {
        crate::parse_name(text, "a reasoning effort")
    }
}

/// Whether and how the model thinks before it answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
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
#[non_exhaustive]
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
    pub(crate) cached: Option<usize>,
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
            cached: None,
        }
    }

    /// Put the cache marker on the last block that the protocol can mark among the first `blocks` blocks. Without
    /// it, the marker goes on the last such block of the whole context.
    #[must_use]
    pub fn cached(self, blocks: usize) -> Self {
        Request {
            cached: Some(blocks),
            ..self
        }
    }

    /// The blocks that the cache marker can go on.
    pub(crate) fn cacheable_blocks(&self) -> &'a [Block] {
        &self.blocks[..self.cached.unwrap_or(self.blocks.len()).min(self.blocks.len())]
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
#[non_exhaustive]
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

    // A command line and a configuration name an effort by its wire name.
    #[test]
    fn each_effort_reads_back_from_its_wire_name() {
        let efforts = [
            (Effort::Minimal, "minimal"),
            (Effort::Low, "low"),
            (Effort::Medium, "medium"),
            (Effort::High, "high"),
            (Effort::Xhigh, "xhigh"),
            (Effort::Max, "max"),
        ];
        for (effort, name) in efforts {
            assert_eq!(effort.to_string(), name);
            assert_eq!(name.parse(), Ok(effort));
        }
        assert_eq!(
            "extreme".parse::<Effort>().map_err(|error| error.to_string()),
            Err("`extreme` is not a reasoning effort".to_owned())
        );
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
}
