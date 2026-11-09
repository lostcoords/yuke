//! Model calls over Anthropic Messages, OpenAI Chat Completions, and OpenAI Responses. [`generate`] returns one owned
//! [`Response`]. [`Encoder`] and [`Reply`] split the same call into steps that lend until the next call.

mod block;
pub mod catalog;
mod encoder;
mod failure;
#[cfg(feature = "http")]
mod http;
mod json;
pub mod oauth;
mod reply;
mod request;
mod response;
pub mod retry;
#[cfg(any(test, feature = "scripted"))]
pub mod scripted;
mod stream;
mod target;
pub mod transport;
mod wire;
mod wyhash;

#[cfg(test)]
mod testing;

pub use block::{
    Blob, BlobStore, Block, Digest, Media, Modality, Origin, OriginRef, Reasoning, ReasoningReplay, ReasoningReplayRef,
    ReplayKind, Role, ToolCall, ToolCallRef, ToolResult,
};
pub use encoder::{EncodeError, Encoded, Encoder, Unsupported};
pub use failure::{Failure, ProviderKind};
pub use reply::Reply;
pub use request::{
    Effort, OutputSchema, ReasoningSettings, Request, SEARCH_TOOL_NAME, Settings, Thinking, ThinkingDisplay,
    ToolChoice, ToolDefinition,
};
pub use response::{
    AttemptError, AttemptInfo, BlockId, BlockResult, BlockStarted, BlockStopped, Completion, Content, Delta, Done,
    Error, Event, FinishReason, Partial, PartialBlock, Response, ResponseLimits, StartedBlock, Usage,
};
pub use stream::ReplyOptions;
pub use target::{
    AnthropicWire, ChatDialect, ChatWire, Credential, CredentialHeader, Header, MaxTokensField, OAuth, Protocol,
    ReasoningReplayMode, ResponsesDialect, ResponsesWire, Route, SessionHeader, Target, ThinkingFormat, Wire,
    invalid_header,
};
use transport::Transport;

/// A text that names no value of a type, such as an unknown finish reason. `Display` quotes the text.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ParseError {
    expected: &'static str,
    text: String,
}

impl ParseError {
    /// The error for `text`, which is not `expected`, such as `a reasoning effort`.
    pub fn new(expected: &'static str, text: impl Into<String>) -> Self {
        ParseError {
            expected,
            text: text.into(),
        }
    }
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "`{}` is not {}", self.text, self.expected)
    }
}

impl std::error::Error for ParseError {}

/// Parse `text` as the serde name of a unit variant of `T`, so the derive keeps the one table of names.
fn parse_name<'de, T: serde::Deserialize<'de>>(text: &'de str, expected: &'static str) -> Result<T, ParseError> {
    use serde::de::IntoDeserializer;

    T::deserialize(IntoDeserializer::<serde::de::value::Error>::into_deserializer(text))
        .map_err(|_| ParseError::new(expected, text))
}

/// Encode one request for `target` with `credential`, open it with `options`, and read the reply to its end. No
/// automatic retries and no tool execution.
///
/// # Errors
///
/// Returns [`Error::Encode`] if the request cannot be encoded, and [`Error::Attempt`] if the attempt failed.
pub async fn generate(
    transport: &dyn Transport,
    target: &Target,
    credential: &Credential,
    request: Request<'_>,
    options: ReplyOptions,
) -> Result<Response, Error> {
    let mut encoder = Encoder::new();
    let encoded = encoder.encode(target, credential, request)?;
    Ok(Reply::open(transport, &encoded, options).await.finish().await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scripted::sse;
    use crate::testing::{CannedTransport, block_on, generate_text, target};

    #[test]
    fn openrouter_reasoning_details_round_trip() {
        let reply = sse(&[
            r#"{"choices":[{"index":0,"delta":{"reasoning":"Plan","reasoning_details":[{"type":"reasoning.text","text":"Plan","signature":"s"}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
        ]) + "data: [DONE]\n\n";
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
        let encoded = encoder
            .encode(&target, &Credential::None, Request::new(&blocks))
            .unwrap();
        let body = String::from_utf8(encoded.http.body().iter().flatten().copied().collect::<Vec<u8>>()).unwrap();
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
            digest: Digest([0; 32]),
            source: store_error,
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

    // A shared transport meets the bound of a transport, and each request reaches the transport inside it.
    #[test]
    fn a_shared_transport_sends_through_the_transport_inside_it() {
        let scripted = scripted::ScriptedTransport::new([testing::canned_reply()]);
        let shared: std::sync::Arc<dyn Transport> = std::sync::Arc::new(scripted.clone());
        let blocks = [Block::user_text("hello")];

        let response = block_on(generate(
            &shared,
            &target(Protocol::AnthropicMessages),
            &Credential::None,
            Request::new(&blocks),
            ReplyOptions::default(),
        ))
        .unwrap();

        assert_eq!(response.completion.text(), "Hello from the mock provider.");
        assert_eq!(scripted.urls(), ["https://example.test/v1/messages"]);
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
        let encoded = encoder.encode(&target, &Credential::None, request).unwrap();
        let open = Reply::open(&canned, &encoded, ReplyOptions::default());
        send(&open);
        let mut reply = block_on(open);
        send(&reply.next());
        let finish = reply.finish();
        send(&finish);
        send(&block_on(finish));
        send(&generate(
            &canned,
            &target,
            &Credential::None,
            request,
            ReplyOptions::default(),
        ));
    }
}
