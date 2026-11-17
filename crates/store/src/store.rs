//! [`FileStore`]: the store lock, the session index, the owner locks, and the [`Store`] methods.

use std::collections::HashMap;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use yuke_agent::{
    Access, EventPage, Lease, ListPosition, Loaded, NewestTurn, Opened, PromptSection, SessionPage, Store, StoreError,
    fork_title_of, title_of,
};
use yuke_engine::Commit;
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, PendingInput, SessionEvent, SessionId, SessionSettings, SessionSummary,
    SessionTitle, StoredEvent,
};

use crate::files::{self, SessionLock};
use crate::index::{Added, Index, Line, Meta};
use crate::log;

/// A [`Store`] in a folder: the index `sessions.jsonl`, the store lock, and a folder for each session. One thread runs
/// the calls of this process in order, and the store lock orders the appends to the index between processes.
pub struct FileStore {
    inner: Arc<Inner>,
    /// The queue of the store thread. One thread runs every call in order, so the allocations of the store stay in one
    /// malloc arena.
    jobs: std::sync::mpsc::Sender<Job>,
    owners: Owners,
}

/// A call that the store thread runs.
type Job = Box<dyn FnOnce(&Inner) + Send>;

struct Inner {
    /// The folder of the session folders.
    sessions: PathBuf,
    /// The store lock file: held for each append to the index.
    lock: File,
    /// The index as this process read it last.
    index: Mutex<Index>,
    /// The next event number of each session that a lease of this store wrote. Only the holder of the lease appends.
    next: Mutex<HashMap<SessionId, u64>>,
}

type Owners = Arc<Mutex<HashMap<SessionId, Arc<SessionLock>>>>;

struct Owner {
    id: SessionId,
    owners: Owners,
}

impl Drop for Owner {
    fn drop(&mut self) {
        self.owners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&self.id);
    }
}

impl fmt::Debug for FileStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FileStore")
            .field("sessions", &self.inner.sessions)
            .finish_non_exhaustive()
    }
}

impl Inner {
    fn folder(&self, id: SessionId) -> PathBuf {
        files::session_folder(&self.sessions, id.as_bytes())
    }

    /// The index with the lines that other processes appended.
    fn index(&self) -> Result<MutexGuard<'_, Index>, StoreError> {
        let mut index = self.index.lock().unwrap_or_else(PoisonError::into_inner);
        index.refresh().map_err(failed)?;
        Ok(index)
    }

    /// Run `function` on the newest index while this process holds the store lock.
    fn locked<T>(&self, function: impl FnOnce(&mut Index) -> Result<T, StoreError>) -> Result<T, StoreError> {
        self.lock.lock().map_err(failed)?;
        let result = self.index().and_then(|mut index| function(&mut index));
        if self.lock.unlock().is_err() {
            // The close of the file at the end of the process releases the lock, so nothing is left to do.
        }
        result
    }

    fn set_next(&self, id: SessionId, seq: u64) {
        self.next.lock().unwrap_or_else(PoisonError::into_inner).insert(id, seq);
    }

    fn next_seq(&self, id: SessionId, folder: &Path) -> Result<u64, StoreError> {
        if let Some(&seq) = self.next.lock().unwrap_or_else(PoisonError::into_inner).get(&id) {
            return Ok(seq);
        }
        Ok(log::read(folder).map_err(failed)?.events.len() as u64 + 1)
    }
}

/// The facts of session `id`, or [`StoreError::NotFound`].
fn meta_of(index: &Index, id: SessionId) -> Result<Meta, StoreError> {
    index
        .get(id)
        .map(|entry| entry.meta.clone())
        .ok_or(StoreError::NotFound)
}

/// `Ok` when `folder` holds a log. A step checks only this file, so a step reads no index.
fn ensure_log(folder: &Path) -> Result<(), StoreError> {
    if log::path(folder).is_file() {
        Ok(())
    } else {
        Err(StoreError::NotFound)
    }
}

