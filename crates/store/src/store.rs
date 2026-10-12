//! [`SqliteStore`]: the connection, the owner locks, and the [`Store`] methods.

use std::collections::HashMap;
use std::fmt;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use yuke_agent::{
    Access, EventNumber, InputId, Lease, Opened, PendingInput, SessionId, SessionSettings, Store, StoreError,
    StoredEvent,
};
use yuke_engine::{Commit, Outcome, TurnEnd};
use yuke_sql::rusqlite::{self, Connection, TransactionBehavior};

use crate::context;
use crate::event;
use crate::files;
use crate::queries::{events, pending_inputs, sessions};
use crate::schema;

/// A [`Store`] in one SQLite file. One connection runs every read and write in call order on its own thread.
pub struct SqliteStore {
    connection: tokio_rusqlite::Connection,
    /// The folder of the session folders.
    sessions: PathBuf,
    owners: Owners,
}

/// The locked file of each session that a lease of this store holds. Each write holds a clone, so the lock stays held
/// until the write ends, also when the lease drops while the write waits in the queue of the connection. Each change of
/// the map is one call, so the map stays valid after a panic of another holder of the mutex.
type Owners = Arc<Mutex<HashMap<SessionId, Arc<File>>>>;

/// The guard of a [`Lease`]. Its drop removes the file from the owners, and the last clone of the file releases the
/// lock.
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
        std::fs::create_dir_all(&sessions).map_err(failed)?;
        files::sync_folder(folder).map_err(failed)?;

        let connection = tokio_rusqlite::Connection::open(folder.join("yuke.db"))
            .await
            .map_err(failed)?;

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

    /// The lock file that a lease of this store holds for session `id`.
    fn owner(&self, id: SessionId) -> Option<Arc<File>> {
        self.owners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .cloned()
    }

    /// The lease of the locked `file` of session `id`.
    fn lease(&self, id: SessionId, file: File) -> Lease {
        self.owners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, Arc::new(file));

        Lease::new(Owner {
            id,
            owners: Arc::clone(&self.owners),
        })
    }
}

