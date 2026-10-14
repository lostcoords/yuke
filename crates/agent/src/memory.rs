//! A store that keeps its sessions in memory.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_engine::{Commit, Outcome, TurnEnd};

use crate::lock;
use yuke_protocol::{EventNumber, InputId, PendingInput, SessionEvent, SessionId, SessionSettings, StoredEvent};

use crate::store::{Access, Lease, Opened, Store, StoreError, blob_of};

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
    newest_input: u64,
    /// The number of event writes of all sessions. It orders the sessions by their newest event.
    writes: u64,
}

impl State {
    /// The order number of a new event write.
    fn next_write(&mut self) -> u64 {
        self.writes += 1;
        self.writes
    }
}

/// One session. Its settings, its context, and whether a turn is open follow from its events.
#[derive(Debug)]
struct Saved {
    /// The events of the session. The event at index `i` has the number `i + 1`.
    events: Vec<StoredEvent>,
    pending: Vec<PendingInput>,
    /// The blobs of the session, by digest.
    blobs: HashMap<yuke_ai::Digest, Vec<u8>>,
    /// The order number of the newest event write of the session.
    newest_write: u64,
}

impl Saved {
    /// Save `event` with the next number of the session. `write` is the order number of the write.
    fn push_event(&mut self, event: SessionEvent, write: u64) -> EventNumber {
        let event_number = EventNumber(self.events.len() as u64 + 1);
        self.events.push(StoredEvent { event_number, event });
        self.newest_write = write;
        event_number
    }

    /// The settings of the newest settings event.
    fn settings(&self) -> Option<&SessionSettings> {
        self.events.iter().rev().find_map(|stored| match &stored.event {
            SessionEvent::Settings(settings) => Some(settings),
            SessionEvent::Commit { .. } => None,
        })
    }

    /// The session `id` as a load gives it, with `lease`. A replay of the events gives the settings and the context.
    #[expect(clippy::expect_used, reason = "a create and a fork each save a settings event first")]
    fn to_opened(&self, id: SessionId, lease: Option<Lease>) -> Opened {
        let mut settings = None;
        let mut context = Vec::new();
        let mut turn_open = false;
        for stored in &self.events {
            match &stored.event {
                SessionEvent::Settings(event_settings) => settings = Some(event_settings),
                SessionEvent::Commit { commit, .. } => {
                    commit.apply(&mut context);
                    turn_open = commit.end.is_none();
                }
            }
        }
        Opened {
            id,
            settings: settings.expect("the session has a settings event").clone(),
            context,
            turn_open,
            lease,
        }
    }
}

/// The number of events that a fork of `events` copies. `through` names the end of a completed turn. `None` takes the
/// newest one, or the events before the first commit when no turn completed.
fn fork_cut(events: &[StoredEvent], through: Option<EventNumber>) -> Result<usize, StoreError> {
    let completed = |stored: &StoredEvent| {
        matches!(
            &stored.event,
            SessionEvent::Commit { commit, .. }
                if matches!(commit.end, Some(TurnEnd::Outcome(Outcome::Completed { .. })))
        )
    };
    match through {
        Some(through) => {
            let cut = usize::try_from(through.0).map_err(|_| StoreError::NotACompletedTurn)?;
            match cut.checked_sub(1).and_then(|index| events.get(index)) {
                Some(stored) if completed(stored) => Ok(cut),
                _ => Err(StoreError::NotACompletedTurn),
            }
        }
        None => Ok(events
            .iter()
            .rposition(completed)
            .map(|index| index + 1)
            .or_else(|| {
                events
                    .iter()
                    .position(|stored| matches!(stored.event, SessionEvent::Commit { .. }))
            })
            .unwrap_or(events.len())),
    }
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
        let mut state = lock(&self.state);
        let mut saved = Saved {
            events: Vec::new(),
            pending: Vec::new(),
            blobs: HashMap::new(),
            newest_write: 0,
        };
        saved.push_event(SessionEvent::Settings(settings.clone()), state.next_write());
        let opened = saved.to_opened(id, Some(self.take_writer(id)?));
        state.sessions.insert(id, saved);
        Ok(opened)
    }

    async fn fork_session(&self, source: SessionId, through: Option<EventNumber>) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let mut state = lock(&self.state);
        let write = state.next_write();
        let saved = state.sessions.get(&source).ok_or(StoreError::NotFound)?;
        let fork = Saved {
            events: saved.events[..fork_cut(&saved.events, through)?].to_vec(),
            pending: Vec::new(),
            blobs: saved.blobs.clone(),
            newest_write: write,
        };
        let opened = fork.to_opened(id, Some(self.take_writer(id)?));
        state.sessions.insert(id, fork);
        Ok(opened)
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<(), StoreError> {
        let mut state = lock(&self.state);
        let write = state.next_write();
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        saved.push_event(SessionEvent::Settings(settings.clone()), write);
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

    async fn newest_session(&self, cwd: &Path) -> Result<Option<SessionId>, StoreError> {
        let state = lock(&self.state);
        Ok(state
            .sessions
            .iter()
            .filter(|(_, saved)| saved.settings().is_some_and(|settings| settings.cwd == cwd))
            .max_by_key(|(_, saved)| saved.newest_write)
            .map(|(id, _)| *id))
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        let state = lock(&self.state);
        let saved = state.sessions.get(&id).ok_or(StoreError::NotFound)?;
        let lease = match access {
            Access::Read => None,
            Access::Write => Some(self.take_writer(id)?),
        };
        Ok(saved.to_opened(id, lease))
    }

    async fn commit(
        &self,
        id: SessionId,
        commit: &Commit<'_>,
        consumed: &[InputId],
    ) -> Result<EventNumber, StoreError> {
        let mut state = lock(&self.state);
        let write = state.next_write();
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        saved.pending.retain(|input| !consumed.contains(&input.id));
        let event_number = saved.push_event(
            SessionEvent::Commit {
                commit: commit.clone().into_owned(),
                consumed: consumed.to_vec(),
            },
            write,
        );
        Ok(event_number)
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        let state = lock(&self.state);
        Ok(state.sessions.get(&id).ok_or(StoreError::NotFound)?.pending.clone())
    }

    async fn events(&self, id: SessionId, after: Option<EventNumber>) -> Result<Vec<StoredEvent>, StoreError> {
        let state = lock(&self.state);
        let saved = state.sessions.get(&id).ok_or(StoreError::NotFound)?;
        // Event number `n` sits at index `n - 1`, so the events after it start at index `n`.
        let after = after.map_or(0, |after| usize::try_from(after.0).unwrap_or(usize::MAX));
        let after = after.min(saved.events.len());
        Ok(saved.events[after..].to_vec())
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
