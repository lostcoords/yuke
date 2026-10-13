//! Model calls over Anthropic Messages, OpenAI Chat Completions, and OpenAI Responses. [`generate`] returns one owned
//! [`Response`]. [`Encoder`] and [`Reply`] split the same call into steps that lend until the next call.

pub mod catalog;
mod encoder;
mod failure;
#[cfg(feature = "http-tokio")]
mod http;
mod json;
mod reply;
mod request;
mod response;
pub mod retry;
pub mod route;
mod stream;
pub mod transport;
mod wire;
mod wyhash;

#[cfg(test)]
mod testing;

pub use encoder::{EncodeError, Encoded, Encoder};
pub use failure::{Failure, ProviderKind, detail_text};
#[cfg(feature = "http-tokio")]
pub use http::{HttpOptions, HttpTransport, InvalidUserAgent};
pub use reply::Reply;
pub use request::{
    AnthropicWire, Blob, BlobStore, Block, ChatDialect, ChatWire, Digest, Effort, MaxTokensField, Media, Modality,
    Origin, OriginRef, OutputSchema, Protocol, Reasoning, ReasoningReplay, ReasoningReplayMode, ReasoningReplayRef,
    ReasoningSettings, ReplayKind, Request, ResponsesDialect, ResponsesWire, Role, SEARCH_TOOL_NAME, Settings, Target,
    Thinking, ThinkingDisplay, ThinkingFormat, ToolCall, ToolCallRef, ToolChoice, ToolDefinition, ToolResult, Wire,
};
pub use response::{
    AttemptError, AttemptInfo, BlockId, BlockKind, BlockResult, BlockStarted, BlockStopped, Completion, Content, Delta,
    Done, Error, Event, FinishReason, Partial, Response, ResponseLimits, Usage,
};
pub use stream::Options;
use transport::Transport;

/// Encode one request, open it with `options`, and read the reply to its end. No automatic retries and no tool
/// execution.
///
/// # Errors
///
/// Returns [`Error::Encode`] if the request cannot be encoded, and [`Error::Attempt`] if the attempt failed.
pub async fn generate(
    transport: &dyn Transport,
    target: &Target,
    request: Request<'_>,
    options: Options,
) -> Result<Response, Error> {
    let mut encoder = Encoder::new();
    let encoded = encoder.encode(target, request)?;
    Ok(Reply::open(transport, &encoded, options).await.finish().await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{CannedTransport, block_on, frame, generate_text, target};

    #[test]
    fn openrouter_reasoning_details_round_trip() {
        let reply = [
            r#"{"choices":[{"index":0,"delta":{"reasoning":"Plan","reasoning_details":[{"type":"reasoning.text","text":"Plan","signature":"s"}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
        ]
        .map(frame)
        .concat()
            + "data: [DONE]\n\n";
        let mut target = target(Protocol::OpenaiChat);
        target.wire = Wire::OpenaiChat(ChatWire {
            reasoning_replay: ReasoningReplayMode::ReasoningDetails,
            ..ChatWire::default()
        });
        let canned = CannedTransport::new(reply);
        let first = generate_text(&canned, &target, "go");
        let completion = first.unwrap().completion;
        assert_eq!(completion.content.len(), 2);

        let mut blocks = vec![Block::user_text("go")];
        blocks.extend(completion.into_blocks());
        blocks.push(Block::ToolResult(ToolResult::success("c1", "ok")));
        let mut encoder = Encoder::new();
        let encoded = encoder.encode(&target, Request::new(&blocks)).unwrap();
        let body = String::from_utf8(encoded.http.body().flatten().copied().collect::<Vec<u8>>()).unwrap();
        let body: serde_json::Value = serde_json::from_str(&body).unwrap();
        let assistant = body["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|message| {
                message["role"] == "assistant"
                    && message["tool_calls"]
                        .as_array()
                        .is_some_and(|calls| calls.iter().any(|call| call["id"] == "c1"))
            })
            .unwrap();
        assert_eq!(
            assistant["reasoning_details"],
            serde_json::json!([
                {"type":"reasoning.text","text":"Plan","signature":"s"}
            ])
        );
    }

    /// The text of `error` and of each of its sources, in order.
    fn chain(error: &dyn std::error::Error) -> Vec<String> {
        std::iter::successors(Some(error), |error| error.source())
            .map(ToString::to_string)
            .collect()
    }

    // An error that shows the text of the error it wraps returns the source of that error, so a printer of the chain
    // shows each text once. A caller reaches the store error of a failed blob read with one `source` call.
    #[test]
    fn each_text_of_an_error_chain_appears_once() {
        let attempt = |cause| {
            Error::Attempt(AttemptError {
                cause,
                info: AttemptInfo::default(),
                partial: Vec::new(),
            })
        };
        let store_error: Box<dyn std::error::Error + Send + Sync> = "the store is locked".into();
        let blob_read = Error::from(EncodeError::BlobRead {
            digest: [0; 32],
            source: store_error.into(),
        });

        assert_eq!(
            chain(&attempt(Failure::Provider(ProviderKind::AuthFailed))),
            ["the provider rejected the credential"]
        );
        assert_eq!(
            chain(&attempt(Failure::Transport(transport::Fault::TlsSetupFailed))),
            ["the client could not build its TLS configuration"]
        );
        assert_eq!(
            chain(&blob_read),
            [
                format!("the blob store failed to read the attachment blob {}", "00".repeat(32)),
                "the store is locked".to_owned(),
            ]
        );
    }

    #[test]
    fn session_types_and_futures_are_send() {
        fn send<T: Send>(_: &T) {}
        let canned = CannedTransport::new(testing::canned_reply());
        let target = target(Protocol::AnthropicMessages);
        let blocks = [Block::user_text("hello")];
        let request = Request::new(&blocks);
        let mut encoder = Encoder::new();
        send(&encoder);
        let encoded = encoder.encode(&target, request).unwrap();
        let open = Reply::open(&canned, &encoded, Options::default());
        send(&open);
        let mut reply = block_on(open);
        send(&reply.next());
        let finish = reply.finish();
        send(&finish);
        send(&block_on(finish));
        send(&generate(&canned, &target, request, Options::default()));
    }
}
