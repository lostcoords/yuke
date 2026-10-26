//! [`SqliteStore`]: the connection, the owner locks, and the [`Store`] methods.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use yuke_agent::{
    Access, EventPage, Lease, ListPosition, Loaded, NewestTurn, Opened, PromptSection, SessionPage, Store, StoreError,
    check_consumed_blocks, preview_of,
};
use yuke_engine::{Commit, Outcome, TurnEnd};
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, PendingInput, SessionId, SessionSettings, SessionSummary,
};
use yuke_sql::rusqlite::{self, Connection, TransactionBehavior};

use crate::context;
use crate::event;
use crate::files::{self, SessionLock};
use crate::queries::{events, pending_inputs, sessions};
use crate::schema;

/// A [`Store`] in one SQLite file. One connection runs every read and write in call order on its own thread.
pub struct SqliteStore {
    connection: tokio_rusqlite::Connection,
    /// The folder of the session folders.
    sessions: PathBuf,
    owners: Owners,
}

/// The lock of each session that a lease of this store holds. Each write holds a clone, so the lock stays held until
/// the write ends, also when the lease drops while the write waits in the queue of the connection. Each change of the
/// map is one call, so the map stays valid after a panic of another holder of the mutex.
type Owners = Arc<Mutex<HashMap<SessionId, Arc<SessionLock>>>>;

/// The guard of a [`Lease`]. Its drop removes the lock from the owners, and the last clone of the lock releases it.
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

impl fmt::Debug for SqliteStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SqliteStore")
            .field("sessions", &self.sessions)
            .finish_non_exhaustive()
    }
}

impl SqliteStore {
    /// Open the store in `folder`. The store keeps the database `yuke.db` and a folder for each session in `sessions/`.
    /// The open makes what is missing, runs the missing migrations, and removes the folders of deleted sessions.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Failed`] when a folder or the database does not open, or a migration fails. It also
    /// returns it when the schema version of the database is above the versions that this yuke knows.
    pub async fn open(folder: impl AsRef<Path>) -> Result<SqliteStore, StoreError> {
        let folder = folder.as_ref();
        let sessions = folder.join("sessions");
        let database = folder.join("yuke.db");
        // A sync costs milliseconds on macOS, so only an open that makes an entry syncs.
        let new_folder = !folder.is_dir();
        let created = new_folder || !sessions.is_dir() || !database.exists();
        std::fs::create_dir_all(&sessions).map_err(failed)?;

        let connection = tokio_rusqlite::Connection::open(&database).await.map_err(failed)?;

        let store = SqliteStore {
            connection,
            sessions: sessions.clone(),
            owners: Owners::default(),
        };
        store
            .call(move |connection| {
                schema::prepare(connection).map_err(failed)?;
                files::sweep(connection, &sessions)
            })
            .await?;
        if created {
            files::sync_folder(folder).map_err(failed)?;
            if new_folder && let Some(parent) = folder.parent().filter(|parent| !parent.as_os_str().is_empty()) {
                files::sync_folder(parent).map_err(failed)?;
            }
        }

        Ok(store)
    }

    /// Run `function` on the thread of the connection.
    async fn call<T: Send + 'static>(
        &self,
        function: impl FnOnce(&mut Connection) -> Result<T, StoreError> + Send + 'static,
    ) -> Result<T, StoreError> {
        self.connection.call(function).await.map_err(|error| match error {
            tokio_rusqlite::Error::Error(error) => error,
            error => failed(error),
        })
    }

    /// The folder of session `id`.
    fn folder(&self, id: SessionId) -> PathBuf {
        files::session_folder(&self.sessions, id.as_bytes())
    }

    /// The lock that a lease of this store holds for session `id`.
    fn owner(&self, id: SessionId) -> Option<Arc<SessionLock>> {
        self.owners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .cloned()
    }

    /// The lease of `lock`, the lock of session `id`.
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

