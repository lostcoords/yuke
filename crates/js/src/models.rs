//! The model requests of the plugins.

use std::error::Error;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Map, Value};
use tokio::runtime::Handle;
use yuke_ai::{Block, FinishReason, Settings, Usage};
use yuke_engine::CancellationToken;
use yuke_protocol::ModelReference;

/// One request of a plugin to a model.
#[derive(Debug, Clone, PartialEq)]
pub struct CompleteRequest {
    /// The model of the request, from the catalog of the consumer.
    pub model: ModelReference,
    /// The system prompt. An empty prompt sends no system prompt.
    pub system: String,
    /// The input of the request, oldest first.
    pub blocks: Vec<Block>,
    /// The settings of the request.
    pub settings: Settings,
}

/// The answer of a [`CompleteRequest`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompleteAnswer {
    /// The text blocks of the answer, one per line.
    pub text: String,
    /// The reason that the answer stopped.
    pub finish_reason: FinishReason,
    /// The input, output, reasoning, and cache token counts of the request.
    pub usage: Usage,
}

/// The models that the plugins call. The consumer gives one value to each runtime.
#[async_trait]
pub trait Models: Send + Sync {
    /// Send `request`, and wait for the first answer. The token `cancel` stops the request.
    ///
    /// # Errors
    ///
    /// Returns why the request failed. A cancel also fails the request.
    async fn complete(
        &self,
        request: CompleteRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>>;
}

/// The models of the consumer on its own tokio runtime. The JavaScript thread has no I/O driver, so each request runs
/// there.
pub(crate) struct OnConsumer {
    pub(crate) models: Arc<dyn Models>,
    pub(crate) handle: Handle,
}

#[async_trait]
impl Models for OnConsumer {
    async fn complete(
        &self,
        request: CompleteRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
        // A drop of the wait, as at a shutdown, cancels the token too.
        let guard = cancel.clone().drop_guard();
        let models = Arc::clone(&self.models);
        let answer = self
            .handle
            .spawn(async move { models.complete(request, cancel).await })
            .await;
        guard.disarm();
        answer?
    }
}

/// `base` with the fields of `changes`, a part of the JSON of [`Settings`]. A field replaces the whole value of `base`.
///
/// # Errors
///
/// Returns a text when `changes` has an unknown field, or a value of another shape.
pub(crate) fn merge_settings(base: &Settings, changes: Map<String, Value>) -> Result<Settings, String> {
    let mut settings = serde_json::to_value(base).map_err(|error| error.to_string())?;
    if let Some(fields) = settings.as_object_mut() {
        // serde skips an unknown field, so a misspelt setting would change nothing without this check.
        if let Some(unknown) = changes.keys().find(|key| !fields.contains_key(*key)) {
            return Err(format!("the settings have the unknown field '{unknown}'"));
        }
        fields.extend(changes);
    }
    serde_json::from_value(settings).map_err(|error| format!("the settings are not valid: {error}"))
}
