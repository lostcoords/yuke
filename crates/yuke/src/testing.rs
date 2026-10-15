//! Test transports that only the yuke tests use. The shared fixtures live in `yuke-testing`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use bytes::Bytes;
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};
use yuke_testing::ScriptedTransport;

/// Answers each request with a 401: the provider rejects the credential.
pub(crate) struct Rejecting;

impl Transport for Rejecting {
    fn open<'a>(&'a self, _: &'a Outgoing<'_>, _: Option<Instant>) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body: BoxBody = Box::pin(OneChunk(Some(Bytes::from_static(b"{}"))));
        Box::pin(std::future::ready(Ok((Head::new(401), body))))
    }
}

/// A body of one chunk.
struct OneChunk(Option<Bytes>);

impl Body for OneChunk {
    fn poll_chunk(
        mut self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<Bytes, Fault>>> {
        std::task::Poll::Ready(self.0.take().map(Ok))
    }
}

/// Panics at its first request, as a provider path with a bug, and then answers as its script.
pub(crate) struct PanicsOnce {
    panicked: AtomicBool,
    script: ScriptedTransport,
}

impl PanicsOnce {
    pub(crate) fn new(replies: impl IntoIterator<Item = String>) -> Self {
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