#[async_trait]
impl Store for SqliteStore {
    async fn create_session(&self, settings: &SessionSettings, prompt: &[PromptSection]) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let folder = self.folder(id);
        let sessions_folder = self.sessions.clone();
        let session = *id.as_bytes();
        let settings_json = serde_json::to_string(settings).map_err(failed)?;
        let params = sessions::InsertSessionParams {
            id: session,
            prompt: serde_json::to_string(prompt).map_err(failed)?,
            settings: settings_json.clone(),
        };

        let lock = self
            .call(move |connection| {
                // No other process knows the new id yet, so the rows can come first. Then each folder that the sweep
                // finds for a live session has its row.
                insert_session(connection, &params, settings_json).map_err(failed)?;
                let locked = files::take_lock(&folder).and_then(|lock| {
                    // A crash must not lose the entry of the new folder, so the call syncs the folder that holds it.
                    files::sync_folder(&sessions_folder).map_err(failed)?;
                    Ok(lock)
                });
                // The caller never learns the id of a failed creation, so nothing else can open or delete it.
                locked.or_else(|error| {
                    delete_new_session(connection, session, &folder)?;
                    Err(error)
                })
            })
            .await?;

        Ok(Opened {
            id,
            settings: settings.clone(),
            prompt: prompt.to_vec(),
            context: Vec::new(),
            newest_turn: NewestTurn::Empty,
            input_tokens: None,
            lease: Some(self.lease(id, lock)),
        })
    }

    async fn fork_session(&self, source: SessionId, through: Option<EventNumber>) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let fork = *id.as_bytes();
        let source_bytes = *source.as_bytes();
        let source_folder = self.folder(source);
        let folder = self.folder(id);
        let sessions_folder = self.sessions.clone();

        // The copy of the blobs runs on the thread of the connection, as a put does. Forks are rare.
        let (opened, lock) = self
            .call(move |connection| {
                let rows = events::CopyEventsParams {
                    source: source_bytes,
                    session_id: fork,
                    cut: fork_point(connection, source_bytes, through)?,
                };
                // The blobs come before the rows, so a fork that a reader finds has each of its blobs. The lock of the
                // new folder keeps the sweep away from the folder until the rows exist.
                let forked = files::take_lock(&folder).and_then(|lock| {
                    // A crash must not lose the new folder entry. The fork syncs its parent folder.
                    files::sync_folder(&sessions_folder).map_err(failed)?;
                    files::copy_blobs(&source_folder, &folder).map_err(failed)?;
                    copy_rows(connection, &rows)?;
                    let opened = read(connection, |connection| context::load(connection, id).map_err(failed))?;
                    Ok((opened.ok_or(StoreError::NotFound)?, lock))
                });
                // The caller never learns the id of a failed fork, so nothing else can open or delete it.
                forked.or_else(|error| {
                    delete_new_session(connection, fork, &folder)?;
                    Err(error)
                })
            })
            .await?;

        Ok(Opened {
            lease: Some(self.lease(id, lock)),
            ..opened
        })
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<EventNumber, StoreError> {
        let owner = self.owner(id);
        let session = *id.as_bytes();
        let settings_json = serde_json::to_string(settings).map_err(failed)?;

        self.call(move |connection| {
            let saved = save_settings(connection, session, settings_json);
            drop(owner);
            saved
        })
        .await
    }

    async fn accept_input(&self, id: SessionId, input: Input) -> Result<InputId, StoreError> {
        let params = pending_inputs::InsertPendingInputParams {
            session_id: *id.as_bytes(),
            input: serde_json::to_string(&input).map_err(failed)?,
        };
        let preview = preview_of(&input);

        self.call(move |connection| {
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(failed)?;
            let id = pending_inputs::insert_pending_input(&transaction, &params)
                .opt()
                .map_err(failed)?
                .ok_or(StoreError::NotFound)?;
            if let Some(preview) = &preview {
                let preview = sessions::SetPreviewParams {
                    id: params.session_id,
                    preview,
                };
                sessions::set_preview(&transaction, &preview).map_err(failed)?;
            }
            transaction.commit().map_err(failed)?;
            Ok(InputId(id))
        })
        .await
    }

    async fn remove_input(&self, id: SessionId, input: InputId) -> Result<(), StoreError> {
        let params = pending_inputs::DeletePendingInputParams {
            session_id: *id.as_bytes(),
            id: input.0,
        };

        self.call(move |connection| {
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(failed)?;
            if pending_inputs::delete_pending_input(&transaction, &params).map_err(failed)? == 0 {
                // No row: the session is unknown, or the input is not pending.
                ensure_session(&transaction, params.session_id)?;
                return Err(StoreError::InputNotPending(input));
            }
            transaction.commit().map_err(failed)
        })
        .await
    }

    async fn list_sessions(
        &self,
        cwd: Option<&Path>,
        after: Option<ListPosition>,
        limit: usize,
    ) -> Result<SessionPage, StoreError> {
        let cwd = match cwd.map(Path::to_str) {
            None => None,
            Some(Some(cwd)) => Some(cwd.to_owned()),
            // The settings save `cwd` as JSON text, which holds only UTF-8, so no session works in another folder.
            Some(None) => {
                return Ok(SessionPage {
                    sessions: Vec::new(),
                    next: None,
                });
            }
        };
        // No event id reaches `i64::MAX`, so a larger position starts at the newest session too.
        let before = after.map_or(i64::MAX, |ListPosition(position)| {
            i64::try_from(position).unwrap_or(i64::MAX)
        });
        // One row more than the page tells whether an older session exists.
        let rows = limit.saturating_add(1);

        let mut listed = self
            .call(move |connection| {
                let listed: Vec<(SessionSummary, i64)> = match &cwd {
                    None => sessions::list_sessions(connection, &sessions::ListSessionsParams { before, limit: rows })
                        .all()
                        .map_err(failed)?
                        .into_iter()
                        .map(|row| {
                            let summary = summary_of(
                                row.id,
                                row.settings,
                                row.preview,
                                row.fork_of,
                                row.created_at,
                                row.updated_at,
                            );
                            (summary, row.newest_event)
                        })
                        .collect(),
                    Some(cwd) => {
                        let params = sessions::ListSessionsInParams {
                            cwd,
                            before,
                            limit: rows,
                        };
                        sessions::list_sessions_in(connection, &params)
                            .all()
                            .map_err(failed)?
                            .into_iter()
                            .map(|row| {
                                let summary = summary_of(
                                    row.id,
                                    row.settings,
                                    row.preview,
                                    row.fork_of,
                                    row.created_at,
                                    row.updated_at,
                                );
                                (summary, row.newest_event)
                            })
                            .collect()
                    }
                };
                Ok(listed)
            })
            .await?;

        let next = if listed.len() > limit {
            listed.truncate(limit);
            listed
                .last()
                .map(|(_, newest_event)| ListPosition(newest_event.unsigned_abs()))
        } else {
            None
        };
        Ok(SessionPage {
            sessions: listed.into_iter().map(|(summary, _)| summary).collect(),
            next,
        })
    }

    async fn session_summary(&self, id: SessionId) -> Result<SessionSummary, StoreError> {
        let session = *id.as_bytes();
        let row = self
            .call(move |connection| sessions::session_summary(connection, session).opt().map_err(failed))
            .await?
            .ok_or(StoreError::NotFound)?;
        Ok(summary_of(
            row.id,
            row.settings,
            row.preview,
            row.fork_of,
            row.created_at,
            row.updated_at,
        ))
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        let folder = match access {
            Access::Read => None,
            Access::Write => Some(self.folder(id)),
        };
        let session = *id.as_bytes();

        let (opened, lock) = self
            .call(move |connection| {
                // The lock comes before the load, so no other writer commits between the lock and the load.
                let lock = match folder {
                    Some(folder) => {
                        ensure_session(connection, session)?;
                        Some(files::take_lock(&folder)?)
                    }
                    None => None,
                };

                let opened = read(connection, |connection| context::load(connection, id).map_err(failed))?;
                Ok((opened.ok_or(StoreError::NotFound)?, lock))
            })
            .await?;

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
        check_consumed_blocks(commit, consumed)?;
        let owner = self.owner(id);
        let params = commit_params(id, commit, consumed).map_err(failed)?;
        let consumed: Vec<InputId> = consumed.iter().map(|input| input.id).collect();

        self.call(move |connection| {
            let saved = save_commit(connection, &params, &consumed);
            drop(owner);
            saved
        })
        .await
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        let session = *id.as_bytes();

        let rows = self
            .call(move |connection| {
                read(connection, |connection| {
                    ensure_session(connection, session)?;
                    pending_inputs::pending_inputs(connection, session)
                        .all()
                        .map_err(failed)
                })
            })
            .await?;

        Ok(rows.into_iter().map(PendingInput::from).collect())
    }

    async fn load(&self, id: SessionId, page: EventPage) -> Result<Loaded, StoreError> {
        let session_id = *id.as_bytes();
        let seq = |number: EventNumber| number.0.min(LARGEST_SEQ);
        let params = match page {
            EventPage::After(after) => events::EventsPageParams {
                session_id,
                after: after.map_or(0, seq),
                before: LARGEST_SEQ,
                limit: -1,
            },
            EventPage::Before { before, limit } => events::EventsPageParams {
                session_id,
                after: 0,
                before: before.map_or(LARGEST_SEQ, seq),
                limit: i64::try_from(limit).unwrap_or(i64::MAX),
            },
        };

        // One read transaction gives both, so they come from one moment.
        let (events, pending) = self
            .call(move |connection| {
                read(connection, |connection| {
                    ensure_session(connection, params.session_id)?;
                    let events = events::events_page(connection, &params).all().map_err(failed)?;
                    let pending = pending_inputs::pending_inputs(connection, params.session_id)
                        .all()
                        .map_err(failed)?;
                    Ok((events, pending))
                })
            })
            .await?;

        Ok(Loaded {
            events: events.into_iter().map(event::stored_event).collect::<Result<_, _>>()?,
            pending: pending.into_iter().map(PendingInput::from).collect(),
        })
    }

    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, StoreError> {
        let session = *id.as_bytes();
        let folder = self.folder(id);

        // The write runs on the thread of the connection, and the calls behind it wait. Puts are rare, and this keeps
        // the caller's task free of blocking work.
        self.call(move |connection| {
            ensure_session(connection, session)?;
            files::write_blob(&folder, &bytes).map_err(failed)
        })
        .await
    }

    fn read_blob(&self, id: SessionId, digest: &yuke_ai::Digest) -> Result<Option<Vec<u8>>, StoreError> {
        files::read_blob(&self.folder(id), digest)
    }

    async fn delete_session(&self, id: SessionId) -> Result<(), StoreError> {
        let session = *id.as_bytes();
        let folder = self.folder(id);

        self.call(move |connection| {
            ensure_session(connection, session)?;
            let lock = files::take_lock(&folder)?;
            sessions::delete_session(connection, session).map_err(failed)?;

            // Windows does not delete an open file, so the lock closes before the folder goes. When the removal
            // fails, the rows are already gone, and the sweep of the next open removes the folder.
            drop(lock);
            files::remove_session_folder(&folder).map_err(failed)
        })
        .await
    }
}

