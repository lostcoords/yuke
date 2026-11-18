//! [`FileStore`]: the store thread, the session index, the owner locks, and the [`Store`] methods.

use std::collections::HashMap;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};

use async_trait::async_trait;
use yuke_agent::{
    Access, EventPage, Lease, ListPosition, Loaded, NewestTurn, Opened, PromptSection, SessionPage, Store, StoreError,
    fork_title_of, title_of,
};
use yuke_engine::Commit;
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, PendingInput, SessionEvent, SessionId, SessionSettings, SessionSummary,
    SessionTitle,
};

use crate::failed;
use crate::files::{self, SessionLock};
use crate::index::{Added, Index, Line, Meta};
use crate::log;

/// A [`Store`] in a folder: the index `sessions.jsonl`, the store lock, and a folder for each session.
pub struct FileStore {
    /// The folder of the session folders.
    sessions: PathBuf,
    /// The queue of the store thread. The store lock orders the processes, and the thread orders the calls of this
    /// process: a file lock does not keep apart two threads that share its file.
    jobs: std::sync::mpsc::Sender<Job>,
    /// The writer of each session that a lease of this store holds.
    writers: Mutex<HashMap<SessionId, Weak<Writer>>>,
}

/// A call that the store thread runs.
type Job = Box<dyn FnOnce(&mut State) + Send>;

/// What the store thread owns.
struct State {
    /// The folder of the session folders.
    sessions: PathBuf,
    /// The store lock file: held for each append to the index.
    lock: File,
    /// The index as this process read it last.
    index: Index,
}

/// The owner lock of a session and the number of its next event. The lease and each call that the lease started hold
/// it, so the lock stays until the last write ends.
struct Writer {
    #[expect(dead_code, reason = "only the drop of the lock matters: it releases the session")]
    lock: SessionLock,
    next: AtomicU64,
}

impl fmt::Debug for FileStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FileStore")
            .field("sessions", &self.sessions)
            .finish_non_exhaustive()
    }
}

impl State {
    /// The index with the lines that other processes appended.
    fn index(&mut self) -> Result<&mut Index, StoreError> {
        self.index.refresh().map_err(failed)?;
        Ok(&mut self.index)
    }