#[async_trait]
impl Store for SqliteStore {
    async fn create_session(&self, settings: &SessionSettings) -> Result<Opened, StoreError> {
        let id = SessionId::generate();
        let folder = self.folder(id);
        let sessions_folder = self.sessions.clone();
        let session = *id.as_bytes();
        let settings_json = serde_json::to_string(settings).map_err(failed)?;

        let file = self
            .call(move |connection| {
                // No other process knows the new id yet, so the rows can come first. Then each folder that the sweep
                // finds for a live session has its row.
                insert_session(connection, session, settings_json).map_err(failed)?;
                let locked = files::take_lock(&folder).and_then(|file| {
                    // A crash must not lose the entry of the new folder, so the call syncs the folder that holds it.
                    files::sync_folder(&sessions_folder).map_err(failed)?;
                    Ok(file)
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
            context: Vec::new(),
            turn_open: false,
            lease: Some(self.lease(id, file)),
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
        let (loaded, file) = self
            .call(move |connection| {
                // The rows come before the folder, as in `create_session`, so the sweep finds no live folder without
                // its row.
                copy_rows(connection, source_bytes, fork, through)?;
                let forked = copy_folder(&source_folder, &folder, &sessions_folder).and_then(|file| {
                    let loaded = read(connection, |connection| context::load(connection, fork))?;
                    Ok((loaded.ok_or(StoreError::NotFound)?, file))
                });
                // The caller never learns the id of a failed fork, so nothing else can open or delete it.
                forked.or_else(|error| {
                    delete_new_session(connection, fork, &folder)?;
                    Err(error)
                })
            })
            .await?;

        Ok(loaded.opened(id, Some(self.lease(id, file))))
    }

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<(), StoreError> {
        let owner = self.owner(id);
        let session = *id.as_bytes();
        let settings_json = serde_json::to_string(settings).map_err(failed)?;

        self.call(move |connection| {
            let saved = save_settings(connection, session, settings_json).map_err(failed)?;
            drop(owner);
            ensure_found(saved)
        })
        .await
    }

    async fn accept_input(&self, id: SessionId, blocks: &[yuke_ai::Block]) -> Result<InputId, StoreError> {
        let params = pending_inputs::InsertPendingInputParams {
            session_id: *id.as_bytes(),
            blocks: serde_json::to_string(blocks).map_err(failed)?,
        };

        self.call(move |connection| {
            let row = pending_inputs::insert_pending_input(connection, &params)
                .opt()
                .map_err(failed)?;
            row.map(|row| InputId(row.id)).ok_or(StoreError::NotFound)
        })
        .await
    }

    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError> {
        let folder = match access {
            Access::Read => None,
            Access::Write => Some(self.folder(id)),
        };
        let session = *id.as_bytes();

        let (loaded, file) = self
            .call(move |connection| {
                // The lock comes before the load, so no other writer commits between the lock and the load.
                let file = match folder {
                    Some(folder) => Some(lock_known_session(connection, session, &folder)?),
                    None => None,
                };

                let loaded = read(connection, |connection| context::load(connection, session))?;
                Ok((loaded.ok_or(StoreError::NotFound)?, file))
            })
            .await?;

        Ok(loaded.opened(id, file.map(|file| self.lease(id, file))))
    }

    async fn commit(&self, id: SessionId, commit: &Commit<'_>, consumed: &[InputId]) -> Result<(), StoreError> {
        let owner = self.owner(id);
        let params = commit_params(id, commit, consumed).map_err(failed)?;
        let consumed: Vec<u64> = consumed.iter().map(|input| input.0).collect();

        self.call(move |connection| {
            let saved = save_commit(connection, &params, &consumed).map_err(failed)?;
            drop(owner);
            ensure_found(saved)
        })
        .await
    }

    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError> {
        let session = *id.as_bytes();

        let rows = self
            .call(move |connection| {
                read(connection, |connection| {
                    if sessions::session_count(connection, session).one()?.count == 0 {
                        return Ok(None);
                    }

                    pending_inputs::pending_inputs(connection, session).all().map(Some)
                })?
                .ok_or(StoreError::NotFound)
            })
            .await?;

        Ok(rows
            .into_iter()
            .map(|row| PendingInput {
                id: InputId(row.id),
                blocks: row.blocks.0,
            })
            .collect())
    }

    async fn events(&self, id: SessionId, after: Option<EventNumber>) -> Result<Vec<StoredEvent>, StoreError> {
        let params = events::EventsAfterParams {
            session_id: *id.as_bytes(),
            after: after.map_or(0, |after| after.0.min(LARGEST_SEQ)),
        };

        let rows = self
            .call(move |connection| {
                read(connection, |connection| {
                    if sessions::session_count(connection, params.session_id).one()?.count == 0 {
                        return Ok(None);
                    }

                    events::events_after(connection, &params).all().map(Some)
                })?
                .ok_or(StoreError::NotFound)
            })
            .await?;

        rows.into_iter().map(event::stored_event).collect()
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
            let lock = lock_known_session(connection, session, &folder)?;
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
    function: impl FnOnce(&Connection) -> rusqlite::Result<T>,
) -> Result<T, StoreError> {
    let transaction = connection.transaction().map_err(failed)?;
    let value = function(&transaction).map_err(failed)?;
    transaction.commit().map_err(failed)?;
    Ok(value)
}

/// Take the next event number of session `session`, and return `false` for an unknown session. The insert of the event
/// reads the number from the session row. Call it in the write transaction of that insert, so a failed save leaves no gap.
fn take_seq(connection: &Connection, session: [u8; 16]) -> rusqlite::Result<bool> {
    Ok(sessions::take_seq(connection, session)? > 0)
}

/// Save a new session row and its first event, which holds its settings, in one transaction.
fn insert_session(connection: &mut Connection, session: [u8; 16], settings: String) -> rusqlite::Result<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    sessions::insert_session(&transaction, session)?;
    take_seq(&transaction, session)?;
    let params = events::InsertSettingsParams {
        session_id: session,
        settings,
    };
    events::insert_settings(&transaction, &params)?;
    transaction.commit()
}

/// Save a settings event in one transaction. Returns `false` for an unknown session.
fn save_settings(connection: &mut Connection, session: [u8; 16], settings: String) -> rusqlite::Result<bool> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if !take_seq(&transaction, session)? {
        return Ok(false);
    }
    let params = events::InsertSettingsParams {
        session_id: session,
        settings,
    };
    events::insert_settings(&transaction, &params)?;
    transaction.commit()?;
    Ok(true)
}

/// Save the commit event and remove the consumed inputs in one transaction. Returns `false` for an unknown session.
fn save_commit(
    connection: &mut Connection,
    params: &events::InsertCommitParams,
    consumed: &[u64],
) -> rusqlite::Result<bool> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if !take_seq(&transaction, params.session_id)? {
        return Ok(false);
    }
    events::insert_commit(&transaction, params)?;

    for &input in consumed {
        let params = pending_inputs::DeletePendingInputParams {
            session_id: params.session_id,
            id: input,
        };
        pending_inputs::delete_pending_input(&transaction, &params)?;
    }

    transaction.commit()?;
    Ok(true)
}

/// Copy the session row and the events of session `source` up to the cut to session `fork` in one transaction. The cut
/// is event `through`, which must end a completed turn, or the cut that `fork_cut` gives.
fn copy_rows(
    connection: &mut Connection,
    source: [u8; 16],
    fork: [u8; 16],
    through: Option<EventNumber>,
) -> Result<(), StoreError> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(failed)?;
    let cut = match through {
        Some(EventNumber(through)) => {
            ensure_session(&transaction, source)?;
            if through > LARGEST_SEQ {
                return Err(StoreError::NotACompletedTurn);
            }
            let params = events::CompletedTurnCountParams {
                session_id: source,
                seq: through,
            };
            if events::completed_turn_count(&transaction, &params)
                .one()
                .map_err(failed)?
                .count
                == 0
            {
                return Err(StoreError::NotACompletedTurn);
            }
            through
        }
        None => events::fork_cut(&transaction, source)
            .map(|row| row.cut)
            .opt()
            .map_err(failed)?
            .ok_or(StoreError::NotFound)?,
    };

    let params = sessions::InsertForkParams { id: fork, cut };
    sessions::insert_fork(&transaction, &params).map_err(failed)?;
    let params = events::CopyEventsParams {
        source,
        session_id: fork,
        cut,
    };
    events::copy_events(&transaction, &params).map_err(failed)?;
    transaction.commit().map_err(failed)
}

/// Take the lock of the new session folder `folder`, and copy the blobs of the session folder `source` into it.
fn copy_folder(source: &Path, folder: &Path, sessions_folder: &Path) -> Result<File, StoreError> {
    let file = files::take_lock(folder)?;
    // A crash must not lose the entry of the new folder, so the call syncs the folder that holds it.
    files::sync_folder(sessions_folder).map_err(failed)?;
    files::copy_blobs(source, folder).map_err(failed)?;
    Ok(file)
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
    consumed: &[InputId],
) -> serde_json::Result<events::InsertCommitParams> {
    let (head, keep) = match &commit.replaced {
        Some(replaced) => (Some(serde_json::to_string(&replaced.head)?), Some(replaced.keep)),
        None => (None, None),
    };

    let answer = commit.answer.as_ref();
    let usage = answer.map(|answer| answer.usage);

    let (end_kind, end_finish_reason, end_message) = match &commit.end {
        None => (None, None, None),
        Some(TurnEnd::Outcome(Outcome::Completed { finish_reason })) => {
            (Some("completed"), Some(finish_reason.as_str()), None)
        }
        Some(TurnEnd::Outcome(Outcome::Stopped)) => (Some("stopped"), None, None),
        Some(TurnEnd::Outcome(Outcome::Cancelled)) => (Some("cancelled"), None, None),
        Some(TurnEnd::Failed(message)) => (Some("failed"), None, Some(message.clone())),
    };

    Ok(events::InsertCommitParams {
        session_id: *id.as_bytes(),
        blocks: serde_json::to_string(&commit.blocks)?,
        consumed: serde_json::to_string(consumed)?,
        head,
        keep,
        model: answer.map(|answer| answer.origin.model.clone()),
        base_url: answer.map(|answer| answer.origin.base_url.clone()),
        input_tokens: usage.map(|usage| usage.input),
        output_tokens: usage.map(|usage| usage.output),
        reasoning_tokens: usage.map(|usage| usage.reasoning),
        cache_read_tokens: usage.map(|usage| usage.cache_read),
        cache_write_tokens: usage.map(|usage| usage.cache_write),
        finish_reason: answer.map(|answer| answer.finish_reason.as_str().to_owned()),
        end_kind: end_kind.map(str::to_owned),
        end_finish_reason: end_finish_reason.map(str::to_owned),
        end_message,
    })
}

/// Take the lock of session `session` in `folder`. An unknown session gets [`StoreError::NotFound`] and no folder.
fn lock_known_session(connection: &Connection, session: [u8; 16], folder: &Path) -> Result<File, StoreError> {
    ensure_session(connection, session)?;

    files::take_lock(folder)
}

/// `Ok` when the database has session `session`, and [`StoreError::NotFound`] otherwise.
fn ensure_session(connection: &Connection, session: [u8; 16]) -> Result<(), StoreError> {
    let count = sessions::session_count(connection, session)
        .one()
        .map_err(failed)?
        .count;

    ensure_found(count > 0)
}

/// `Ok` when the session was found, and [`StoreError::NotFound`] otherwise.
fn ensure_found(session_found: bool) -> Result<(), StoreError> {
    if session_found {
        Ok(())
    } else {
        Err(StoreError::NotFound)
    }
}

pub(crate) fn failed(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> StoreError {
    StoreError::Failed(error.into())
}