/// The largest event number that SQLite can hold. A larger number names no event.
const LARGEST_SEQ: u64 = i64::MAX.unsigned_abs();

/// Run `function` in a read transaction, so each of its queries reads the same state.
fn read<T>(
    connection: &mut Connection,
    function: impl FnOnce(&Connection) -> Result<T, StoreError>,
) -> Result<T, StoreError> {
    let transaction = connection.transaction().map_err(failed)?;
    let value = function(&transaction)?;
    transaction.commit().map_err(failed)?;
    Ok(value)
}

/// Save a new session row and its first event, which holds its settings, in one transaction.
fn insert_session(
    connection: &mut Connection,
    session: &sessions::InsertSessionParams,
    settings: String,
) -> rusqlite::Result<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    sessions::insert_session(&transaction, session)?;
    let params = events::InsertSettingsParams {
        session_id: session.id,
        settings,
    };
    events::insert_settings(&transaction, &params).one()?;
    sessions::touch_session(&transaction, session.id)?;
    transaction.commit()
}

/// Save a settings event in one transaction. Returns [`StoreError::NotFound`] for an unknown session.
fn save_settings(connection: &mut Connection, session: [u8; 16], settings: String) -> Result<EventNumber, StoreError> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(failed)?;
    let seq = events::insert_settings(
        &transaction,
        &events::InsertSettingsParams {
            session_id: session,
            settings: settings.clone(),
        },
    )
    .opt()
    .map_err(failed)?
    .ok_or(StoreError::NotFound)?;
    let params = sessions::SetSessionSettingsParams { id: session, settings };
    sessions::set_session_settings(&transaction, &params).map_err(failed)?;
    sessions::touch_session(&transaction, session).map_err(failed)?;
    transaction.commit().map_err(failed)?;
    Ok(EventNumber(seq))
}

