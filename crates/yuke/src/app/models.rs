//! The model requests of the plugins, through the catalog and the credentials of the sessions.

use std::borrow::Cow;
use std::collections::HashMap;
use std::error::Error;
use std::sync::Arc;

use async_trait::async_trait;
use yuke_agent::{Store, blob_of};
use yuke_ai::{BlobStore, Block, Digest, Media, Request};
use yuke_engine::{CancellationToken, Driver, Model};
use yuke_js::{CompleteAnswer, CompleteRequest, Models, SideRequest};
use yuke_protocol::SessionId;

use super::{Shared, TokioTimer, model_of};

/// The models of the app for the plugins. A request is one request to the model: no tool runs, no hook sees it, and
/// the store keeps nothing of it.
pub(super) struct PluginModels(pub(super) Arc<Shared>);

#[async_trait]
impl Models for PluginModels {
    // The request reads only the media of its attachments, so a media block of the session fails it.
    async fn complete(
        &self,
        request: CompleteRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
        let model = model_of(&request.model, &self.0)?;
        let mut blocks = request.blocks;
        let mut attachments = Attachments::default();
        for attachment in request.attachments {
            let blob = blob_of(&attachment.bytes);
            blocks.push(Block::Media(Media::new(blob, attachment.mime_type)));
            attachments.0.insert(blob.digest, attachment.bytes);
        }
        let request = Request::new(&blocks)
            .system(&request.system)
            .settings(&request.settings)
            .blobs(&attachments);
        send(&model, request, &self.0, &cancel).await
    }

    async fn side_request(
        &self,
        request: SideRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
        let SideRequest {
            model,
            system,
            tools,
            settings,
            session_id,
            mut blocks,
            prompt,
        } = request;
        // The marker stays on the blocks of the round, so the round after the request reads the same cache entry.
        let cached = blocks.len();
        blocks.push(Block::user_text(prompt));
        // A session turn sends the same key, so the provider routes both to the same cache.
        let key = session_id.to_string();
        let media = SessionMedia {
            store: &*self.0.store,
            session_id,
        };
        let request = Request::new(&blocks)
            .system(&system)
            .settings(&settings)
            .session_id(&key)
            .tools(&tools)
            .blobs(&media)
            .cached(cached);
        send(&model, request, &self.0, &cancel).await
    }
}

/// Send `request` to `model` through the transport of `shared`. Answer with the text, the finish, and the usage of the
/// answer.
async fn send(
    model: &Model,
    request: Request<'_>,
    shared: &Shared,
    cancel: &CancellationToken,
) -> Result<CompleteAnswer, Box<dyn Error + Send + Sync>> {
    let response = Driver::new(&*shared.machine.transport, model, &TokioTimer)
        .request(request, cancel)
        .await?
        .ok_or("the model request was cancelled")?;
    let completion = response.completion;
    Ok(CompleteAnswer {
        finish_reason: completion.finish_reason,
        usage: completion.usage,
        text: yuke_ai::answer_text(&completion.into_blocks().collect::<Vec<_>>()),
    })
}

/// The bytes of the attachments of one request, by digest.
#[derive(Default)]
struct Attachments(HashMap<Digest, Vec<u8>>);

impl BlobStore for Attachments {
    fn read(&self, digest: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn Error + Send + Sync>> {
        Ok(self.0.get(digest).map(|bytes| Cow::Borrowed(bytes.as_slice())))
    }
}

/// The media of one session in the store.
struct SessionMedia<'a> {
    store: &'a dyn Store,
    session_id: SessionId,
}

impl BlobStore for SessionMedia<'_> {
    fn read(&self, digest: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn Error + Send + Sync>> {
        Ok(self.store.read_blob(self.session_id, digest)?.map(Cow::Owned))
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use yuke_ai::transport::Transport;
    use yuke_ai::{FinishReason, ToolDefinition, Usage};
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
    async fn a_side_request_reads_the_media_of_its_session_and_offers_its_tools() {
        let transport = ScriptedTransport::new([text_reply("A cat.")]);
        let app = app(
            "a_side_request_reads_the_media_of_its_session_and_offers_its_tools",
            Box::new(transport.clone()),
        )
        .await;
        let reference = request("MiniMax-M3").model;
        let settings = yuke_protocol::SessionSettings {
            model: reference.clone(),
            settings: yuke_ai::Settings::new(),
            cwd: std::env::temp_dir(),
        };
        let session = app.shared.store.create_session(&settings, &[]).await.unwrap();
        let blob = app
            .shared
            .store
            .put_blob(session.id, b"png bytes".to_vec())
            .await
            .unwrap();
        let request = SideRequest {
            model: model_of(&reference, &app.shared).unwrap(),
            system: "Be brief.".to_owned(),
            tools: vec![ToolDefinition {
                name: "look".into(),
                description: "Look.".to_owned(),
                input_schema: r#"{"type":"object"}"#.to_owned(),
                defer_loading: false,
            }],
            settings: yuke_ai::Settings::new(),
            session_id: session.id,
            blocks: vec![Block::Media(Media::new(blob, "image/png".to_owned()))],
            prompt: "Describe.".to_owned(),
        };

        let answer = PluginModels(Arc::clone(&app.shared))
            .side_request(request, CancellationToken::new())
            .await;
        app.shutdown().await;

        assert_eq!(answer.unwrap().text, "A cat.");
        assert_in_order(
            &transport.requests()[0],
            &["Be brief.", "look", "cG5nIGJ5dGVz", "Describe."],
        );
    }

    // A turn of the session sends the same key and marker, so the provider serves both requests from one cache entry.
    #[tokio::test]
    async fn a_side_request_keeps_the_cache_key_and_the_cache_marker_of_its_round() {
        let reply =
            yuke_testing::sse(&[r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#]);
        let transport = ScriptedTransport::new([reply]);
        let app = app(
            "a_side_request_keeps_the_cache_key_and_the_cache_marker_of_its_round",
            Box::new(transport.clone()),
        )
        .await;
        let session_id = SessionId::generate();
        let target = yuke_ai::Target {
            wire: yuke_ai::Wire::OpenaiResponses(yuke_ai::ResponsesWire {
                cache: true,
                ..yuke_ai::ResponsesWire::default()
            }),
            ..yuke_testing::target()
        };
        let request = SideRequest {
            model: yuke_testing::model_of(target),
            system: String::new(),
            tools: Vec::new(),
            settings: yuke_ai::Settings::new(),
            session_id,
            blocks: vec![Block::user_text("one")],
            prompt: "Summarize.".to_owned(),
        };

        let answer = PluginModels(Arc::clone(&app.shared))
            .side_request(request, CancellationToken::new())
            .await;
        app.shutdown().await;

        answer.unwrap();
        let request = &transport.requests()[0];
        assert!(
            request.contains(&format!(r#""prompt_cache_key":"{session_id}""#)),
            "{request}"
        );
        assert!(
            request.contains(r#"{"type":"input_text","text":"one","prompt_cache_breakpoint":{"mode":"explicit"}},{"type":"input_text","text":"Summarize."}"#),
            "{request}"
        );
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
