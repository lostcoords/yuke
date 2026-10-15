//! The fixtures that only the session tests use: settings, inputs, a tool that sends input, and a store that fails a
//! chosen commit. The shared ones live in `yuke-testing`.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use yuke_agent::{Access, InputSender, Loaded, MemoryStore, Opened, Store, StoreError};
use yuke_ai::Block;
use yuke_engine::{Commit, Tool, ToolContent, ToolContext};
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, InputSource, ModelReference, PendingInput, SessionEvent, SessionId,
    SessionSettings,
};

/// Session settings for the shared test target.
pub(crate) fn settings() -> SessionSettings {
    SessionSettings {
        model: ModelReference {
            provider: "test".to_owned(),
            model: "test-model".to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: std::path::PathBuf::from("/work"),
    }
}

/// An input of the user with one text block.
pub(crate) fn user_input(text: &str) -> Input {
    Input::new(InputSource::User, vec![Block::user_text(text)]).unwrap()
}

/// The records of the inputs that the commits of session `id` consumed, in event order.
pub(crate) async fn consumed_inputs(store: &dyn Store, id: SessionId) -> Vec<ConsumedInput> {
    store
        .load(id, None)
        .await
        .map(|loaded| loaded.events)
        .unwrap()
        .into_iter()
        .flat_map(|stored| match stored.event {
            SessionEvent::Commit { consumed, .. } => consumed,
            SessionEvent::Settings(_) => Vec::new(),
        })
        .collect()
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
            .send(user_input(self.text))
            .await
            .map_err(|error| error.to_string())?;
        Ok("sent".into())
    }
}

/// A failure mode for a test store.
#[derive(Debug, Clone, Copy)]
pub(crate) enum StoreBehavior {
    /// Fail the commit at this position without a save. Count commits from 1.
    FailCommit(usize),
    /// Save the commit at this position, then report a failure.
    FailAfterCommit(usize),
    /// Wait forever before the commit at this position.
    StallCommit(usize),
    /// Save the settings. Do not answer the write.
    StallSettings,
    /// Fail each read of the pending inputs.
    FailPending,
}

/// A memory store with one selected failure mode.
#[derive(Debug)]
pub(crate) struct FailingStore {
    store: MemoryStore,
    behavior: StoreBehavior,
    commits: AtomicUsize,
}

impl FailingStore {
    pub(crate) fn new(behavior: StoreBehavior) -> Arc<Self> {
        Arc::new(FailingStore {
            store: MemoryStore::new(),
            behavior,
            commits: AtomicUsize::new(0),
        })
    }
}

#[async_trait]
impl Store for FailingStore {
    async fn create_session(&self, settings: &SessionSettings) -> Result<Opened, StoreError> {
        self.store.create_session(settings).await
    }

    async fn fork_session(&self, source: SessionId, through: Option<EventNumber>) -> Result<Opened, StoreError> {
        self.store.fork_session(source, through).await
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<EventNumber, StoreError> {
        let event_number = self.store.set_settings(id, settings).await?;
        if matches!(self.behavior, StoreBehavior::StallSettings) {
            std::future::pending::<()>().await;
        }
        Ok(event_number)
    }

    async fn accept_input(&self, id: SessionId, input: Input) -> Result<InputId, StoreError> {
        self.store.accept_input(id, input).await
    }

    async fn remove_input(&self, id: SessionId, input: InputId) -> Result<(), StoreError> {
        self.store.remove_input(id, input).await
    }

    async fn newest_session(&self, cwd: &Path) -> Result<Option<SessionId>, StoreError> {
        self.store.newest_session(cwd).await
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        self.store.open(id, access).await
    }

    async fn commit(
        &self,
        id: SessionId,
        commit: &Commit<'_>,
        consumed: &[ConsumedInput],
    ) -> Result<EventNumber, StoreError> {
        let number = self.commits.fetch_add(1, Ordering::SeqCst) + 1;
        if let StoreBehavior::FailCommit(fail_at) = self.behavior
            && number == fail_at
        {
            return Err(StoreError::Failed("the disk is full".into()));
        }
        if let StoreBehavior::StallCommit(stall_at) = self.behavior
            && number == stall_at
        {
            std::future::pending::<()>().await;
        }
        let receipt = self.store.commit(id, commit, consumed).await?;
        if let StoreBehavior::FailAfterCommit(fail_at) = self.behavior
            && number == fail_at
        {
            return Err(StoreError::Failed("the write result was lost".into()));
        }
        Ok(receipt)
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        if matches!(self.behavior, StoreBehavior::FailPending) {
            return Err(StoreError::Failed("the disk is gone".into()));
        }
        self.store.pending(id).await
    }

    async fn load(&self, id: SessionId, after: Option<EventNumber>) -> Result<Loaded, StoreError> {
        self.store.load(id, after).await
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