/// Save the commit event and remove the consumed inputs in one transaction. Returns [`StoreError::NotFound`] for an
/// unknown session, and [`StoreError::InputNotPending`] for a consumed input that is not pending. A failure saves
/// nothing.
fn save_commit(
    connection: &mut Connection,
    params: &events::InsertCommitParams,
    consumed: &[InputId],
) -> Result<EventNumber, StoreError> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(failed)?;
    let seq = events::insert_commit(&transaction, params)
        .opt()
        .map_err(failed)?
        .ok_or(StoreError::NotFound)?;

    for &input in consumed {
        let params = pending_inputs::DeletePendingInputParams {
            session_id: params.session_id,
            id: input.0,
        };
        // A drop of the transaction rolls it back, so the error saves nothing.
        if pending_inputs::delete_pending_input(&transaction, &params).map_err(failed)? == 0 {
            return Err(StoreError::InputNotPending(input));
        }
    }

    sessions::touch_session(&transaction, params.session_id).map_err(failed)?;
    transaction.commit().map_err(failed)?;
    Ok(EventNumber(seq))
}

/// The newest event of session `source` that a fork copies: event `through`, which must end a completed turn, or the
/// cut that `fork_cut` gives.
fn fork_point(connection: &mut Connection, source: [u8; 16], through: Option<EventNumber>) -> Result<u64, StoreError> {
    let transaction = connection.transaction().map_err(failed)?;
    let cut = match through {
        Some(EventNumber(through)) => {
            ensure_session(&transaction, source)?;
            if through > LARGEST_SEQ {
                return Err(StoreError::NotACompletedTurn);
            }
            let params = events::EndsCompletedTurnParams {
                session_id: source,
                seq: through,
            };
            if !events::ends_completed_turn(&transaction, &params)
                .one()
                .map_err(failed)?
            {
                return Err(StoreError::NotACompletedTurn);
            }
            through
        }
        None => events::fork_cut(&transaction, source)
            .opt()
            .map_err(failed)?
            .ok_or(StoreError::NotFound)?,
    };
    transaction.commit().map_err(failed)?;
    Ok(cut)
}

