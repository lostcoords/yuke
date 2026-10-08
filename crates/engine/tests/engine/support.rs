//! A scripted transport and fixtures. Each exchange completes without a wait, except a stall that a test asks for.

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;
use std::time::Instant;

use async_trait::async_trait;
use bytes::Bytes;
use yuke_ai::route::{Credential, Route};
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};
use yuke_ai::{AnthropicWire, Encoder, Request, Target, Wire};
use yuke_engine::{Action, CancellationToken, Inbox, Timer, Tool, ToolContent, ToolContext};

/// An Anthropic target at a test host, with no credential.
pub(crate) fn target() -> Target {
    Target {
        model: "test-model".into(),
        route: Route {
            base_url: "https://example.test/v1".into(),
            ..Route::default()
        },
        credential: Credential::None,
        wire: Wire::AnthropicMessages(AnthropicWire {
            max_tokens: 64,
            cache: false,
        }),
    }
}

/// The body that a request of the blocks of `action` encodes to for [`target`].
pub(crate) fn sent_body(action: Action<'_>) -> String {
    let blocks = match action {
        Action::Send(blocks) => blocks,
        other => panic!("expected a request, got {other:?}"),
    };
    let mut encoder = Encoder::new();
    let encoded = encoder.encode(&target(), Request::new(blocks)).unwrap();
    String::from_utf8(encoded.http.body().flatten().copied().collect()).unwrap()
}

/// The names of the calls that `action` asks to run.
pub(crate) fn called_names(action: Action<'_>) -> Vec<String> {
    match action {
        Action::CallTools(calls) => calls.into_iter().map(|call| call.name.clone()).collect(),
        other => panic!("expected tool calls, got {other:?}"),
    }
}

/// Assert that each of `texts` appears as a JSON string in `body`, in order.
pub(crate) fn assert_in_order(body: &str, texts: &[&str]) {
    let positions: Vec<Option<usize>> = texts.iter().map(|text| body.find(&format!("\"{text}\""))).collect();
    assert!(positions.iter().all(Option::is_some), "{body}");
    assert!(positions.is_sorted(), "{body}");
}

/// One complete Anthropic text answer, as SSE.
pub(crate) fn text_reply(text: &str) -> String {
    [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.to_owned(),
        format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ]
    .map(|json| format!("data: {json}\n\n"))
    .concat()
}

/// An Anthropic answer that fails with an overload error before any output, as SSE.
pub(crate) fn overloaded_reply() -> String {
    [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
    ]
    .map(|json| format!("data: {json}\n\n"))
    .concat()
}

/// An Anthropic answer that streams `text`, then fails with an overload error, as SSE.
pub(crate) fn failed_reply(text: &str) -> String {
    [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.to_owned(),
        format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#),
        r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.to_owned(),
    ]
    .map(|json| format!("data: {json}\n\n"))
    .concat()
}

