//! Client tools. A [`Toolset`] keeps each definition beside its handler. A call runs the handler of its name.

use std::error::Error;
use std::fmt;

use async_trait::async_trait;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;
use yuke_ai::{Media, ToolCall, ToolResult};

use crate::drive::{Observer, TurnEvent};

/// How the calls of one tool run beside other calls of the same answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Concurrency {
    /// The call runs alone. It starts after the calls before it end.
    Serial,

    /// The call runs together with the `Parallel` calls next to it. The calls share the task of the turn, so a call
    /// that blocks the thread stops the others. Wait with async I/O, or move blocking work off the task.
    Parallel,
}

/// A tool that the model can call.
#[async_trait]
pub trait Tool: Send + Sync {
    /// How the calls of this tool run beside other calls. Declare `Parallel` only for a tool whose calls do not
    /// depend on each other, for example a tool that only reads.
    fn concurrency(&self) -> Concurrency {
        Concurrency::Serial
    }

    /// How a frontend shows the calls of this tool. The model never sees the hints.
    fn hints(&self) -> ToolHints {
        ToolHints::default()
    }

    /// Run one call with its raw `arguments`.
    /// The tool parses the arguments, for example with [`parse_arguments`].
    /// `Err` reaches the model as an error result, and the turn continues.
    /// The result text includes each cause of the error.
    ///
    /// When the cancellation token of `context` is cancelled, stop the work. Return a result that describes the
    /// stopped work, for example the output so far and "Command aborted". The driver waits for the return.
    async fn call(
        &self,
        arguments: &str,
        context: &ToolContext<'_>,
    ) -> Result<ToolContent, Box<dyn Error + Send + Sync>>;
}

/// Parse the JSON `arguments` of a call into `T`. A tool calls it first, and `?` returns the parse error to the
/// model, for example a missing field. The struct then holds the checked arguments.
///
/// # Errors
///
/// Returns the parse error as the text of an error result when the arguments do not fit `T`.
pub fn parse_arguments<T: DeserializeOwned>(arguments: &str) -> Result<T, String> {
    serde_json::from_str(arguments).map_err(|error| format!("The arguments are not valid: {error}"))
}

/// What a call gives its tool besides the arguments.
pub struct ToolContext<'a> {
    block_index: usize,
    call: &'a ToolCall,
    cancellation_token: &'a CancellationToken,
    observer: &'a dyn Observer,
}

impl fmt::Debug for ToolContext<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ToolContext")
            .field("call", &self.call)
            .finish_non_exhaustive()
    }
}

impl<'a> ToolContext<'a> {
    pub(crate) fn new(
        block_index: usize,
        call: &'a ToolCall,
        cancellation_token: &'a CancellationToken,
        observer: &'a dyn Observer,
    ) -> Self {
        ToolContext {
            block_index,
            call,
            cancellation_token,
            observer,
        }
    }

    /// The id of the call. The provider pairs the result with the call by this id.
    pub fn call_id(&self) -> &str {
        &self.call.call_id
    }

    /// The token that a cancel of the turn cancels.
    pub fn cancellation_token(&self) -> &CancellationToken {
        self.cancellation_token
    }

    /// Show `text` as live output of the call, for example a line that a command prints. The observer receives it as
    /// [`TurnEvent::ToolOutput`] at once. The model does not receive it. Put the text for the model in the returned
    /// [`ToolContent`].
    pub fn output(&self, text: &str) {
        self.observer.event(&TurnEvent::ToolOutput {
            block_index: self.block_index,
            text,
        });
    }
}

/// The content of a call. The model sees its text and its media, and the user sees its display. An `Err` of
/// [`Tool::call`] is a failure with text only.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolContent {
    /// The result text.
    pub text: String,
    /// Attachments beside the text, for example an image that the tool read.
    pub media: Vec<Media>,
    /// The call failed. The model still sees the text and the media.
    pub is_error: bool,
    /// What a frontend shows in place of the text. The model never sees it.
    pub display: Vec<DisplayBlock>,
}

/// How a frontend shows the calls of a tool. The model never sees the hints.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolHints {
    /// The name of the summary line in place of the tool name.
    pub title: Option<String>,
    /// The argument of the call that the summary line shows.
    pub subject: Option<Subject>,
    /// The part of the output that a folded call shows.
    pub preview: Preview,
}

