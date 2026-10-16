//! Test transports and folders that only the yuke tests use. The shared fixtures live in `yuke-testing`.

use std::collections::VecDeque;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use bytes::Bytes;
use yuke_ai::transport::{
    Answer, Body, BoxBody, BoxFuture, Exchange, ExchangeRequest, Fault, Head, Outgoing, Transport,
};
use yuke_store::SqliteStore;
use yuke_testing::ScriptedTransport;

use crate::app::{Machine, Variable};
use crate::paths::Paths;

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

/// Answers each exchange with the next scripted answer, and records each request body. A clone shares the script and
/// the records.
#[derive(Debug, Clone, Default)]
pub(crate) struct Answers(Arc<Mutex<ExchangeScript>>);

#[derive(Debug, Default)]
struct ExchangeScript {
    answers: VecDeque<Result<Answer, Fault>>,
    bodies: Vec<String>,
}

impl Answers {
    /// Add an answer of `status` and `body` to the end of the script.
    pub(crate) fn push(&self, status: u16, body: &str) {
        self.0.lock().unwrap().answers.push_back(Ok(Answer {
            head: Head::new(status),
            body: body.as_bytes().to_vec(),
        }));
    }

    /// Add an exchange that fails with `fault` to the end of the script.
    pub(crate) fn push_fault(&self, fault: Fault) {
        self.0.lock().unwrap().answers.push_back(Err(fault));
    }

    /// The request bodies, in send order.
    pub(crate) fn bodies(&self) -> Vec<String> {
        self.0.lock().unwrap().bodies.clone()
    }
}

impl Exchange for Answers {
    fn exchange<'a>(
        &'a self,
        request: &'a ExchangeRequest<'_>,
        _: Option<Instant>,
    ) -> BoxFuture<'a, Result<Answer, Fault>> {
        let mut script = self.0.lock().unwrap();
        script.bodies.push(String::from_utf8(request.body.to_vec()).unwrap());
        let answer = script.answers.pop_front().expect("the script has no answer left");
        Box::pin(std::future::ready(answer))
    }
}

/// The folders of one test: the profile, the work folder of its sessions, and an empty home folder.
pub(crate) struct Place {
    pub(crate) paths: Paths,
    pub(crate) work: PathBuf,
    pub(crate) home: PathBuf,
}

impl Place {
    /// New empty folders for the test `name` of the suite `suite`.
    pub(crate) fn new(suite: &str, name: &str) -> Place {
        let root = std::env::temp_dir().join(format!("yuke-{suite}-tests-{}/{name}", std::process::id()));
        if root.exists() {
            std::fs::remove_dir_all(&root).unwrap();
        }
        std::fs::create_dir_all(root.join("work")).unwrap();
        std::fs::create_dir_all(root.join("home")).unwrap();
        let root = root.canonicalize().unwrap();
        Place {
            paths: Paths {
                config: root.join("config"),
                data: root.join("data"),
                cache: root.join("cache"),
            },
            work: root.join("work"),
            home: root.join("home"),
        }
    }

    /// The machine of a run in the place. `variable` reads the environment variables.
    pub(crate) fn machine(&self, variable: Box<Variable>, transport: Box<dyn Transport>) -> Machine {
        Machine {
            paths: self.paths.clone(),
            home: Some(self.home.clone()),
            variable,
            transport: transport.into(),
            exchange: Arc::new(Answers::default()),
        }
    }

    /// The store of the place, opened again.
    pub(crate) async fn store(&self) -> SqliteStore {
        SqliteStore::open(&self.paths.data).await.unwrap()
    }
}

/// The MiniMax key that every test environment holds.
pub(crate) fn with_key(name: &str) -> Option<OsString> {
    (name == "MINIMAX_API_KEY").then(|| OsString::from("test-key"))
}