    /// Run `function` on the newest index while this process holds the store lock.
    fn locked<T>(&mut self, function: impl FnOnce(&mut Index) -> Result<T, StoreError>) -> Result<T, StoreError> {
        self.lock.lock().map_err(failed)?;
        let result = self.index().and_then(function);
        if self.lock.unlock().is_err() {
            // The close of the file at the end of the process releases the lock, so nothing is left to do.
        }
        result
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

/// The number of the next event of the session in `folder`. The writer of a lease counts it. A call without a lease
/// counts the lines of the log.
fn next_event_number(writer: Option<&Writer>, folder: &Path) -> Result<u64, StoreError> {
    match writer {
        Some(writer) => Ok(writer.next.load(Ordering::Relaxed)),
        None => Ok(log::read(folder).map_err(failed)?.events.len() as u64 + 1),
    }
}

impl FileStore {
    /// Open the store in `folder`: the index `folder/sessions.jsonl`, the session folders in `folder/sessions/`, and
    /// the store lock `folder/store.lock`. The open makes what is missing and removes the folders that a crash left
    /// without a log.
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
        let mut state = State {
            sessions: sessions.clone(),
            lock,
            index: Index::new(&folder),
        };
        let (jobs, queue) = std::sync::mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("yuke-store".to_owned())
            .spawn(move || {
                for job in queue {
                    job(&mut state);
                }
            })
            .map_err(failed)?;
        let store = FileStore {
            sessions,
            jobs,
            writers: Mutex::default(),
        };
        store
            .call(|state| {
                let sessions = state.sessions.clone();
                state.locked(|index| files::sweep(&sessions, |id| index.get(SessionId::from_bytes(id)).is_some()))
            })
            .await?;
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
        function: impl FnOnce(&mut State) -> Result<T, StoreError> + Send + 'static,
    ) -> Result<T, StoreError> {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        self.jobs
            .send(Box::new(move |state: &mut State| {
                if sender.send(function(state)).is_err() {
                    // The caller stopped waiting. The call ran, as a call of a stopped caller does.
                }
            }))
            .map_err(|_| failed("the store thread stopped"))?;
        receiver.await.map_err(failed)?
    }

    fn folder(&self, id: SessionId) -> PathBuf {
        files::session_folder(&self.sessions, id.as_bytes())
    }

    /// The writer of session `id` while a lease of this store holds it.
    fn writer(&self, id: SessionId) -> Option<Arc<Writer>> {
        self.writers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .and_then(Weak::upgrade)
    }

    /// A lease of session `id` that holds `lock`, with `next` as the number of the next event.
    fn lease(&self, id: SessionId, lock: SessionLock, next: u64) -> Lease {
        let writer = Arc::new(Writer {
            lock,
            next: AtomicU64::new(next),
        });
        let mut writers = self.writers.lock().unwrap_or_else(PoisonError::into_inner);
        // The drop of a lease leaves its entry. Each new lease removes such entries.
        writers.retain(|_, writer| writer.strong_count() > 0);
        writers.insert(id, Arc::downgrade(&writer));
        Lease::new(writer)
    }
}

/// Make the session folder `folder` with its lock and log, then add `meta` to the index durably. On an error, the
/// folder goes again. The lock keeps the sweep of another process away until the folder has its log.
fn make_session(
    state: &mut State,
    id: SessionId,
    folder: &Path,
    write_folder: impl FnOnce() -> std::io::Result<()>,
    meta: Meta,
) -> Result<SessionLock, StoreError> {
    let lock = files::take_lock(folder)?;
    let made = files::sync_folder(&state.sessions)
        .and_then(|()| write_folder())
        .map_err(failed)
        .and_then(|()| {
            state.locked(|index| {
                let meta = Meta {
                    position: index.next_position(),
                    ..meta
                };
                let line = Line {
                    meta: Some(meta),
                    ..Line::new(id)
                };
                index.append(line, true).map_err(failed)
            })
        });
    match made {
        Ok(()) => Ok(lock),
        Err(error) => {
            drop(lock);
            if files::remove_session_folder(folder).is_err() {
                // The error of the make tells the cause, so it wins over the error of the removal.
            }
            Err(error)
        }
    }
}

/// Append `body` as the next event of the session in `folder`, then `line` with a new list position in its facts.
/// When `line` does not save, the log line goes again. The caller holds the store lock.
fn write_event(
    index: &mut Index,
    folder: &Path,
    writer: Option<&Writer>,
    body: &[u8],
    durable: bool,
    mut line: Line,
) -> Result<EventNumber, StoreError> {
    let number = next_event_number(writer, folder)?;
    let before = log::len(folder).map_err(failed)?;
    log::append(folder, &log::line(number, body), durable).map_err(failed)?;
    if let Some(meta) = &mut line.meta {
        meta.position = index.next_position();
    }
    let saved = index.append(line, false);
    // When the cut fails too, the line stays in the log, so the next event takes the number after it. The error of
    // the index tells the cause.
    let kept = saved.is_ok() || log::truncate(folder, before).is_err();
    if kept && let Some(writer) = writer {
        writer.next.store(number + 1, Ordering::Relaxed);
    }
    saved.map_err(failed)?;
    Ok(EventNumber(number))
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
        };

        let lock = self
            .call(move |state| make_session(state, id, &folder, || log::append(&folder, &line, true), meta))
            .await?;