/// Add session `rows.session_id`. Copy events from `rows.source` through `rows.cut` in the same transaction.
fn copy_rows(connection: &mut Connection, rows: &events::CopyEventsParams) -> Result<(), StoreError> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(failed)?;
    // Another writer can delete the source between the read of the cut and this write.
    ensure_session(&transaction, rows.source)?;
    let session = sessions::CopySessionParams {
        source: rows.source,
        id: rows.session_id,
        cut: rows.cut,
    };
    sessions::copy_session(&transaction, &session).map_err(failed)?;
    events::copy_events(&transaction, rows).map_err(failed)?;
    sessions::place_fork(&transaction, rows.session_id).map_err(failed)?;
    transaction.commit().map_err(failed)
}

/// The saved facts of a session row.
fn summary_of(
    id: [u8; 16],
    settings: crate::Json<SessionSettings>,
    preview: Option<String>,
    fork_of: Option<[u8; 16]>,
    created_at: u64,
    updated_at: u64,
) -> SessionSummary {
    let SessionSettings { model, cwd, .. } = settings.0;
    SessionSummary {
        session_id: SessionId::from_bytes(id),
        model,
        cwd,
        preview,
        created_at,
        updated_at,
        fork_of: fork_of.map(SessionId::from_bytes),
    }
}

