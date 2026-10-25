//! A store that keeps its sessions in memory.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use yuke_engine::{Commit, Outcome, TurnEnd};

use crate::{PromptSection, lock};
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, PendingInput, SessionEvent, SessionId, SessionSettings, SessionSummary,
    StoredEvent,
};

use crate::store::{
    Access, Lease, ListPosition, Loaded, NewestTurn, Opened, SessionPage, Store, StoreError, blob_of,
    check_consumed_blocks, preview_of,
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
    /// The sections of the system prompt of the session.
    prompt: Vec<PromptSection>,
    /// The events of the session. The event at index `i` has the number `i + 1`.
    events: Vec<StoredEvent>,
    pending: Vec<PendingInput>,
    /// The blobs of the session, by digest.
    blobs: HashMap<yuke_ai::Digest, Vec<u8>>,
    /// The order number of the newest event write of the session.
    newest_write: u64,
    /// The trimmed user text of the first message input with text.
    preview: Option<String>,
    /// The source of a fork.
    fork_of: Option<SessionId>,
    /// The creation time, in milliseconds since the Unix epoch.
    created_at: u64,
    /// The time of the newest event, in milliseconds since the Unix epoch.
    updated_at: u64,
}

/// The time now, in milliseconds since the Unix epoch.
fn now_ms() -> u64 {
    // A clock before 1970 gives 0, as the times of a store need no more.
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

impl Saved {
    /// Save `event` with the next number of the session. `write` is the order number of the write.
    fn push_event(&mut self, event: SessionEvent, write: u64) -> EventNumber {
        let event_number = EventNumber(self.events.len() as u64 + 1);
        self.events.push(StoredEvent { event_number, event });
        self.newest_write = write;
        self.updated_at = now_ms();
        event_number
    }

    /// The saved facts of the session `id`.
    #[expect(clippy::expect_used, reason = "a create and a fork each save a settings event first")]
    fn summary(&self, id: SessionId) -> SessionSummary {
        let settings = self.settings().expect("the session has a settings event");
        SessionSummary {
            session_id: id,
            model: settings.model.clone(),
            cwd: settings.cwd.clone(),
            preview: self.preview.clone(),
            created_at: self.created_at,
            updated_at: self.updated_at,
            fork_of: self.fork_of,
        }
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
        let mut newest_turn = NewestTurn::Empty;
        let mut input_tokens = None;
        for stored in &self.events {
            match &stored.event {
                SessionEvent::Settings(event_settings) => settings = Some(event_settings),
                SessionEvent::Commit { commit, .. } => {
                    commit.apply(&mut context);
                    newest_turn = commit.end.clone().map_or(NewestTurn::Open, NewestTurn::Ended);
                    if let Some(answer) = &commit.answer {
                        input_tokens = answer.usage.input;
                    }
                }
            }
        }
        Opened {
            id,
            settings: settings.expect("the session has a settings event").clone(),
            prompt: self.prompt.clone(),
            context,
            newest_turn,
            input_tokens,
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
    async fn create_session(&self, settings: &SessionSettings, prompt: &[PromptSection]) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let mut state = lock(&self.state);
        let now = now_ms();
        let mut saved = Saved {
            prompt: prompt.to_vec(),
            events: Vec::new(),
            pending: Vec::new(),
            blobs: HashMap::new(),
            newest_write: 0,
            preview: None,
            fork_of: None,
            created_at: now,
            updated_at: now,
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
        let now = now_ms();
        let fork = Saved {
            prompt: saved.prompt.clone(),
            events: saved.events[..fork_cut(&saved.events, through)?].to_vec(),
            pending: Vec::new(),
            blobs: saved.blobs.clone(),
            newest_write: write,
            preview: saved.preview.clone(),
            fork_of: Some(source),
            created_at: now,
            updated_at: now,
        };
        let opened = fork.to_opened(id, Some(self.take_writer(id)?));
        state.sessions.insert(id, fork);
        Ok(opened)
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<EventNumber, StoreError> {
        let mut state = lock(&self.state);
        let write = state.next_write();
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        Ok(saved.push_event(SessionEvent::Settings(settings.clone()), write))
    }

    async fn accept_input(&self, id: SessionId, input: Input) -> Result<InputId, StoreError> {
        let mut state = lock(&self.state);
        let input_id = InputId(state.newest_input + 1);
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        if saved.preview.is_none() {
            saved.preview = preview_of(&input);
        }
        saved.pending.push(PendingInput { id: input_id, input });
        state.newest_input = input_id.0;
        Ok(input_id)
    }

    async fn remove_input(&self, id: SessionId, input: InputId) -> Result<(), StoreError> {
        let mut state = lock(&self.state);
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        let position = saved
            .pending
            .iter()
            .position(|pending| pending.id == input)
            .ok_or(StoreError::InputNotPending(input))?;
        saved.pending.remove(position);
        Ok(())
    }

    async fn list_sessions(
        &self,
        cwd: Option<&Path>,
        after: Option<ListPosition>,
        limit: usize,
    ) -> Result<SessionPage, StoreError> {
        // The SQLite store saves a folder as UTF-8 JSON text, so a folder that is not UTF-8 lists no session.
        if cwd.is_some_and(|cwd| cwd.to_str().is_none()) {
            return Ok(SessionPage {
                sessions: Vec::new(),
                next: None,
            });
        }
        let state = lock(&self.state);
        let mut listed: Vec<(&SessionId, &Saved)> = state
            .sessions
            .iter()
            .filter(|(_, saved)| after.is_none_or(|ListPosition(before)| saved.newest_write < before))
            .filter(|(_, saved)| cwd.is_none_or(|cwd| saved.settings().is_some_and(|settings| settings.cwd == cwd)))
            .collect();
        listed.sort_by_key(|(_, saved)| std::cmp::Reverse(saved.newest_write));
        let next = (listed.len() > limit)
            .then(|| limit.checked_sub(1).and_then(|last| listed.get(last)))
            .flatten()
            .map(|(_, saved)| ListPosition(saved.newest_write));
        Ok(SessionPage {
            sessions: listed
                .into_iter()
                .take(limit)
                .map(|(id, saved)| saved.summary(*id))
                .collect(),
            next,
        })
    }

    async fn session_summary(&self, id: SessionId) -> Result<SessionSummary, StoreError> {
        let state = lock(&self.state);
        Ok(state.sessions.get(&id).ok_or(StoreError::NotFound)?.summary(id))
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
        consumed: &[ConsumedInput],
    ) -> Result<EventNumber, StoreError> {
        check_consumed_blocks(commit, consumed)?;
        let mut state = lock(&self.state);
        let saved = state.sessions.get(&id).ok_or(StoreError::NotFound)?;
        // Each check comes before the first change, so a refused commit changes nothing.
        for (index, input) in consumed.iter().enumerate() {
            let taken_before = consumed[..index].iter().any(|earlier| earlier.id == input.id);
            if taken_before || !saved.pending.iter().any(|pending| pending.id == input.id) {
                return Err(StoreError::InputNotPending(input.id));
            }
        }
        let write = state.next_write();
        let saved = state.sessions.get_mut(&id).ok_or(StoreError::NotFound)?;
        saved
            .pending
            .retain(|pending| !consumed.iter().any(|input| input.id == pending.id));
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

    async fn load(&self, id: SessionId, after: Option<EventNumber>) -> Result<Loaded, StoreError> {
        // One lock covers both reads, so they come from one moment.
        let state = lock(&self.state);
        let saved = state.sessions.get(&id).ok_or(StoreError::NotFound)?;
        // Event number `n` sits at index `n - 1`, so the events after it start at index `n`.
        let after = after.map_or(0, |after| usize::try_from(after.0).unwrap_or(usize::MAX));
        let after = after.min(saved.events.len());
        Ok(Loaded {
            events: saved.events[after..].to_vec(),
            pending: saved.pending.clone(),
        })
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

    /// A session of a folder that is not UTF-8 lists in no folder, as in the SQLite store, which cannot save one.
    #[tokio::test]
    async fn a_session_in_a_folder_that_is_not_utf8_lists_in_no_folder() {
        use std::os::unix::ffi::OsStrExt;
        use std::path::{Path, PathBuf};

        use crate::Store;

        let store = MemoryStore::new();
        let folder = Path::new(std::ffi::OsStr::from_bytes(b"/work\xff"));
        let settings = yuke_protocol::SessionSettings {
            cwd: PathBuf::from(folder),
            ..crate::testing::settings("one")
        };
        store.create_session(&settings, &[]).await.unwrap();

        let page = store.list_sessions(Some(folder), None, 10).await.unwrap();

        assert_eq!(page.sessions, []);
    }
}
