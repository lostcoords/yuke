//! Test support for whole runs: a scripted provider and its replies.

use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};

/// One complete Anthropic text answer, as SSE.
pub(crate) fn text_reply(text: &str) -> String {
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.to_owned(),
        format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ])
}

/// One complete Anthropic answer that calls `name` with the JSON `arguments`, as SSE.
pub(crate) fn tool_reply(id: &str, name: &str, arguments: &str) -> String {
    let partial = serde_json::Value::String(arguments.to_owned()).to_string();
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        format!(
            r#"{{"type":"content_block_start","index":0,"content_block":{{"type":"tool_use","id":"{id}","name":"{name}","input":{{}}}}}}"#
        ),
        format!(
            r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"input_json_delta","partial_json":{partial}}}}}"#
        ),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ])
}

pub(crate) fn sse(events: &[String]) -> String {
    events.iter().map(|json| ["data: ", json, "\n\n"].concat()).collect()
}

/// Answers each request with the next scripted reply, and keeps each request body. A clone shares the script.
#[derive(Clone)]
pub(crate) struct ScriptedTransport {
    replies: Arc<Mutex<VecDeque<String>>>,
    requests: Arc<Mutex<Vec<String>>>,
}

impl ScriptedTransport {
    pub(crate) fn new(replies: &[String]) -> Self {
        ScriptedTransport {
            replies: Arc::new(Mutex::new(replies.iter().cloned().collect())),
            requests: Arc::default(),
        }
    }

    pub(crate) fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }

    /// Add `reply` to the end of the script.
    pub(crate) fn push(&self, reply: String) {
        self.replies.lock().unwrap().push_back(reply);
    }
}

impl Transport for ScriptedTransport {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        _: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body = String::from_utf8(request.body().flatten().copied().collect()).unwrap();
        self.requests.lock().unwrap().push(body);
        let reply = self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .expect("the script has no reply left");
        let body: BoxBody = Box::pin(OneChunk(Some(Bytes::from(reply))));
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

/// Answers each request with a 401: the provider rejects the credential.
pub(crate) struct Rejecting;

impl Transport for Rejecting {
    fn open<'a>(&'a self, _: &'a Outgoing<'_>, _: Option<Instant>) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body: BoxBody = Box::pin(OneChunk(Some(Bytes::from_static(b"{}"))));
        Box::pin(std::future::ready(Ok((Head::new(401), body))))
    }
}

/// Panics at its first request, as a provider path with a bug, and then answers as its script.
pub(crate) struct PanicsOnce {
    panicked: AtomicBool,
    script: ScriptedTransport,
}

impl PanicsOnce {
    pub(crate) fn new(replies: &[String]) -> Self {
        PanicsOnce {
            panicked: AtomicBool::new(false),
            script: ScriptedTransport::new(replies),
        }
    }
}

impl Transport for PanicsOnce {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        assert!(
            self.panicked.swap(true, Ordering::SeqCst),
            "the first request panics on purpose"
        );
        self.script.open(request, deadline)
    }
}

/// Answers each request with a stream that never ends, as a provider that holds its answer open.
pub(crate) struct Stalled;

impl Transport for Stalled {
    fn open<'a>(&'a self, _: &'a Outgoing<'_>, _: Option<Instant>) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body: BoxBody = Box::pin(Never);
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

/// A body that never yields a chunk.
struct Never;

impl Body for Never {
    fn poll_chunk(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        Poll::Pending
    }
}

/// A body of one chunk.
struct OneChunk(Option<Bytes>);

impl Body for OneChunk {
    fn poll_chunk(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        Poll::Ready(self.0.take().map(Ok))
    }
}
