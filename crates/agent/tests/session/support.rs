//! A scripted transport, reply fixtures, and a store that fails a chosen commit.

use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use yuke_agent::{
    Access, InputId, InputSender, MemoryStore, ModelReference, Opened, PendingInput, SessionId, SessionSettings, Store,
    StoreError,
};
use yuke_ai::route::{Credential, Route};
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};
use yuke_ai::{AnthropicWire, Block, Target, Wire};
use yuke_engine::{Commit, Timer, Tool, ToolContent, ToolContext};

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
        tool_search: false,
    }
}

/// Session settings for [`target`].
pub(crate) fn settings() -> SessionSettings {
    SessionSettings {
        model: ModelReference::new("test", "test-model"),
        settings: yuke_ai::Settings::new(),
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
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.to_owned(),
        format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ])
}

/// An Anthropic answer that streams `text`, then fails with an overload error, as SSE. The output before the error
/// stops a retry, so the request fails at once.
pub(crate) fn failed_reply(text: &str) -> String {
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.to_owned(),
        format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#),
        r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.to_owned(),
    ])
}

/// One complete Anthropic answer that asks for one call of `name` with the id `id` and no arguments, as SSE.
pub(crate) fn tool_reply(id: &str, name: &str) -> String {
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        format!(
            r#"{{"type":"content_block_start","index":0,"content_block":{{"type":"tool_use","id":"{id}","name":"{name}","input":{{}}}}}}"#
        ),
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#
            .to_owned(),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ])
}

fn sse(events: &[String]) -> String {
    events
        .iter()
        .map(|json| format!("data: {json}\n\n"))
        .collect::<Vec<_>>()
        .concat()
}

/// Answer each open with the next scripted reply, and record each request body.
#[derive(Debug, Default)]
pub(crate) struct ScriptedTransport {
    replies: Mutex<VecDeque<String>>,
    requests: Mutex<Vec<String>>,
}

impl ScriptedTransport {
    pub(crate) fn new(replies: impl IntoIterator<Item = String>) -> Self {
        ScriptedTransport {
            replies: Mutex::new(replies.into_iter().collect()),
            requests: Mutex::default(),
        }
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
        let body: BoxBody = Box::pin(OneChunk(Some(Bytes::from(reply))));
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

/// A transport whose answer never ends, as a provider that holds its stream open. It is also the body of that answer.
#[derive(Debug)]
pub(crate) struct Stalled;

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

/// A body of one chunk.
#[derive(Debug)]
struct OneChunk(Option<Bytes>);

impl Body for OneChunk {
    fn poll_chunk(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        Poll::Ready(self.0.take().map(Ok))
    }
}

/// A timer whose waits end at once.
pub(crate) struct NoWait;

#[async_trait]
impl Timer for NoWait {
    async fn sleep(&self, _: Duration) {}
}

/// A tool that sends one input to its session, and answers "sent".
pub(crate) struct SendsInput {
    pub(crate) sender: InputSender,
    pub(crate) text: &'static str,
}

#[async_trait]
impl Tool for SendsInput {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        self.sender
            .send(&[Block::user_text(self.text)])
            .await
            .map_err(|error| error.to_string())?;
        Ok("sent".into())
    }
}

/// A memory store whose commit number `fail_at`, counted from 1, fails without a save.
#[derive(Debug)]
pub(crate) struct FailingStore {
    store: MemoryStore,
    fail_at: usize,
    commits: AtomicUsize,
    forks: Mutex<Vec<SessionId>>,
}

impl FailingStore {
    pub(crate) fn new(fail_at: usize) -> Arc<Self> {
        Arc::new(FailingStore {
            store: MemoryStore::new(),
            fail_at,
            commits: AtomicUsize::new(0),
            forks: Mutex::default(),
        })
    }

    /// The id of each session that a fork made.
    pub(crate) fn forks(&self) -> Vec<SessionId> {
        self.forks.lock().unwrap().clone()
    }
}

#[async_trait]
impl Store for FailingStore {
    async fn create_session(&self, settings: &SessionSettings) -> Result<Opened, StoreError> {
        self.store.create_session(settings).await
    }

    async fn fork_session(&self, source: SessionId) -> Result<Opened, StoreError> {
        let opened = self.store.fork_session(source).await?;
        self.forks.lock().unwrap().push(opened.id);
        Ok(opened)
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<(), StoreError> {
        self.store.set_settings(id, settings).await
    }

    async fn accept_input(&self, id: SessionId, blocks: &[Block]) -> Result<InputId, StoreError> {
        self.store.accept_input(id, blocks).await
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        self.store.open(id, access).await
    }

    async fn commit(&self, id: SessionId, commit: &Commit<'_>, consumed: &[InputId]) -> Result<(), StoreError> {
        if self.commits.fetch_add(1, Ordering::SeqCst) + 1 == self.fail_at {
            return Err(StoreError::Failed("the disk is full".into()));
        }
        self.store.commit(id, commit, consumed).await
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        self.store.pending(id).await
    }

    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, StoreError> {
        self.store.put_blob(id, bytes).await
    }

    fn read_blob(&self, id: SessionId, digest: &yuke_ai::Digest) -> Result<Option<Vec<u8>>, StoreError> {
        self.store.read_blob(id, digest)
    }

    async fn delete_session(&self, id: SessionId) -> Result<(), StoreError> {
        self.store.delete_session(id).await
    }
}
