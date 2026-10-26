//! The model requests of the plugins.

use std::error::Error;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Map, Value};
use tokio::runtime::Handle;
use yuke_ai::{Block, FinishReason, Settings, ToolDefinition, Usage};
use yuke_engine::{CancellationToken, Model};
use yuke_protocol::{ModelReference, SessionId};

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
    /// The media that follow `blocks` in the input, in order.
    pub attachments: Vec<Attachment>,
}

/// One media item of a [`CompleteRequest`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    /// The bytes of the media.
    pub bytes: Vec<u8>,
    /// The media type, for example `image/png`.
    pub mime_type: String,
}

/// One request of a round hook: the request of the round, with other blocks, then a prompt. It repeats the bytes and the
/// cache marker of the round, so it can reuse the prompt cache of the earlier rounds.
#[derive(Debug, Clone)]
pub struct SideRequest {
    /// The model of the round.
    pub model: Model,
    /// The system prompt of the round.
    pub system: String,
    /// The tool definitions of the round. The request offers them, and no tool runs.
    pub tools: Vec<ToolDefinition>,
    /// The settings of the round, with the output limit of the caller.
    pub settings: Settings,
    /// The session of the round. Its media store serves the media blocks, and its id is the cache key.
    pub session_id: SessionId,
    /// The blocks of the round, oldest first. The cache marker goes on them, as in the round.
    pub blocks: Vec<Block>,
    /// The text of the user block after `blocks`.
    pub prompt: String,
}

/// The answer of a [`CompleteRequest`] or a [`SideRequest`].
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

    /// Send `request`, and wait for the first answer. The token `cancel` stops the request.
    ///
    /// # Errors
    ///
    /// Returns why the request failed. A cancel also fails the request.
    async fn side_request(
        &self,
        request: SideRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>>;
}

/// The models of the consumer on the tokio runtime of the consumer. A request runs there, and the drop of its wait
/// cancels it.
pub(crate) struct OnConsumer {
    pub(crate) models: Arc<dyn Models>,
    pub(crate) handle: Handle,
}

impl OnConsumer {
    /// Run the request that `send` makes on the runtime of the consumer.
    async fn run<F>(
        &self,
        cancel: CancellationToken,
        send: impl FnOnce(CancellationToken) -> F + Send + 'static,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>>
    where
        F: Future<Output = Result<CompleteAnswer, Box<dyn Error + Send + Sync>>> + Send + 'static,
    {
        // A drop of the wait, as at a shutdown, cancels the token too.
        let guard = cancel.clone().drop_guard();
        let answer = self.handle.spawn(send(cancel)).await;
        guard.disarm();
        answer?
    }
}

#[async_trait]
impl Models for OnConsumer {
    async fn complete(
        &self,
        request: CompleteRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
        let models = Arc::clone(&self.models);
        self.run(cancel, async move |cancel| models.complete(request, cancel).await)
            .await
    }

    async fn side_request(
        &self,
        request: SideRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
        let models = Arc::clone(&self.models);
        self.run(cancel, async move |cancel| models.side_request(request, cancel).await)
            .await
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