impl FileStore {
    /// Open the store in `folder`: the index `folder/sessions.jsonl`, the session folders in `folder/sessions/`, and
    /// the store lock `folder/store.lock`. The open makes what is missing and removes the folders of deleted sessions.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Failed`] when a folder does not open.
    pub async fn open(folder: impl AsRef<Path>) -> Result<FileStore, StoreError> {
        let folder = folder.as_ref().to_path_buf();
        let sessions = folder.join("sessions");
        let new_folder = !folder.is_dir();
        let created = new_folder || !sessions.is_dir();
        std::fs::create_dir_all(&sessions).map_err(failed)?;
        let lock = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(folder.join("store.lock"))
            .map_err(failed)?;
        let inner = Arc::new(Inner {
            sessions: sessions.clone(),
            lock,
            index: Mutex::new(Index::new(&folder)),
            next: Mutex::new(HashMap::new()),
        });
        let (jobs, queue) = std::sync::mpsc::channel::<Job>();
        let worker = Arc::clone(&inner);
        std::thread::Builder::new()
            .name("yuke-store".to_owned())
            .spawn(move || {
                for job in queue {
                    job(&worker);
                }
            })
            .map_err(failed)?;
        let store = FileStore {
            inner,
            jobs,
            owners: Owners::default(),
        };
        store.call(move |inner| files::sweep(&inner.sessions)).await?;
        if created {
            files::sync_folder(&folder).map_err(failed)?;
            if new_folder && let Some(parent) = folder.parent().filter(|parent| !parent.as_os_str().is_empty()) {
                files::sync_folder(parent).map_err(failed)?;
            }
        }
        Ok(store)
    }

    /// Run `function` on the store thread, after the calls before it. The call runs also when the caller stops
    /// waiting.
    async fn call<T: Send + 'static>(
        &self,
        function: impl FnOnce(&Inner) -> Result<T, StoreError> + Send + 'static,
    ) -> Result<T, StoreError> {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        self.jobs
            .send(Box::new(move |inner: &Inner| {
                if sender.send(function(inner)).is_err() {
                    // The caller stopped waiting. The call ran, as a call of a stopped caller does.
                }
            }))
            .map_err(|_| failed("the store thread stopped"))?;
        receiver.await.map_err(failed)?
    }

    fn folder(&self, id: SessionId) -> PathBuf {
        self.inner.folder(id)
    }

    fn owner(&self, id: SessionId) -> Option<Arc<SessionLock>> {
        self.owners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .cloned()
    }

    fn lease(&self, id: SessionId, lock: SessionLock) -> Lease {
        self.owners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, Arc::new(lock));
        Lease::new(Owner {
            id,
            owners: Arc::clone(&self.owners),
        })
    }
}

/// Make the session folder `folder` with its lock and log, then add `meta` to the index durably. On an error, the
/// folder goes again. The lock keeps the sweep of another process away until the index has the session.
fn make_session(
    inner: &Inner,
    id: SessionId,
    folder: &Path,
    write_folder: impl FnOnce() -> std::io::Result<()>,
    meta: Meta,
) -> Result<SessionLock, StoreError> {
    let lock = files::take_lock(folder)?;
    let made = files::sync_folder(&inner.sessions)
        .and_then(|()| write_folder())
        .map_err(failed)
        .and_then(|()| {
            inner.locked(|index| {
                let meta = Meta {
                    position: index.next_position(),
                    ..meta
                };
                index.append(Line::meta(id, meta), true).map_err(failed)
            })
        });
    match made {
        Ok(()) => Ok(lock),
        Err(error) => {
            drop(lock);
            files::remove_session_folder(folder).map_err(failed)?;
            Err(error)
        }
    }
}

#[async_trait]
impl Store for FileStore {
    async fn create_session(
        &self,
        settings: &SessionSettings,
        prompt: &[PromptSection],
        parent: Option<SessionId>,
    ) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let folder = self.folder(id);
        let line = log::line(1, &log::settings_body(settings, Some(prompt)).map_err(failed)?);
        let meta = Meta {
            model: settings.model.clone(),
            cwd: settings.cwd.clone(),
            title: None,
            fork_of: None,
            parent,
            position: 0,
            next_input: 1,
        };

        let lock = self
            .call(move |inner| make_session(inner, id, &folder, || log::append(&folder, &line, true), meta))
            .await?;
        self.inner.set_next(id, 2);

