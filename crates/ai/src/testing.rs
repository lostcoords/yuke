//! Canned transports and SSE fixtures for the tests of this crate.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll, Waker};
use std::time::Instant;

use bytes::Bytes;

use crate::request::{AnthropicWire, ChatWire, Protocol, ResponsesWire, Target, Wire};
use crate::response::{AttemptError, Completion, Error, Response};
use crate::route::{Credential, Route};
use crate::stream::Options;
use crate::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};
use crate::{Block, Request, generate};

/// Assert that two values print the same `Debug` text. An error with a boxed source has no `PartialEq`. Use it only
/// for a value whose `Debug` is derived and holds no boxed source, so the text shows every field.
#[track_caller]
pub(crate) fn assert_same<T: std::fmt::Debug>(actual: T, expected: T) {
    assert_eq!(format!("{actual:?}"), format!("{expected:?}"));
}

/// Run a future that never waits, as every canned exchange is.
pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    let mut future = std::pin::pin!(future);
    match future.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(output) => output,
        Poll::Pending => panic!("a canned exchange never waits"),
    }
}

/// A target for `protocol` at a test host, with no credential.
pub(crate) fn target(protocol: Protocol) -> Target {
    Target {
        model: "test-model".into(),
        route: Route {
            base_url: "https://example.test/v1".into(),
            ..Route::default()
        },
        wire: match protocol {
            Protocol::AnthropicMessages => Wire::AnthropicMessages(AnthropicWire {
                max_tokens: 64,
                cache: false,
            }),
            Protocol::OpenaiChat => Wire::OpenaiChat(ChatWire::default()),
            Protocol::OpenaiResponses => Wire::OpenaiResponses(ResponsesWire::default()),
        },
        tool_search: false,
    }
}

/// An Anthropic overload answer, as an HTTP body or as one stream event.
pub(crate) const OVERLOAD_EVENT: &str =
    r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#;

/// One SSE frame of `json`.
pub(crate) fn frame(json: &str) -> String {
    format!("data: {json}\n\n")
}

/// One complete Anthropic text response.
pub(crate) fn canned_reply() -> String {
    [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from the mock provider."}}"#,
        r#"{"type":"content_block_stop","index":0}"#,
        r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}"#,
        r#"{"type":"message_stop"}"#,
    ]
    .map(frame)
    .concat()
}

/// Generate from one user text block, as most call tests do.
pub(crate) fn generate_text(
    transport: &dyn Transport,
    target: &Target,
    prompt: &str,
) -> Result<Response, AttemptError> {
    generate_with(transport, target, prompt, Options::default())
}

pub(crate) fn generate_with(
    transport: &dyn Transport,
    target: &Target,
    prompt: &str,
    options: Options,
) -> Result<Response, AttemptError> {
    let blocks = [Block::user_text(prompt)];
    match block_on(generate(
        transport,
        target,
        &Credential::None,
        Request::new(&blocks),
        options,
    )) {
        Ok(response) => Ok(response),
        Err(Error::Attempt(error)) => Err(error),
        Err(error) => panic!("the request does not encode: {error}"),
    }
}

#[derive(Debug, Default)]
struct Counters {
    opens: AtomicUsize,
    closes: AtomicUsize,
}

/// Replay one fixed reply for every open, and count opens and closes.
#[derive(Debug)]
pub(crate) struct CannedTransport {
    bytes: Bytes,
    status: u16,
    request_id: Option<String>,
    /// The most bytes one body read hands over.
    chunk_size: usize,
    /// The open fails with this cause, so the attempt reads no head.
    open_error: Option<Fault>,
    /// Every body read fails with this cause.
    read_error: Option<Fault>,
    /// The first poll for each chunk waits, so a test can cancel a read at every await.
    wait_first: bool,
    counters: Arc<Counters>,
}

impl CannedTransport {
    pub(crate) fn new(bytes: impl Into<Bytes>) -> Self {
        CannedTransport {
            bytes: bytes.into(),
            status: 200,
            request_id: None,
            chunk_size: 4096,
            open_error: None,
            read_error: None,
            wait_first: false,
            counters: Arc::default(),
        }
    }

    pub(crate) fn status(self, status: u16) -> Self {
        CannedTransport { status, ..self }
    }

    pub(crate) fn request_id(self, id: &str) -> Self {
        CannedTransport {
            request_id: Some(id.to_owned()),
            ..self
        }
    }

    pub(crate) fn chunk_size(self, chunk_size: usize) -> Self {
        CannedTransport { chunk_size, ..self }
    }

    pub(crate) fn open_error(self, fault: Fault) -> Self {
        CannedTransport {
            open_error: Some(fault),
            ..self
        }
    }

    pub(crate) fn read_error(self, fault: Fault) -> Self {
        CannedTransport {
            read_error: Some(fault),
            ..self
        }
    }

    pub(crate) fn wait_first(self) -> Self {
        CannedTransport {
            wait_first: true,
            ..self
        }
    }

    pub(crate) fn opens(&self) -> usize {
        self.counters.opens.load(Ordering::Relaxed)
    }

    pub(crate) fn closes(&self) -> usize {
        self.counters.closes.load(Ordering::Relaxed)
    }
}

impl Transport for CannedTransport {
    fn open<'a>(&'a self, _: &'a Outgoing<'_>, _: Option<Instant>) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        self.counters.opens.fetch_add(1, Ordering::Relaxed);
        let result = if let Some(fault) = self.open_error {
            Err(fault)
        } else {
            let head = Head {
                request_id: self.request_id.clone(),
                ..Head::new(self.status)
            };
            let body: BoxBody = Box::pin(CannedBody {
                bytes: self.bytes.clone(),
                chunk_size: self.chunk_size,
                read_error: self.read_error,
                wait_first: self.wait_first,
                waited: false,
                counters: Arc::clone(&self.counters),
            });
            Ok((head, body))
        };
        Box::pin(std::future::ready(result))
    }
}

/// One response body of a [`CannedTransport`]. Each open has its own read offset.
struct CannedBody {
    bytes: Bytes,
    chunk_size: usize,
    read_error: Option<Fault>,
    wait_first: bool,
    /// The last poll waited, so the next one answers.
    waited: bool,
    counters: Arc<Counters>,
}

impl Body for CannedBody {
    fn poll_chunk(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        if self.wait_first && !std::mem::replace(&mut self.waited, true) {
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        self.waited = false;
        // A connection that breaks ends the body after the bytes it carried.
        if self.bytes.is_empty() {
            return Poll::Ready(self.read_error.map(Err));
        }
        let take = self.chunk_size.min(self.bytes.len());
        Poll::Ready(Some(Ok(self.bytes.split_to(take))))
    }
}

impl Drop for CannedBody {
    fn drop(&mut self) {
        self.counters.closes.fetch_add(1, Ordering::Relaxed);
    }
}

/// The completion of a successful attempt. Panic if the attempt failed.
pub(crate) fn completion(response: &Result<Response, AttemptError>) -> &Completion {
    match response {
        Ok(response) => &response.completion,
        Err(error) => panic!("the attempt failed: {error:?}"),
    }
}
