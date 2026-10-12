//! A store that keeps its sessions in memory.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_engine::Commit;

use crate::lock;
use crate::store::{
    Access, InputId, Lease, Opened, PendingInput, SessionId, SessionSettings, Store, StoreError, blob_of,
};

/// A [`Store`] that keeps its sessions in memory, for tests and for a caller that saves nothing. It refuses a second
/// writer of a session, as a store with a file lock does.
#[derive(Debug, Default)]
pub struct MemoryStore {
    state: Mutex<State>,
    /// The sessions that a writer holds. A lease removes its session when it drops.
    writers: Arc<Mutex<HashSet<SessionId>>>,
}

#[derive(Debug, Default)]
struct State {
    sessions: HashMap<SessionId, Saved>,
    /// The id of the newest input of all sessions.
    newest_input: i64,
}

/// One session as a store load gives it.
#[derive(Debug)]
struct Saved {
    settings: SessionSettings,
    context: Vec<yuke_ai::Block>,
    pending: Vec<PendingInput>,
    turn_open: bool,
    /// The blobs of the session, by digest.
    blobs: HashMap<yuke_ai::Digest, Vec<u8>>,
}

/// The lock of one writer.
struct Writer {
    writers: Arc<Mutex<HashSet<SessionId>>>,
    id: SessionId,
}

impl Drop for Writer {
    fn drop(&mut self) {
        lock(&self.writers).remove(&self.id);
    }
}

impl MemoryStore {
    /// A store with no sessions.
    pub fn new() -> Self {
        Self::default()
    }

    /// The lease of the one writer of session `id`.
    fn take_writer(&self, id: SessionId) -> Result<Lease, StoreError> {
        if !lock(&self.writers).insert(id) {
            return Err(StoreError::Owned);
        }
        Ok(Lease::new(Writer {
            writers: Arc::clone(&self.writers),
            id,
        }))
    }
}

#[async_trait]
impl Store for MemoryStore {
    async fn create_session(&self, settings: &SessionSettings) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        lock(&self.state).sessions.insert(
            id,
            Saved {
                settings: settings.clone(),
                context: Vec::new(),
                pending: Vec::new(),
                turn_open: false,
                blobs: HashMap::new(),
            },
        );
        Ok(Opened {
            id,
            settings: settings.clone(),
            context: Vec::new(),
            turn_open: false,
            lease: Some(self.take_writer(id)?),
        })
    }

    async fn fork_session(&self, source: SessionId) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let mut state = lock(&self.state);
        let saved = state.sessions.get(&source).ok_or(StoreError::NotFound)?;
        let fork = Saved {
            settings: saved.settings.clone(),
            context: saved.context.clone(),
            pending: Vec::new(),
            turn_open: saved.turn_open,
            blobs: saved.blobs.clone(),
        };
        let opened = Opened {
            id,
            settings: fork.settings.clone(),
            context: fork.context.clone(),
            turn_open: fork.turn_open,
            lease: Some(self.take_writer(id)?),
        };
        state.sessions.insert(id, fork);
        Ok(opened)
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<(), StoreError> {
        let mut state = lock(&self.state);
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        saved.settings = settings.clone();
        Ok(())
    }

    async fn accept_input(&self, id: SessionId, blocks: &[yuke_ai::Block]) -> Result<InputId, StoreError> {
        let mut state = lock(&self.state);
        let input = InputId(state.newest_input + 1);
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        saved.pending.push(PendingInput {
            id: input,
            blocks: blocks.to_vec(),
        });
        state.newest_input = input.0;
        Ok(input)
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        let state = lock(&self.state);
        let saved = state.sessions.get(&id).ok_or(StoreError::NotFound)?;
        let lease = match access {
            Access::Read => None,
            Access::Write => Some(self.take_writer(id)?),
        };
        Ok(Opened {
            id,
            settings: saved.settings.clone(),
            context: saved.context.clone(),
            turn_open: saved.turn_open,
            lease,
        })
    }

    async fn commit(&self, id: SessionId, commit: &Commit<'_>, consumed: &[InputId]) -> Result<(), StoreError> {
        let mut state = lock(&self.state);
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        if let Some(replaced) = commit.replaced {
            let kept = saved
                .context
                .split_off(saved.context.len().saturating_sub(replaced.keep));
            saved.context = [replaced.head, &kept].concat();
        }
        saved.context.extend_from_slice(commit.blocks);
        saved.pending.retain(|input| !consumed.contains(&input.id));
        saved.turn_open = commit.end.is_none();
        Ok(())
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        let state = lock(&self.state);
        Ok(state.sessions.get(&id).ok_or(StoreError::NotFound)?.pending.clone())
    }

    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, StoreError> {
        let blob = blob_of(&bytes);
        let mut state = lock(&self.state);
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        saved.blobs.insert(blob.digest, bytes);
        Ok(blob)
    }

    fn read_blob(&self, id: SessionId, digest: &yuke_ai::Digest) -> Result<Option<Vec<u8>>, StoreError> {
        let state = lock(&self.state);
        let saved = state.sessions.get(&id).ok_or(StoreError::NotFound)?;
        Ok(saved.blobs.get(digest).cloned())
    }

    async fn delete_session(&self, id: SessionId) -> Result<(), StoreError> {
        let mut state = lock(&self.state);
        if !state.sessions.contains_key(&id) {
            return Err(StoreError::NotFound);
        }
        if lock(&self.writers).contains(&id) {
            return Err(StoreError::Owned);
        }
        state.sessions.remove(&id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::MemoryStore;

    #[expect(clippy::unused_async, reason = "`store_tests!` awaits each factory")]
    async fn make_store(_: &str) -> Arc<MemoryStore> {
        Arc::new(MemoryStore::new())
    }

    crate::store_tests!(make_store);
}