        Ok(Opened {
            id,
            settings: settings.clone(),
            prompt: prompt.to_vec(),
            parent,
            context: Vec::new(),
            newest_turn: NewestTurn::Empty,
            input_tokens: None,
            lease: Some(self.lease(id, lock)),
        })
    }

    async fn fork_session(&self, source: SessionId, through: Option<EventNumber>) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let source_folder = self.folder(source);
        let folder = self.folder(id);

        let (opened, lock, cut) = self
            .call(move |inner| {
                let source_meta = meta_of(&*inner.index()?, source)?;
                let title = source_meta
                    .title
                    .as_deref()
                    .and_then(fork_title_of)
                    .map(|title| title.to_string());
                let source_log = log::read(&source_folder).map_err(failed)?;
                let cut = match through {
                    Some(EventNumber(through)) if source_log.ends_completed_turn(through) => through,
                    Some(_) => return Err(StoreError::NotACompletedTurn),
                    None => source_log.fork_cut(),
                };
                let settings = settings_of(&source_log, cut)?;
                let meta = Meta {
                    model: settings.model.clone(),
                    cwd: settings.cwd.clone(),
                    title,
                    fork_of: Some(source),
                    parent: None,
                    position: 0,
                    next_input: 1,
                };
                // The blobs come before the log, so a reader finds every blob that a copied event names. The first
                // copied line holds the prompt.
                let lock = make_session(
                    inner,
                    id,
                    &folder,
                    || {
                        files::copy_blobs(&source_folder, &folder)
                            .and_then(|()| log::copy_prefix(&source_folder, &folder, source_log.prefix_len(cut)))
                    },
                    meta,
                )?;
                let events =
                    &source_log.events[..usize::try_from(cut).unwrap_or(usize::MAX).min(source_log.events.len())];
                let (context, newest_turn, input_tokens) = log::replay(events);
                Ok((
                    Opened {
                        id,
                        settings,
                        prompt: source_log.prompt,
                        parent: None,
                        context,
                        newest_turn,
                        input_tokens,
                        lease: None,
                    },
                    lock,
                    cut,
                ))
            })
            .await?;
        self.inner.set_next(id, cut + 1);
        Ok(Opened {
            lease: Some(self.lease(id, lock)),
            ..opened
        })
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<EventNumber, StoreError> {
        let owner = self.owner(id);
        let folder = self.folder(id);
        let body = log::settings_body(settings, None).map_err(failed)?;
        let settings = settings.clone();

        self.call(move |inner| {
            let saved = inner.locked(|index| {
                let mut meta = meta_of(index, id)?;
                let seq = inner.next_seq(id, &folder)?;
                let before = log::len(&folder).map_err(failed)?;
                log::append(&folder, &log::line(seq, &body), true).map_err(failed)?;
                meta.model = settings.model;
                meta.cwd = settings.cwd;
                meta.position = index.next_position();
                if let Err(error) = index.append(Line::meta(id, meta), false) {
                    log::truncate(&folder, before).map_err(failed)?;
                    return Err(failed(error));
                }
                inner.set_next(id, seq + 1);
                Ok(EventNumber(seq))
            });
            drop(owner);
            saved
        })
        .await
    }

    async fn rename_session(&self, id: SessionId, title: &SessionTitle) -> Result<(), StoreError> {
        let title = title.to_string();
        self.call(move |inner| {
            inner.locked(|index| {
                let mut meta = meta_of(index, id)?;
                meta.title = Some(title);
                index.append(Line::meta(id, meta), false).map_err(failed)
            })
        })
        .await
    }

    async fn accept_input(&self, id: SessionId, input: Input) -> Result<InputId, StoreError> {
        let title = title_of(&input).map(|title| title.to_string());
        self.call(move |inner| {
            inner.locked(|index| {
                let mut meta = meta_of(index, id)?;
                let input_id = InputId(meta.next_input.max(1));
                meta.next_input = input_id.0 + 1;
                if meta.title.is_none() {
                    meta.title = title;
                }
                // One line saves the input, its id, and the title. No sync: like the NORMAL sync of a database, a
                // power loss can take it back, but no crash of the process.
                let line = Line {
                    add: Some(Added { id: input_id, input }),
                    ..Line::meta(id, meta)
                };
                index.append(line, false).map_err(failed)?;
                Ok(input_id)
            })
        })
        .await
    }

    async fn remove_input(&self, id: SessionId, input: InputId) -> Result<(), StoreError> {
        self.call(move |inner| {
            inner.locked(|index| {
                let entry = index.get(id).ok_or(StoreError::NotFound)?;
                if !entry.pending.iter().any(|pending| pending.id == input) {
                    return Err(StoreError::InputNotPending(input));
                }
                index.append(Line::remove(id, vec![input]), false).map_err(failed)
            })
        })
        .await
    }

    async fn list_sessions(
        &self,
        cwd: Option<&Path>,
        parent: Option<SessionId>,
        after: Option<ListPosition>,
        limit: usize,
    ) -> Result<SessionPage, StoreError> {
        let cwd = cwd.map(Path::to_path_buf);
        let before = after.map_or(u64::MAX, |ListPosition(position)| position);

        self.call(move |inner| {
            let index = inner.index()?;
            // Sort references, and copy only the facts of the page.
            let mut listed: Vec<(&SessionId, &Meta)> = index
                .sessions()
                .iter()
                .map(|(id, entry)| (id, &entry.meta))
                .filter(|(_, meta)| meta.parent == parent && meta.position < before)
                .filter(|(_, meta)| cwd.as_ref().is_none_or(|cwd| meta.cwd == *cwd))
                .collect();
            listed.sort_unstable_by_key(|(_, meta)| std::cmp::Reverse(meta.position));
            let next = if listed.len() > limit {
                listed.truncate(limit);
                listed.last().map(|(_, meta)| ListPosition(meta.position))
            } else {
                None
            };
            Ok(SessionPage {
                sessions: listed
                    .into_iter()
                    .map(|(&id, meta)| summary_of(id, meta))
                    .collect::<Result<_, _>>()?,
                next,
            })
        })
        .await
    }

    async fn session_summary(&self, id: SessionId) -> Result<SessionSummary, StoreError> {
        self.call(move |inner| {
            let index = inner.index()?;
            summary_of(id, &index.get(id).ok_or(StoreError::NotFound)?.meta)
        })
        .await
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        let folder = self.folder(id);

        let (opened, next, lock) = self
            .call(move |inner| {
                let meta = meta_of(&*inner.index()?, id)?;
                // The lock comes before the read, so no other writer appends between the lock and the read.
                let lock = match access {
                    Access::Write => Some(files::take_lock(&folder)?),
                    Access::Read => None,
                };
                let log = log::read(&folder).map_err(failed)?;
                if lock.is_some() {
                    repair(inner, id, &folder, &log)?;
                }
                let (context, newest_turn, input_tokens) = log::replay(&log.events);
                let settings = settings_of(&log, u64::MAX)?;
                let next = log.events.len() as u64 + 1;
                let opened = Opened {
                    id,
                    settings,
                    prompt: log.prompt,
                    parent: meta.parent,
                    context,
                    newest_turn,
                    input_tokens,
                    lease: None,
                };
                Ok((opened, next, lock))
            })
            .await?;
        if lock.is_some() {
            self.inner.set_next(id, next);
        }
        Ok(Opened {
            lease: lock.map(|lock| self.lease(id, lock)),
            ..opened
        })
    }

    async fn commit(
        &self,
        id: SessionId,
        commit: &Commit<'_>,
        consumed: &[ConsumedInput],
    ) -> Result<EventNumber, StoreError> {
        let owner = self.owner(id);
        let folder = self.folder(id);
        let body = log::commit_body(commit, consumed).map_err(failed)?;
        let consumed: Vec<InputId> = consumed.iter().map(|input| input.id).collect();
        // A turn end is durable at once. A step of a turn survives a crash of the process, not a power loss.
        let ends_turn = commit.end.is_some();

        self.call(move |inner| {
            let saved = (|| {
                if consumed.is_empty() && !ends_turn {
                    ensure_log(&folder)?;
                    let seq = inner.next_seq(id, &folder)?;
                    log::append(&folder, &log::line(seq, &body), false).map_err(failed)?;
                    inner.set_next(id, seq + 1);
                    return Ok(EventNumber(seq));
                }
                // A turn start or end also changes the facts and the pending inputs: one line in the log, then one
                // line in the index. A crash between the two leaves consumed inputs that the next lease removes.
                inner.locked(|index| {
                    let entry = index.get(id).ok_or(StoreError::NotFound)?;
                    if let Some(&input) = consumed
                        .iter()
                        .find(|&&input| !entry.pending.iter().any(|pending| pending.id == input))
                    {
                        return Err(StoreError::InputNotPending(input));
                    }
                    let mut meta = entry.meta.clone();
                    let seq = inner.next_seq(id, &folder)?;
                    let before = log::len(&folder).map_err(failed)?;
                    log::append(&folder, &log::line(seq, &body), ends_turn).map_err(failed)?;
                    meta.position = index.next_position();
                    let line = Line {
                        remove: consumed,
                        ..Line::meta(id, meta)
                    };
                    if let Err(error) = index.append(line, false) {
                        log::truncate(&folder, before).map_err(failed)?;
                        return Err(failed(error));
                    }
                    inner.set_next(id, seq + 1);
                    Ok(EventNumber(seq))
                })
            })();
            drop(owner);
            saved
        })
        .await
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        self.call(move |inner| {
            let index = inner.index()?;
            Ok(index.get(id).ok_or(StoreError::NotFound)?.pending.clone())
        })
        .await
    }

    async fn load(&self, id: SessionId, page: EventPage) -> Result<Loaded, StoreError> {
        let folder = self.folder(id);
        self.call(move |inner| {
            // The inputs come before the log. An input that a newer line consumed is no longer pending.
            let pending = inner.index()?.get(id).ok_or(StoreError::NotFound)?.pending.clone();
            let (events, consumed) = log::page(&folder, page, !pending.is_empty()).map_err(failed)?;
            let pending = pending
                .into_iter()
                .filter(|input| !consumed.contains(&input.id))
                .collect();
            Ok(Loaded { events, pending })
        })
        .await
    }

    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, StoreError> {
        let folder = self.folder(id);
        self.call(move |_| {
            ensure_log(&folder)?;
            files::write_blob(&folder, &bytes).map_err(failed)
        })
        .await
    }

    fn read_blob(&self, id: SessionId, digest: &yuke_ai::Digest) -> Result<Option<Vec<u8>>, StoreError> {
        files::read_blob(&self.folder(id), digest)
    }

    async fn delete_session(&self, id: SessionId) -> Result<(), StoreError> {
        let folder = self.folder(id);
        self.call(move |inner| {
            inner.locked(|index| {
                if index.get(id).is_none() {
                    return Err(StoreError::NotFound);
                }
                let lock = files::take_lock(&folder)?;
                index.append(Line::deleted(id), false).map_err(failed)?;
                // Windows does not delete an open file, so the lock closes before the folder goes. The log goes first,
                // so when the removal of the rest fails, the sweep of the next open removes the folder.
                drop(lock);
                std::fs::remove_file(log::path(&folder)).map_err(failed)?;
                files::remove_session_folder(&folder).map_err(failed)
            })
        })
        .await?;
        self.inner
            .next
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&id);
        Ok(())
    }
}

