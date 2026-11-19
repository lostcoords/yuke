//! Test transports and folders that only the yuke tests use. The shared fixtures live in `yuke-testing`.

use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use yuke_ai::scripted::ScriptedExchange;
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};
use yuke_store::FileStore;

use async_trait::async_trait;
use yuke_engine::Timer;

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

/// The folders of one test: the profile, the work folder of its sessions, and an empty home folder.
pub(crate) struct Place {
    pub(crate) paths: Paths,
    pub(crate) work: PathBuf,
    pub(crate) home: PathBuf,
}

impl Place {
    /// New empty folders for the test `name` of the suite `suite`.
    pub(crate) fn new(suite: &str, name: &str) -> Place {
        let root = yuke_testing::folder(suite, name);
        std::fs::create_dir_all(root.join("work")).unwrap();
        std::fs::create_dir_all(root.join("home")).unwrap();
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
            exchange: Arc::new(ScriptedExchange::default()),
            fetch: Arc::new(
                yuke_http::Client::new(yuke_http::ClientOptions {
                    idle_timeout: None,
                    user_agent: "yuke-test".to_owned(),
                })
                .unwrap(),
            ),
            interface: None,
            internal_imports: false,
            test: None,
        }
    }

    /// Write the plugin `name` in the profile folder: its manifest, and `source` as its entry `index.ts`.
    pub(crate) fn plugin(&self, name: &str, source: &str) {
        let folder = self.paths.config.join(name);
        std::fs::create_dir_all(&folder).unwrap();
        let manifest = format!(r#"{{ "name": "{name}", "extensions": {{ "sh.yuke": {{ "entry": "index.ts" }} }} }}"#);
        std::fs::write(folder.join("plugin.json"), manifest).unwrap();
        std::fs::write(folder.join("index.ts"), source).unwrap();
    }

    /// The store of the place, opened again.
    pub(crate) async fn store(&self) -> FileStore {
        FileStore::open(&self.paths.data).await.unwrap()
    }
}

/// The MiniMax key that every test environment holds.
pub(crate) fn with_key(name: &str) -> Option<OsString> {
    (name == "MINIMAX_API_KEY").then(|| OsString::from("test-key"))
}

/// Counts its waits, and returns at once.
#[derive(Default)]
pub(crate) struct CountedWaits(AtomicUsize);

impl CountedWaits {
    /// The number of waits so far.
    pub(crate) fn count(&self) -> usize {
        self.0.load(Ordering::SeqCst)
    }
}

#[async_trait(?Send)]
impl Timer for CountedWaits {
    async fn sleep(&self, _: Duration) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}