/// Delete the rows and the folder of a new session whose creation or fork failed. Its lock is already free. An error
/// here returns in place of the first error, because the session then stays.
fn delete_new_session(connection: &Connection, session: [u8; 16], folder: &Path) -> Result<(), StoreError> {
    sessions::delete_session(connection, session).map_err(failed)?;
    files::remove_session_folder(folder).map_err(failed)
}

/// The row of `commit` and its `consumed` inputs, with its blocks as JSON text.
fn commit_params(
    id: SessionId,
    commit: &Commit<'_>,
    consumed: &[ConsumedInput],
) -> serde_json::Result<events::InsertCommitParams<'static>> {
    let (head, keep) = match &commit.replaced {
        Some(replaced) => (Some(serde_json::to_string(&replaced.head)?), Some(replaced.keep)),
        None => (None, None),
    };

    let answer = commit.answer.as_ref();
    let usage = answer.map(|answer| answer.usage);

    let (end_kind, end_finish_reason, end_message) = match &commit.end {
        None => (None, None, None),
        Some(TurnEnd::Outcome(Outcome::Completed { finish_reason })) => {
            (Some(event::COMPLETED), Some(finish_reason.as_str()), None)
        }
        Some(TurnEnd::Outcome(Outcome::Stopped)) => (Some(event::STOPPED), None, None),
        Some(TurnEnd::Outcome(Outcome::Cancelled)) => (Some(event::CANCELLED), None, None),
        Some(TurnEnd::Failed(message)) => (Some(event::FAILED), None, Some(message.clone())),
    };

    Ok(events::InsertCommitParams {
        session_id: *id.as_bytes(),
        blocks: serde_json::to_string(&commit.blocks)?,
        consumed: serde_json::to_string(consumed)?,
        head,
        keep,
        model: answer.map(|answer| answer.origin.model.clone()),
        base_url: answer.map(|answer| answer.origin.base_url.clone()),
        input_tokens: usage.and_then(|usage| usage.input),
        output_tokens: usage.and_then(|usage| usage.output),
        reasoning_tokens: usage.and_then(|usage| usage.reasoning),
        cache_read_tokens: usage.and_then(|usage| usage.cache_read),
        cache_write_tokens: usage.and_then(|usage| usage.cache_write),
        finish_reason: answer.map(|answer| answer.finish_reason.as_str()),
        end_kind,
        end_finish_reason,
        end_message,
    })
}

/// Tell whether the database has session `session`.
pub(crate) fn has_session(connection: &Connection, session: [u8; 16]) -> Result<bool, StoreError> {
    sessions::session_exists(connection, session).one().map_err(failed)
}

/// `Ok` when the database has session `session`, and [`StoreError::NotFound`] otherwise. Call this function before the
/// lock of the session, so an unknown session gets no folder.
fn ensure_session(connection: &Connection, session: [u8; 16]) -> Result<(), StoreError> {
    if has_session(connection, session)? {
        Ok(())
    } else {
        Err(StoreError::NotFound)
    }
}

pub(crate) fn failed(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> StoreError {
    StoreError::Failed(error.into())
}

impl From<pending_inputs::PendingInputs> for PendingInput {
    fn from(row: pending_inputs::PendingInputs) -> Self {
        PendingInput {
            id: InputId(row.id),
            input: row.input.0,
        }
    }
}