/// The ids of the inputs that the commits of `events` consumed.
fn consumed_ids(events: &[StoredEvent]) -> Vec<InputId> {
    events
        .iter()
        .filter_map(|event| match &event.event {
            SessionEvent::Commit(commit) => Some(commit.consumed.iter().map(|input| input.id)),
            SessionEvent::Settings(_) => None,
        })
        .flatten()
        .collect()
}

/// Repair the session in `folder` for a new writer: cut a torn tail of the log, and remove the pending inputs that a
/// line consumed before a crash removed them from the index.
fn repair(inner: &Inner, id: SessionId, folder: &Path, log: &log::Log) -> Result<(), StoreError> {
    if log.torn {
        log::truncate(folder, log.prefix_len(u64::MAX)).map_err(failed)?;
    }
    let consumed = consumed_ids(&log.events);
    inner.locked(|index| {
        let stale: Vec<InputId> = index
            .get(id)
            .map(|entry| {
                entry
                    .pending
                    .iter()
                    .map(|input| input.id)
                    .filter(|input| consumed.contains(input))
                    .collect()
            })
            .unwrap_or_default();
        if stale.is_empty() {
            return Ok(());
        }
        index.append(Line::remove(id, stale), false).map_err(failed)
    })
}

/// The newest settings of `log` through event `cut`. The first line of each log is a settings event.
fn settings_of(log: &log::Log, cut: u64) -> Result<SessionSettings, StoreError> {
    log.settings_through(cut)
        .cloned()
        .ok_or_else(|| failed("the log has no settings event"))
}

/// The summary of session `id` from its facts.
fn summary_of(id: SessionId, meta: &Meta) -> Result<SessionSummary, StoreError> {
    let bytes = id.as_bytes();
    Ok(SessionSummary {
        session_id: id,
        model: meta.model.clone(),
        cwd: meta.cwd.clone(),
        title: meta
            .title
            .as_deref()
            .map(SessionTitle::new)
            .transpose()
            .map_err(failed)?,
        // A version 7 id starts with the millisecond of its creation, and the list position is the microsecond of the
        // newest activity, so the index stores neither time.
        created_at: u64::from_be_bytes([0, 0, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]]),
        updated_at: meta.position / 1000,
        fork_of: meta.fork_of,
        parent: meta.parent,
    })
}

pub(crate) fn failed(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> StoreError {
    StoreError::Failed(error.into())
}
