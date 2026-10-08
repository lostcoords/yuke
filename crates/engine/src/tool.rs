//! Client tools. A [`Toolset`] keeps each definition beside its handler. A call runs the handler of its name.

use async_trait::async_trait;
use serde::de::DeserializeOwned;
use tokio_util::sync::CancellationToken;
use yuke_ai::{Media, ToolCall, ToolResult};

use crate::drive::{Observer, TurnEvent};

/// A tool that the model can call.
#[async_trait]
pub trait Tool: Send + Sync {
    /// Run one call with its JSON `arguments`. The engine checks that the arguments are valid JSON first. `Err`
    /// reaches the model as an error result, and the turn continues.
    ///
    /// When the cancellation token of `context` is cancelled, stop the work. Return a result that describes the
    /// stopped work, for example the output so far and "Command aborted". The driver waits for the return.
    async fn call(&self, arguments: &str, context: &mut ToolContext<'_>) -> Result<ToolContent, String>;
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
    call: &'a ToolCall,
    cancellation_token: &'a CancellationToken,
    observer: &'a mut dyn Observer,
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
        call: &'a ToolCall,
        cancellation_token: &'a CancellationToken,
        observer: &'a mut dyn Observer,
    ) -> Self {
        ToolContext {
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
    pub fn output(&mut self, text: &str) {
        self.observer.event(&TurnEvent::ToolOutput {
            call_id: &self.call.call_id,
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

impl ToolContent {
    /// The same answer with attachments beside its text.
    #[must_use]
    pub fn with_media(self, media: Vec<Media>) -> Self {
        ToolContent { media, ..self }
    }
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

/// The error of [`Toolset::add`] when another tool already has the name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateToolName {
    /// The name that two tools share.
    pub name: String,
}

impl std::fmt::Display for DuplicateToolName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "another tool already has the name \"{}\"", self.name)
    }
}

impl std::error::Error for DuplicateToolName {}

/// The tools that a driver offers to the model.
#[derive(Default)]
pub struct Toolset {
    definitions: Vec<yuke_ai::ToolDefinition>,
    /// One handler for each definition, at the same index.
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
    /// Returns [`DuplicateToolName`] if the toolset already holds a tool of that name. The toolset stays unchanged. One
    /// name can select only one handler.
    pub fn add(
        &mut self,
        definition: yuke_ai::ToolDefinition,
        tool: impl Tool + 'static,
    ) -> Result<(), DuplicateToolName> {
        if self.definitions.iter().any(|held| held.name == definition.name) {
            return Err(DuplicateToolName { name: definition.name });
        }
        self.definitions.push(definition);
        self.handlers.push(Box::new(tool));
        Ok(())
    }

    /// The definitions, in the order of [`Toolset::add`].
    pub(crate) fn definitions(&self) -> &[yuke_ai::ToolDefinition] {
        &self.definitions
    }

    /// Run `call`, and return its result. The tool sees `context`.
    pub(crate) async fn call(&self, call: &ToolCall, context: &mut ToolContext<'_>) -> ToolResult {
        let Some(index) = self.definitions.iter().position(|tool| tool.name == call.name) else {
            return ToolResult::error(&call.call_id, format!("Unknown tool: {}", call.name));
        };

        match self.handlers[index].call(&call.arguments, context).await {
            Ok(content) => ToolResult::success(&call.call_id, content.text).with_media(content.media),
            Err(content) => ToolResult::error(&call.call_id, content),
        }
    }
}
