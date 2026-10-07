//! Client tools. A [`Toolset`] keeps each definition beside its handler. A call runs the handler of its name.

use ai::{ToolCall, ToolResult};
use async_trait::async_trait;

/// A tool that the model can call.
#[async_trait]
pub trait Tool: Send + Sync {
    /// Run one call with its JSON `arguments`. `Err` reaches the model as an error result, and the turn continues.
    async fn call(&self, arguments: &str) -> Result<String, String>;
}

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

    /// Offer `definition` to the model. A call of its name runs `tool`.
    pub fn add(&mut self, definition: ai::ToolDefinition, tool: impl Tool + 'static) {
        self.definitions.push(definition);
        self.handlers.push(Box::new(tool));
    }

    /// The definitions, in the order of [`Toolset::add`].
    pub(crate) fn definitions(&self) -> &[ai::ToolDefinition] {
        &self.definitions
    }

    /// Run `call`, and return its result.
    pub(crate) async fn call(&self, call: &ToolCall) -> ToolResult {
        let Some(index) = self.definitions.iter().position(|tool| tool.name == call.name) else {
            return ToolResult::error(&call.call_id, format!("Unknown tool: {}", call.name));
        };

        match self.handlers[index].call(&call.arguments).await {
            Ok(content) => ToolResult::success(&call.call_id, content),
            Err(content) => ToolResult::error(&call.call_id, content),
        }
    }
}