/// The argument of a call that its summary line shows.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Subject {
    /// The name of a top-level string argument.
    pub argument: String,
    /// What the value of the argument names.
    pub kind: SubjectKind,
}

/// What the subject argument names. A frontend can open a file or a URI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum SubjectKind {
    /// Plain text, such as a command.
    Text,
    /// A file path. A relative path starts in the folder of the call.
    File,
    /// A URI.
    Uri,
}

/// The part of the output that a folded call shows. An error always shows its first rows.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum Preview {
    /// The first rows.
    #[default]
    Head,
    /// The last rows.
    Tail,
    /// No rows.
    None,
}

/// One block that a frontend shows for a result. The model never sees it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DisplayBlock {
    /// Markdown text. A relative file link starts in the folder of the call, and `#L40` or `#L40-L52` names lines.
    Markdown {
        /// The Markdown source.
        text: String,
    },
    /// The change of one file.
    Diff {
        /// The path of the file. A relative path starts in the folder of the call.
        path: String,
        /// Unified hunks, each with its `@@` header.
        patch: String,
    },
}

/// The result of a call for the model, and its display for the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolOutcome {
    /// What the model receives.
    pub result: ToolResult,
    /// What a frontend shows in place of the result text.
    pub display: Vec<DisplayBlock>,
}

impl From<ToolResult> for ToolOutcome {
    fn from(result: ToolResult) -> Self {
        ToolOutcome {
            result,
            display: Vec::new(),
        }
    }
}

impl From<String> for ToolContent {
    fn from(text: String) -> Self {
        ToolContent {
            text,
            ..ToolContent::default()
        }
    }
}

impl From<&str> for ToolContent {
    fn from(text: &str) -> Self {
        ToolContent::from(text.to_owned())
    }
}

/// The most characters of a tool name. Each provider that yuke supports accepts it.
pub const TOOL_NAME_MAX: usize = 64;

/// Whether each provider that yuke supports accepts `character` in a tool name. Anthropic and OpenAI accept no other.
pub fn tool_name_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '_' | '-')
}

/// Stores the bytes of a result attachment, such as an image, for the session of a turn.
#[async_trait]
pub trait MediaStore: Send + Sync {
    /// Store `bytes`, and return their blob.
    ///
    /// # Errors
    ///
    /// Returns why the store failed.
    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, Box<dyn Error + Send + Sync>>;
}

/// Check that a tool can have `name`: it matches `^[a-zA-Z0-9_-]{1,64}$`, and the engine does not own it.
///
/// # Errors
///
/// Returns [`ToolNameError::Invalid`] for another form, and [`ToolNameError::Reserved`] for
/// [`yuke_ai::SEARCH_TOOL_NAME`] and `tool_call`.
pub fn check_tool_name(name: &str) -> Result<(), ToolNameError> {
    let valid = (1..=TOOL_NAME_MAX).contains(&name.len()) && name.chars().all(tool_name_character);
    if !valid {
        return Err(ToolNameError::Invalid(name.to_owned()));
    }
    if [yuke_ai::SEARCH_TOOL_NAME, TOOL_CALL_NAME].contains(&name) {
        return Err(ToolNameError::Reserved(name.to_owned()));
    }
    Ok(())
}

/// The error of [`Toolset::add`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolNameError {
    /// Another tool already has the name. One name can select only one handler.
    Duplicate(String),
    /// The engine owns the name: [`yuke_ai::SEARCH_TOOL_NAME`] or `tool_call`.
    Reserved(String),
    /// The name does not match `^[a-zA-Z0-9_-]{1,64}$`.
    Invalid(String),
}

impl fmt::Display for ToolNameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ToolNameError::Duplicate(name) => write!(f, "another tool already has the name \"{name}\""),
            ToolNameError::Reserved(name) => write!(f, "the engine reserves the tool name \"{name}\""),
            ToolNameError::Invalid(name) => {
                write!(f, "the tool name \"{name}\" does not match ^[a-zA-Z0-9_-]{{1,64}}$")
            }
        }
    }
}

impl Error for ToolNameError {}

