//! Client tools. A [`Toolset`] keeps each definition beside its handler. A call runs the handler of its name.

use async_trait::async_trait;
use serde::de::DeserializeOwned;
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

    /// Run one call with its JSON `arguments`. The engine checks that the arguments are valid JSON first. `Err`
    /// reaches the model as an error result, and the turn continues.
    ///
    /// When the cancellation token of `context` is cancelled, stop the work. Return a result that describes the
    /// stopped work, for example the output so far and "Command aborted". The driver waits for the return.
    async fn call(&self, arguments: &str, context: &ToolContext<'_>) -> Result<ToolContent, String>;
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

impl std::fmt::Debug for ToolContext<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
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

/// The answer of a call that succeeds. The model sees its text and its media.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolContent {
    /// The result text.
    pub text: String,
    /// Attachments beside the text, for example an image that the tool read.
    pub media: Vec<Media>,
}

impl From<String> for ToolContent {
    fn from(text: String) -> Self {
        ToolContent {
            text,
            media: Vec::new(),
        }
    }
}

impl From<&str> for ToolContent {
    fn from(text: &str) -> Self {
        ToolContent::from(text.to_owned())
    }
}

/// The error of [`Toolset::add`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolNameError {
    /// Another tool already has the name. One name can select only one handler.
    Duplicate(String),
    /// The engine owns the name: [`yuke_ai::SEARCH_TOOL_NAME`] or [`TOOL_CALL_NAME`].
    Reserved(String),
}

impl std::fmt::Display for ToolNameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ToolNameError::Duplicate(name) => write!(f, "another tool already has the name \"{name}\""),
            ToolNameError::Reserved(name) => write!(f, "the engine reserves the tool name \"{name}\""),
        }
    }
}

impl std::error::Error for ToolNameError {}

/// The name of the bridge tool that calls a deferred tool, on a target without a native tool search.
pub const TOOL_CALL_NAME: &str = "tool_call";

/// The tools that a driver offers to the model.
#[derive(Default)]
pub struct Toolset {
    definitions: Vec<yuke_ai::ToolDefinition>,
    /// One handler for each definition, at the same index. The definitions stay one slice, so a request without a
    /// deferred tool borrows them without a copy.
    handlers: Vec<Box<dyn Tool>>,
}

impl std::fmt::Debug for Toolset {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
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
        }
    }

    /// Offer `definition` to the model. A call with that name runs `tool`.
    ///
    /// # Errors
    ///
    /// Returns [`ToolNameError`] if the toolset already holds a tool of that name, or if the engine reserves the
    /// name. The toolset stays unchanged.
    pub fn add(&mut self, definition: yuke_ai::ToolDefinition, tool: impl Tool + 'static) -> Result<(), ToolNameError> {
        if [yuke_ai::SEARCH_TOOL_NAME, TOOL_CALL_NAME].contains(&definition.name.as_str()) {
            return Err(ToolNameError::Reserved(definition.name));
        }
        if self.definitions.iter().any(|held| held.name == definition.name) {
            return Err(ToolNameError::Duplicate(definition.name));
        }
        self.definitions.push(definition);
        self.handlers.push(Box::new(tool));
        Ok(())
    }

    /// The definitions, in the order of [`Toolset::add`].
    pub(crate) fn definitions(&self) -> &[yuke_ai::ToolDefinition] {
        &self.definitions
    }

    /// The definitions that stay out of the model's context until a search finds them, in the order of
    /// [`Toolset::add`]. The search tool names no tool, so a caller can list these in its system prompt.
    pub fn deferred(&self) -> impl Iterator<Item = &yuke_ai::ToolDefinition> {
        self.definitions.iter().filter(|definition| definition.defer_loading)
    }

    /// The definition of the tool `name`.
    pub(crate) fn definition(&self, name: &str) -> Option<&yuke_ai::ToolDefinition> {
        self.definitions.iter().find(|definition| definition.name == name)
    }

    /// The concurrency of the tool of `name`. A name without a tool runs nothing, so it does not wait for other calls.
    pub(crate) fn concurrency(&self, name: &str) -> Concurrency {
        match self.definitions.iter().position(|tool| tool.name == name) {
            Some(index) => self.handlers[index].concurrency(),
            None => Concurrency::Parallel,
        }
    }

    /// Run `call`, and return its result. The tool sees `context`.
    pub(crate) async fn call(&self, call: &ToolCall, context: &ToolContext<'_>) -> ToolResult {
        let Some(index) = self.definitions.iter().position(|tool| tool.name == call.name) else {
            return ToolResult::error(&call.call_id, format!("Unknown tool: {}", call.name));
        };

        match self.handlers[index].call(&call.arguments, context).await {
            Ok(content) => ToolResult::success(&call.call_id, content.text).with_media(content.media),
            Err(content) => ToolResult::error(&call.call_id, content),
        }
    }
}