        Ok(Opened {
            id,
            settings: settings.clone(),
            prompt: prompt.to_vec(),
            parent,
            context: Vec::new(),
            newest_turn: NewestTurn::Empty,
            input_tokens: None,
            lease: Some(self.lease(id, lock, 2)),
        })
    }

    async fn fork_session(&self, source: SessionId, through: Option<EventNumber>) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let source_folder = self.folder(source);
        let folder = self.folder(id);

        let (opened, lock, cut) = self
            .call(move |state| {
                let source_meta = meta_of(state.index()?, source)?;
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
                };
                // The blobs come before the log, so a reader finds every blob that a copied event names. The first
                // copied line holds the prompt.
                let lock = make_session(
                    state,
                    id,
                    &folder,
                    || {
                        files::copy_blobs(&source_folder, &folder)
                            .and_then(|()| log::copy_prefix(&source_folder, &folder, source_log.prefix_len(cut)))
                    },
                    meta,
                )?;
                let (context, newest_turn, input_tokens) = log::replay(source_log.through(cut));
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
        Ok(Opened {
            lease: Some(self.lease(id, lock, cut + 1)),
            ..opened
        })
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<EventNumber, StoreError> {
        let writer = self.writer(id);
        let folder = self.folder(id);
        let body = log::settings_body(settings, None).map_err(failed)?;
        let settings = settings.clone();

        self.call(move |state| {
            state.locked(|index| {
                let mut meta = meta_of(index, id)?;
                meta.model = settings.model;
                meta.cwd = settings.cwd;
                let line = Line {
                    meta: Some(meta),
                    ..Line::new(id)
                };
                write_event(index, &folder, writer.as_deref(), &body, true, line)
            })
        })
        .await
    }

    async fn rename_session(&self, id: SessionId, title: &SessionTitle) -> Result<(), StoreError> {
        let title = title.to_string();
        self.call(move |state| {
            state.locked(|index| {
                let mut meta = meta_of(index, id)?;
                meta.title = Some(title);
                let line = Line {
                    meta: Some(meta),
                    ..Line::new(id)
                };
                index.append(line, false).map_err(failed)
            })
        })
        .await
    }

    async fn accept_input(&self, id: SessionId, input: Input) -> Result<InputId, StoreError> {
        let title = title_of(&input).map(|title| title.to_string());
        self.call(move |state| {
            state.locked(|index| {
                let entry = index.get(id).ok_or(StoreError::NotFound)?;
                let input_id = entry.next_input;
                // The first input with a title names the session.
                let meta = match (&entry.meta.title, title) {
                    (None, Some(title)) => Some(Meta {
                        title: Some(title),
                        ..entry.meta.clone()
                    }),
                    _ => None,
                };
                // One line saves the input, its id, and the title. No sync: like the NORMAL sync of a database, a
                // power loss can take it back, but no crash of the process.
                let line = Line {
                    meta,
                    add: Some(Added { id: input_id, input }),
                    ..Line::new(id)
                };
                index.append(line, false).map_err(failed)?;
                Ok(input_id)
            })
        })
        .await
    }

    async fn remove_input(&self, id: SessionId, input: InputId) -> Result<(), StoreError> {
        self.call(move |state| {
            state.locked(|index| {
                let entry = index.get(id).ok_or(StoreError::NotFound)?;
                if !entry.pending.iter().any(|pending| pending.id == input) {
                    return Err(StoreError::InputNotPending(input));
                }
                let line = Line {
                    remove: vec![input],
                    ..Line::new(id)
                };
                index.append(line, false).map_err(failed)
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

        self.call(move |state| {
            let index = state.index()?;
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
        self.call(move |state| summary_of(id, &state.index()?.get(id).ok_or(StoreError::NotFound)?.meta))
            .await
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        let folder = self.folder(id);

        let (opened, lock, next) = self
            .call(move |state| {
                let parent = meta_of(state.index()?, id)?.parent;
                // The lock comes before the read, so no other writer appends between the lock and the read.
                let lock = match access {
                    Access::Write => Some(files::take_lock(&folder)?),
                    Access::Read => None,
                };
                let log = log::read(&folder).map_err(failed)?;
                if lock.is_some() {
                    // A crash can leave a torn line after the last event, and inputs in the index that an event
                    // consumed. The new writer removes both.
                    let complete = log.prefix_len(u64::MAX);
                    if log::len(&folder).map_err(failed)? > complete {
                        log::truncate(&folder, complete).map_err(failed)?;
                    }
                    let consumed: Vec<InputId> = log
                        .events
                        .iter()
                        .filter_map(|event| match &event.event {
                            SessionEvent::Commit(commit) => Some(commit.consumed.iter().map(|input| input.id)),
                            SessionEvent::Settings(_) => None,
                        })
                        .flatten()
                        .collect();
                    state.locked(|index| {
                        let entry = index.get(id).ok_or(StoreError::NotFound)?;
                        let stale: Vec<InputId> = entry
                            .pending
                            .iter()
                            .map(|input| input.id)
                            .filter(|input| consumed.contains(input))
                            .collect();
                        if stale.is_empty() {
                            return Ok(());
                        }
                        let line = Line {
                            remove: stale,
                            ..Line::new(id)
                        };
                        index.append(line, false).map_err(failed)
                    })?;
                }
                let (context, newest_turn, input_tokens) = log::replay(&log.events);
                let opened = Opened {
                    id,
                    settings: settings_of(&log, u64::MAX)?,
                    prompt: log.prompt,
                    parent,
                    context,
                    newest_turn,
                    input_tokens,
                    lease: None,
                };
                Ok((opened, lock, log.events.len() as u64 + 1))
            })
            .await?;
        Ok(Opened {
            lease: lock.map(|lock| self.lease(id, lock, next)),
            ..opened
        })
    }

    async fn commit(
        &self,
        id: SessionId,
        commit: &Commit<'_>,
        consumed: &[ConsumedInput],
    ) -> Result<EventNumber, StoreError> {
        let writer = self.writer(id);
        let folder = self.folder(id);
        let body = log::commit_body(commit, consumed).map_err(failed)?;
        let consumed: Vec<InputId> = consumed.iter().map(|input| input.id).collect();
        // A turn end is durable at once. A step of a turn survives a crash of the process, not a power loss.
        let ends_turn = commit.end.is_some();

        self.call(move |state| {
            let writer = writer.as_deref();
            if consumed.is_empty() && !ends_turn {
                ensure_log(&folder)?;
                let number = next_event_number(writer, &folder)?;
                log::append(&folder, &log::line(number, &body), false).map_err(failed)?;
                if let Some(writer) = writer {
                    writer.next.store(number + 1, Ordering::Relaxed);
                }
                return Ok(EventNumber(number));
            }
            // A turn start or end also changes the facts and the pending inputs: one line in the log, then one line
            // in the index. A crash between the two leaves consumed inputs that the next lease removes.
            state.locked(|index| {
                let entry = index.get(id).ok_or(StoreError::NotFound)?;
                if let Some(&input) = consumed
                    .iter()
                    .find(|&&input| !entry.pending.iter().any(|pending| pending.id == input))
                {
                    return Err(StoreError::InputNotPending(input));
                }
                let line = Line {
                    meta: Some(entry.meta.clone()),
                    remove: consumed,
                    ..Line::new(id)
                };
                write_event(index, &folder, writer, &body, ends_turn, line)
            })
        })
        .await
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        self.call(move |state| Ok(state.index()?.get(id).ok_or(StoreError::NotFound)?.pending.clone()))
            .await
    }

    async fn load(&self, id: SessionId, page: EventPage) -> Result<Loaded, StoreError> {
        let folder = self.folder(id);
        self.call(move |state| {
            // The inputs come before the log. An input that the newest event consumed is no longer pending.
            let pending = state.index()?.get(id).ok_or(StoreError::NotFound)?.pending.clone();
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
        self.call(move |state| {
            state.locked(|index| {
                if index.get(id).is_none() {
                    return Err(StoreError::NotFound);
                }
                let lock = files::take_lock(&folder)?;
                let line = Line {
                    deleted: true,
                    ..Line::new(id)
                };
                index.append(line, false).map_err(failed)?;
                // Windows does not delete an open file, so the lock closes before the folder goes. The log goes first,
                // so when the removal of the rest fails, the sweep of the next open removes the folder.
                drop(lock);
                match std::fs::remove_file(log::path(&folder)) {
                    Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(failed(error)),
                    _ => {}
                }
                files::remove_session_folder(&folder).map_err(failed)
            })
        })
        .await
    }
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
