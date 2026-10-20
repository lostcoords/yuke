//! Test fixtures that the tests of several yuke crates share: a test model, scripted provider answers as Anthropic SSE,
//! a scripted transport, a timer that never waits, and a new folder for each test. A fixture that one crate alone uses
//! stays in that crate.
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::missing_panics_doc,
    reason = "a fixture fails its test by panicking"
)]

use std::collections::VecDeque;
use std::fmt::{Display, Write};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use serde_json::{Value, json};
use yuke_ai::route::{Credential, Route};
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Header, Outgoing, Transport};
use yuke_ai::{AnthropicWire, Target, Wire};
use yuke_engine::{Model, Timer};

/// An Anthropic target at a test host. Its route takes no credential.
pub fn target() -> Target {
    Target {
        model: "test-model".into(),
        route: Route {
            base_url: "https://example.test/v1".into(),
            ..Route::default()
        },
        wire: Wire::AnthropicMessages(AnthropicWire {
            max_tokens: 64,
            cache: false,
        }),
        tool_search: false,
    }
}

/// [`target`] with no credential.
pub fn model() -> Model {
    model_of(target())
}

/// `target` with no credential.
pub fn model_of(target: Target) -> Model {
    Model {
        target,
        source: Arc::new(Credential::None),
    }
}

/// A timer whose waits end at once.
#[derive(Debug)]
pub struct NoWait;

#[async_trait]
impl Timer for NoWait {
    async fn sleep(&self, _: Duration) {}
}

/// Assert that each of `texts` appears as a JSON string in `body`, in order.
#[track_caller]
pub fn assert_in_order(body: &str, texts: &[&str]) {
    let positions: Vec<Option<usize>> = texts
        .iter()
        .map(|text| body.find(&Value::from(*text).to_string()))
        .collect();
    assert!(positions.iter().all(Option::is_some), "{body}");
    assert!(positions.is_sorted(), "{body}");
}

/// `events` as one SSE body: each event is the data of one message.
pub fn sse<T: Display>(events: &[T]) -> String {
    let mut output = String::new();
    for event in events {
        write!(output, "data: {event}\n\n").unwrap();
    }
    output
}

fn message_start() -> Value {
    json!({"type": "message_start", "message": {"usage": {"input_tokens": 0}}})
}

