//! The model requests of the plugins, through the catalog and the credentials of the sessions.

use std::borrow::Cow;
use std::collections::HashMap;
use std::error::Error;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_agent::blob_of;
use yuke_ai::{BlobStore, Block, Digest, FinishReason, Media};
use yuke_engine::{Answer, CancellationToken, Commit, Driver, Hooks, Journal, Outcome, RoundDecision};
use yuke_js::{CompleteAnswer, CompleteRequest, Models};

use super::{Shared, TokioTimer, lock, model_of};

/// The models of the app for the plugins. A request is one round with no tools and no plugin hooks, and the store keeps
/// nothing of it. The round reads only the media of its attachments, so a media block of the session fails it.
pub(super) struct PluginModels(pub(super) Arc<Shared>);

#[async_trait]
impl Models for PluginModels {
    async fn complete(
        &self,
        request: CompleteRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
        let model = model_of(&request.model, &self.0)?;
        let first = FirstAnswer::default();
        let mut input = request.blocks;
        let mut attachments = Attachments::default();
        for attachment in request.attachments {
            let blob = blob_of(&attachment.bytes);
            input.push(Block::Media(Media::new(blob, attachment.mime_type)));
            attachments.0.insert(blob.digest, attachment.bytes);
        }
        let driver = Driver::new(&*self.0.machine.transport, &model, &TokioTimer)
            .system(&request.system)
            .settings(&request.settings)
            .hooks(&first)
            .journal(&first)
            .blobs(&attachments);
        let mut context = Vec::new();
        let outcome = driver
            .turn(&mut context, input)
            .cancellation_token(cancel)
            .run()
            .await?;
        if outcome == Outcome::Cancelled {
            return Err("the model request was cancelled".into());
        }
        let answer = lock(&first.answer).take().ok_or("the model sent no answer")?;
        Ok(CompleteAnswer {
            text: yuke_ai::answer_text(&context),
            finish_reason: answer.finish_reason,
            usage: answer.usage,
        })
    }
}

/// The bytes of the attachments of one request, by digest.
#[derive(Default)]
struct Attachments(HashMap<Digest, Vec<u8>>);