/// The name of the bridge tool that calls a deferred tool, on a target without a native tool search.
pub(crate) const TOOL_CALL_NAME: &str = "tool_call";

/// The tools that a driver offers to the model.
#[derive(Default)]
pub struct Toolset {
    definitions: Vec<yuke_ai::ToolDefinition>,
    /// One handler for each definition, at the same index. The definitions stay one slice, so a request without a
    /// deferred tool borrows them without a copy.
    handlers: Vec<Box<dyn Tool>>,
    /// The hints of each handler, at the same index.
    hints: Vec<ToolHints>,
    /// The folder where the tools run, for a frontend that opens a relative path of a call. The engine does not read it.
    folder: Option<String>,
}

impl fmt::Debug for Toolset {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Toolset")
            .field("definitions", &self.definitions)
            .finish_non_exhaustive()
    }
}

impl Toolset {
    /// An empty toolset.
    pub const fn new() -> Self {
        Toolset {
            definitions: Vec::new(),
            handlers: Vec::new(),
            hints: Vec::new(),
            folder: None,
        }
    }

    /// Set the folder where the tools run. Each call carries it to the frontend.
    pub fn set_folder(&mut self, folder: impl Into<String>) {
        self.folder = Some(folder.into());
    }

    /// The folder where the tools run, if the caller set one.
    pub(crate) fn folder(&self) -> Option<&str> {
        self.folder.as_deref()
    }

    /// The hints of the tool `name`, or the default hints for a name that no tool has.
    pub(crate) fn hints_of(&self, name: &str) -> ToolHints {
        self.definitions
            .iter()
            .position(|definition| definition.name == name)
            .map(|index| self.hints[index].clone())
            .unwrap_or_default()
    }

    /// Offer `definition` to the model. A call with that name runs `tool`.
    ///
    /// # Errors
    ///
    /// Returns [`ToolNameError`] if the name does not match `^[a-zA-Z0-9_-]{1,64}$`, if the engine reserves the
    /// name, or if the toolset already holds a tool of that name. The toolset stays unchanged.
    pub fn add(&mut self, definition: yuke_ai::ToolDefinition, tool: impl Tool + 'static) -> Result<(), ToolNameError> {
        check_tool_name(&definition.name)?;
        if self.definitions.iter().any(|held| held.name == definition.name) {
            return Err(ToolNameError::Duplicate(definition.name));
        }
        self.definitions.push(definition);
        self.hints.push(tool.hints());
        self.handlers.push(Box::new(tool));
        Ok(())
    }

    /// The definitions, in the order of [`Toolset::add`].
    pub(crate) fn definitions(&self) -> &[yuke_ai::ToolDefinition] {
        &self.definitions
    }

    /// The definitions that stay out of the model's context until a search finds them, in the order of
    /// [`Toolset::add`].
    pub fn deferred(&self) -> impl Iterator<Item = &yuke_ai::ToolDefinition> {
        self.definitions.iter().filter(|definition| definition.defer_loading)
    }

    /// Whether a tool is deferred. Without one, the requests declare no search and no bridge.
    pub(crate) fn has_deferred(&self) -> bool {
        self.deferred().next().is_some()
    }

    /// The concurrency of the tool of `name`. A name without a tool runs nothing, so it does not wait for other calls.
    pub(crate) fn concurrency(&self, name: &str) -> Concurrency {
        match self.definitions.iter().position(|tool| tool.name == name) {
            Some(index) => self.handlers[index].concurrency(),
            None => Concurrency::Parallel,
        }
    }

    /// Run `call`, and return its outcome. The tool sees `context`.
    pub(crate) async fn call(&self, call: &ToolCall, context: &ToolContext<'_>) -> ToolOutcome {
        let Some(index) = self.definitions.iter().position(|tool| tool.name == call.name) else {
            return ToolResult::error(&call.call_id, format!("Unknown tool: {}", call.name)).into();
        };

        match self.handlers[index].call(&call.arguments, context).await {
            Ok(content) => ToolOutcome {
                result: ToolResult {
                    is_error: content.is_error,
                    ..ToolResult::success(&call.call_id, content.text)
                }
                .with_media(content.media),
                display: content.display,
            },
            Err(error) => ToolResult::error(&call.call_id, crate::chain_text(error.as_ref())).into(),
        }
    }
}