fn text_start() -> Value {
    json!({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
}

fn text_delta(text: &str) -> Value {
    json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
}

fn overloaded() -> Value {
    json!({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
}

fn message_end(stop_reason: &str) -> [Value; 2] {
    [
        json!({"type": "message_delta", "delta": {"stop_reason": stop_reason}, "usage": {"output_tokens": 1}}),
        json!({"type": "message_stop"}),
    ]
}

/// One complete Anthropic text answer, as SSE.
pub fn text_reply(text: &str) -> String {
    let [delta, stop] = message_end("end_turn");
    sse(&[
        message_start(),
        text_start(),
        text_delta(text),
        json!({"type": "content_block_stop", "index": 0}),
        delta,
        stop,
    ])
}

/// An Anthropic answer that fails with an overload error before any output, as SSE. The default retry policy retries
/// it.
pub fn overloaded_reply() -> String {
    sse(&[message_start(), overloaded()])
}

/// An Anthropic answer that streams `text`, then fails with an overload error, as SSE. The output before the error
/// stops a retry, so the request fails at once.
pub fn failed_reply(text: &str) -> String {
    sse(&[message_start(), text_start(), text_delta(text), overloaded()])
}

/// One complete Anthropic answer that asks for `calls`, each an id, a name, and JSON arguments, as SSE.
pub fn tool_reply(calls: &[(&str, &str, &str)]) -> String {
    calls_reply(calls, "tool_use")
}

/// An answer like [`tool_reply`] that the output limit cut, as SSE.
pub fn cut_reply(calls: &[(&str, &str, &str)]) -> String {
    calls_reply(calls, "max_tokens")
}

fn calls_reply(calls: &[(&str, &str, &str)], stop_reason: &str) -> String {
    let mut events = vec![message_start()];
    for (index, (id, name, arguments)) in calls.iter().enumerate() {
        events.extend([
            json!({
                "type": "content_block_start",
                "index": index,
                "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}},
            }),
            json!({
                "type": "content_block_delta",
                "index": index,
                "delta": {"type": "input_json_delta", "partial_json": arguments},
            }),
            json!({"type": "content_block_stop", "index": index}),
        ]);
    }
    events.extend(message_end(stop_reason));
    sse(&events)
}

/// Answers each open with the next scripted reply, and records the URL, the body, and the headers of each request. A
/// clone shares the script and the records.
#[derive(Debug, Clone, Default)]
pub struct ScriptedTransport {
    script: Arc<Mutex<Script>>,
}

#[derive(Debug, Default)]
struct Script {
    replies: VecDeque<Reply>,
    urls: Vec<String>,
    requests: Vec<String>,
    headers: Vec<Vec<Header>>,
}

/// One scripted reply. A reply that stalls never ends after its body.
#[derive(Debug)]
struct Reply {
    body: Bytes,
    stalls: bool,
}

impl ScriptedTransport {
    /// A transport that answers with `replies`, in order.
    pub fn new(replies: impl IntoIterator<Item = String>) -> Self {
        let transport = ScriptedTransport::default();
        for reply in replies {
            transport.push(reply);
        }
        transport
    }

    /// Add `reply` to the end of the script.
    pub fn push(&self, reply: String) {
        self.add(reply, false);
    }

    /// Add a reply that sends `reply`, then waits forever, as a stream that the provider holds open.
    #[must_use]
    pub fn then_stall(self, reply: String) -> Self {
        self.add(reply, true);
        self
    }

    fn add(&self, reply: String, stalls: bool) {
        self.script.lock().unwrap().replies.push_back(Reply {
            body: Bytes::from(reply),
            stalls,
        });
    }

    /// The request URLs, in send order.
    pub fn urls(&self) -> Vec<String> {
        self.script.lock().unwrap().urls.clone()
    }

    /// The request bodies, in send order.
    pub fn requests(&self) -> Vec<String> {
        self.script.lock().unwrap().requests.clone()
    }

    /// The headers of each request, in send order.
    pub fn headers(&self) -> Vec<Vec<Header>> {
        self.script.lock().unwrap().headers.clone()
    }

    /// The value of the header `name` in each request, in send order.
    pub fn header(&self, name: &str) -> Vec<Option<String>> {
        self.headers()
            .iter()
            .map(|sent| {
                sent.iter()
                    .find(|header| header.name == name)
                    .map(|header| header.value.to_string())
            })
            .collect()
    }
}

impl Transport for ScriptedTransport {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        _: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let mut script = self.script.lock().unwrap();
        script.urls.push(request.url().to_owned());
        script
            .requests
            .push(String::from_utf8(request.body().flatten().copied().collect()).unwrap());
        script.headers.push(request.headers().to_vec());
        let reply = script.replies.pop_front().expect("the script has no reply left");
        let body: BoxBody = Box::pin(OneChunk {
            chunk: Some(reply.body),
            stalls: reply.stalls,
        });
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

/// A body of one chunk. A body that stalls never ends after its chunk.
struct OneChunk {
    chunk: Option<Bytes>,
    stalls: bool,
}

impl Body for OneChunk {
    fn poll_chunk(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        match self.chunk.take() {
            Some(chunk) => Poll::Ready(Some(Ok(chunk))),
            None if self.stalls => Poll::Pending,
            None => Poll::Ready(None),
        }
    }
}

/// A transport whose answer never ends, as a provider that holds its stream open. It is also the body of that answer.
#[derive(Debug)]
pub struct Stalled;

impl Transport for Stalled {
    fn open<'a>(&'a self, _: &'a Outgoing<'_>, _: Option<Instant>) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body: BoxBody = Box::pin(Stalled);
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

impl Body for Stalled {
    fn poll_chunk(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        Poll::Pending
    }
}

/// A new empty folder for the test `name` of the test group `group`, as a canonical path. The process id keeps two test
/// runs at once apart.
pub fn folder(group: &str, name: &str) -> std::path::PathBuf {
    let folder = std::env::temp_dir()
        .join(format!("yuke-{group}-tests-{}", std::process::id()))
        .join(name);
    match std::fs::remove_dir_all(&folder) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        result => result.unwrap(),
    }
    std::fs::create_dir_all(&folder).unwrap();
    // On macOS, the temporary folder is a symbolic link. A command reports the canonical path of its working folder.
    folder.canonicalize().unwrap()
}
