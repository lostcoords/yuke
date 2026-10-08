//! Client tools. A [`Toolset`] keeps each definition beside its handler. A call runs the handler of its name.

use ai::{ToolCall, ToolResult};
use async_trait::async_trait;
use tokio_util::sync::CancellationToken;

/// A tool that the model can call.
#[async_trait]
pub trait Tool: Send + Sync {
    /// Run one call with its JSON `arguments`. `Err` reaches the model as an error result, and the turn continues.
    ///
    /// When `cancellation_token` is cancelled, stop the work. Return a result that describes the stopped work, for
    /// example the output so far and "Command aborted". The driver waits for the return.
    async fn call(&self, arguments: &str, cancellation_token: &CancellationToken) -> Result<String, String>;
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
    definitions: Vec<ai::ToolDefinition>,
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
    pub fn add(&mut self, definition: ai::ToolDefinition, tool: impl Tool + 'static) -> Result<(), DuplicateToolName> {
        if self.definitions.iter().any(|held| held.name == definition.name) {
            return Err(DuplicateToolName { name: definition.name });
        }
        self.definitions.push(definition);
        self.handlers.push(Box::new(tool));
        Ok(())
    }

    /// The definitions, in the order of [`Toolset::add`].
    pub(crate) fn definitions(&self) -> &[ai::ToolDefinition] {
        &self.definitions
    }

    /// Run `call`, and return its result. The tool sees `cancellation_token`.
    pub(crate) async fn call(&self, call: &ToolCall, cancellation_token: &CancellationToken) -> ToolResult {
        let Some(index) = self.definitions.iter().position(|tool| tool.name == call.name) else {
            return ToolResult::error(&call.call_id, format!("Unknown tool: {}", call.name));
        };

        match self.handlers[index].call(&call.arguments, cancellation_token).await {
            Ok(content) => ToolResult::success(&call.call_id, content),
            Err(content) => ToolResult::error(&call.call_id, content),
        }
    }
}