/// One complete Anthropic answer that asks for `calls`, each an id, a name, and JSON arguments, as SSE.
pub(crate) fn tool_reply(calls: &[(&str, &str, &str)]) -> String {
    let mut events = vec![r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned()];
    for (index, (id, name, arguments)) in calls.iter().enumerate() {
        let arguments = arguments.replace('\\', "\\\\").replace('"', "\\\"");
        events.extend([
            format!(
                r#"{{"type":"content_block_start","index":{index},"content_block":{{"type":"tool_use","id":"{id}","name":"{name}","input":{{}}}}}}"#
            ),
            format!(
                r#"{{"type":"content_block_delta","index":{index},"delta":{{"type":"input_json_delta","partial_json":"{arguments}"}}}}"#
            ),
            format!(r#"{{"type":"content_block_stop","index":{index}}}"#),
        ]);
    }
    events.extend([
        r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ]);
    events
        .iter()
        .map(|json| format!("data: {json}\n\n"))
        .collect::<Vec<_>>()
        .concat()
}

/// An answer like [`tool_reply`] that the output limit cut, as SSE.
pub(crate) fn cut_reply(calls: &[(&str, &str, &str)]) -> String {
    tool_reply(calls).replace(r#""stop_reason":"tool_use""#, r#""stop_reason":"max_tokens""#)
}

/// A definition of `name` that takes any object.
pub(crate) fn definition(name: &str) -> yuke_ai::ToolDefinition {
    yuke_ai::ToolDefinition::new(name, "A test tool.", r#"{"type":"object"}"#)
}

/// A tool that records the arguments of each call, and answers the call with "result N", counted from 1.
#[derive(Debug, Default, Clone)]
pub(crate) struct Recorder {
    calls: Arc<Mutex<Vec<String>>>,
}

impl Recorder {
    /// The arguments of each call, in call order.
    pub(crate) fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl Tool for Recorder {
    async fn call(&self, arguments: &str, _: &mut ToolContext<'_>) -> Result<ToolContent, String> {
        let mut calls = self.calls.lock().unwrap();
        calls.push(arguments.to_owned());
        Ok(format!("result {}", calls.len()).into())
    }
}

/// An inbox that hands out one scripted batch for each take, then nothing.
#[derive(Debug, Default)]
pub(crate) struct Batches {
    batches: Mutex<VecDeque<Vec<yuke_ai::Block>>>,
}

impl Batches {
    pub(crate) fn new(batches: impl IntoIterator<Item = Vec<yuke_ai::Block>>) -> Self {
        Batches {
            batches: Mutex::new(batches.into_iter().collect()),
        }
    }
}

impl Inbox for Batches {
    fn take(&self) -> Vec<yuke_ai::Block> {
        self.batches.lock().unwrap().pop_front().unwrap_or_default()
    }
}

/// A timer whose waits end at once.
pub(crate) struct NoWait;

#[async_trait]
impl Timer for NoWait {
    async fn sleep(&self, _: Duration) {}
}

/// A timer that records each wait and ends it at once.
#[derive(Debug, Default)]
pub(crate) struct Waits {
    waits: Mutex<Vec<Duration>>,
}

impl Waits {
    /// The waits, in order.
    pub(crate) fn waits(&self) -> Vec<Duration> {
        self.waits.lock().unwrap().clone()
    }
}

#[async_trait]
impl Timer for Waits {
    async fn sleep(&self, duration: Duration) {
        self.waits.lock().unwrap().push(duration);
    }
}

/// Answer each open with the next scripted reply, and record each request body.
#[derive(Debug, Default)]
pub(crate) struct ScriptedTransport {
    replies: Mutex<VecDeque<OneChunk>>,
    requests: Mutex<Vec<String>>,
}

impl ScriptedTransport {
    pub(crate) fn new(replies: impl IntoIterator<Item = String>) -> Self {
        ScriptedTransport {
            replies: Mutex::new(
                replies
                    .into_iter()
                    .map(|reply| OneChunk {
                        chunk: Some(Bytes::from(reply)),
                        stalls: false,
                    })
                    .collect(),
            ),
            requests: Mutex::default(),
        }
    }

    /// Add a reply that sends `reply`, then waits forever. It acts as a stream that the provider holds open.
    pub(crate) fn then_stall(self, reply: String) -> Self {
        self.replies.lock().unwrap().push_back(OneChunk {
            chunk: Some(Bytes::from(reply)),
            stalls: true,
        });
        self
    }

    /// The request bodies, in send order.
    pub(crate) fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
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
        let body: BoxBody = Box::pin(reply);
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

/// A body of one chunk. A body that stalls never ends after its chunk.
#[derive(Debug)]
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

/// A timer that cancels the turn when its wait starts. The wait never ends by itself.
pub(crate) struct CancelOnSleep(pub(crate) CancellationToken);

#[async_trait]
impl Timer for CancelOnSleep {
    async fn sleep(&self, _: Duration) {
        self.0.cancel();
        std::future::pending::<()>().await;
    }
}

/// Run a future to its end. It polls again only after a wake, and a future that waits with no wake fails the test.
pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    let woken = Arc::new(Woken::default());
    let waker = Waker::from(Arc::clone(&woken));
    let mut context = Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    loop {
        if let Poll::Ready(output) = future.as_mut().poll(&mut context) {
            return output;
        }
        assert!(
            woken.0.swap(false, Ordering::SeqCst),
            "the future waits for something that no test ends"
        );
    }
}

/// A waker that records a wake.
#[derive(Default)]
struct Woken(AtomicBool);

impl std::task::Wake for Woken {
    fn wake(self: Arc<Self>) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// Wait once, and wake at once, as a short wait for the operating system does.
pub(crate) async fn yield_once() {
    let mut yielded = false;
    std::future::poll_fn(|context| {
        if yielded {
            return Poll::Ready(());
        }
        yielded = true;
        context.waker().wake_by_ref();
        Poll::Pending
    })
    .await;
}
