//! A store that keeps its sessions in memory.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_engine::Commit;

use crate::lock;
use crate::store::{Access, InputId, Lease, Opened, PendingInput, SessionId, SessionSettings, Store, StoreError};

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