impl BlobStore for Attachments {
    fn read(&self, digest: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn Error + Send + Sync>> {
        Ok(self.0.get(digest).map(|bytes| Cow::Borrowed(bytes.as_slice())))
    }
}

/// Ends a turn after its first answer, and keeps that answer.
#[derive(Default)]
struct FirstAnswer {
    answer: Mutex<Option<Answer>>,
}

// The request offers no tools, but a model can still ask for a call. The stop keeps the turn at one request.
#[async_trait]
impl Hooks for FirstAnswer {
    async fn after_round(
        &self,
        _context: &[Block],
        _finish_reason: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn Error + Send + Sync>> {
        Ok(RoundDecision::Stop)
    }
}

#[async_trait]
impl Journal for FirstAnswer {
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn Error + Send + Sync>> {
        if let Some(answer) = &commit.answer {
            *lock(&self.answer) = Some(answer.clone());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use yuke_ai::Usage;
    use yuke_ai::transport::Transport;
    use yuke_js::Attachment;
    use yuke_protocol::{ModelReference, ServerNotification};
    use yuke_testing::{ScriptedTransport, assert_in_order, counted, text_reply, tool_reply};

    use super::*;
    use crate::app::{App, Mode, Observer};
    use crate::testing::{Place, with_key};

    /// Drops each notification.
    struct Silent;

    impl Observer for Silent {
        fn notify(&self, _notification: ServerNotification) {}
    }

    /// An app of the test `name` that sends the requests of the model through `transport`.
    async fn app(name: &str, transport: Box<dyn Transport>) -> App {
        let place = Place::new("models", name);
        App::start(
            place.machine(Box::new(with_key), transport),
            Mode::Print,
            Arc::new(Silent),
        )
        .await
        .unwrap()
    }

    /// A request to the MiniMax model `model` for a summary of at most 77 tokens.
    fn request(model: &str) -> CompleteRequest {
        CompleteRequest {
            model: ModelReference {
                provider: "minimax".to_owned(),
                model: model.to_owned(),
            },
            system: "Summarize the text.".to_owned(),
            blocks: vec![Block::user_text("the text to summarize")],
            settings: yuke_ai::Settings {
                max_output_tokens: Some(77),
                ..yuke_ai::Settings::new()
            },
            attachments: Vec::new(),
        }
    }

    #[tokio::test]
    async fn a_request_sends_its_prompt_and_settings_without_tools_and_answers_with_the_text_the_finish_and_the_usage()
    {
        let transport = ScriptedTransport::new([counted(&text_reply("A summary."), 42)]);
        let app = app(
            "a_request_sends_its_prompt_and_settings_without_tools_and_answers_with_the_text_the_finish_and_the_usage",
            Box::new(transport.clone()),
        )
        .await;

        let answer = PluginModels(Arc::clone(&app.shared))
            .complete(request("MiniMax-M3"), CancellationToken::new())
            .await;
        app.shutdown().await;

        assert_eq!(
            answer.unwrap(),
            CompleteAnswer {
                text: "A summary.".to_owned(),
                finish_reason: FinishReason::Stop,
                usage: Usage {
                    input: Some(42),
                    output: Some(1),
                    ..Usage::default()
                },
            }
        );
        let requests = transport.requests();
        assert_eq!(requests.len(), 1);
        assert_in_order(&requests[0], &["Summarize the text.", "the text to summarize"]);
        assert!(requests[0].contains(r#""max_tokens":77"#), "{}", requests[0]);
        assert!(!requests[0].contains(r#""tools""#), "{}", requests[0]);
    }

    #[tokio::test]
    async fn an_attachment_reaches_the_provider_after_the_prompt() {
        let transport = ScriptedTransport::new([text_reply("A cat.")]);
        let app = app(
            "an_attachment_reaches_the_provider_after_the_prompt",
            Box::new(transport.clone()),
        )
        .await;
        let request = CompleteRequest {
            attachments: vec![Attachment {
                bytes: b"png bytes".to_vec(),
                mime_type: "image/png".to_owned(),
            }],
            ..request("MiniMax-M3")
        };

        let answer = PluginModels(Arc::clone(&app.shared))
            .complete(request, CancellationToken::new())
            .await;
        app.shutdown().await;

        assert_eq!(answer.unwrap().text, "A cat.");
        // The provider gets the bytes as base64, after the text of the prompt.
        assert_in_order(
            &transport.requests()[0],
            &["the text to summarize", "image/png", "cG5nIGJ5dGVz"],
        );
    }

    #[tokio::test]
    async fn a_call_in_the_answer_ends_the_request_without_a_second_request() {
        let transport = ScriptedTransport::new([tool_reply(&[("c1", "read", "{}")]), text_reply("never sent")]);
        let app = app(
            "a_call_in_the_answer_ends_the_request_without_a_second_request",
            Box::new(transport.clone()),
        )
        .await;

        let answer = PluginModels(Arc::clone(&app.shared))
            .complete(request("MiniMax-M3"), CancellationToken::new())
            .await
            .unwrap();
        app.shutdown().await;

        assert_eq!(
            (answer.text.as_str(), answer.finish_reason),
            ("", FinishReason::ToolCalls)
        );
        assert_eq!(transport.requests().len(), 1);
    }

    #[tokio::test]
    async fn a_cancel_ends_a_request_that_waits_for_the_model() {
        let transport = ScriptedTransport::default().then_stall(String::new());
        let app = app(
            "a_cancel_ends_a_request_that_waits_for_the_model",
            Box::new(transport.clone()),
        )
        .await;
        let cancel = CancellationToken::new();
        let models = PluginModels(Arc::clone(&app.shared));
        let complete = models.complete(request("MiniMax-M3"), cancel.clone());
        // The cancel comes after the request starts, so it ends the wait for the model.
        let canceller = async {
            while transport.requests().is_empty() {
                tokio::task::yield_now().await;
            }
            cancel.cancel();
        };

        let (answer, ()) = tokio::time::timeout(Duration::from_secs(5), async { tokio::join!(complete, canceller) })
            .await
            .unwrap();
        drop(models);
        app.shutdown().await;

        assert_eq!(answer.unwrap_err().to_string(), "the model request was cancelled");
        assert_eq!(transport.requests().len(), 1);
    }

    #[tokio::test]
    async fn a_model_that_the_catalog_lacks_fails_before_any_request() {
        let transport = ScriptedTransport::default();
        let app = app(
            "a_model_that_the_catalog_lacks_fails_before_any_request",
            Box::new(transport.clone()),
        )
        .await;

        let answer = PluginModels(Arc::clone(&app.shared))
            .complete(request("no-such-model"), CancellationToken::new())
            .await;
        app.shutdown().await;

        let error = answer.unwrap_err().to_string();
        assert!(error.starts_with("minimax/no-such-model: "), "{error}");
        assert_eq!(transport.requests(), Vec::<String>::new());
    }
}
