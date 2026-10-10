//! [`SqliteStore`]: the connection, the owner locks, and the [`Store`] methods.

use std::collections::HashMap;
use std::fmt;
use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use yuke_agent::{Access, InputId, Lease, Opened, PendingInput, SessionId, SessionSettings, Store, StoreError};
use yuke_engine::{Commit, Outcome, TurnEnd};
use yuke_sql::rusqlite::{self, Connection, TransactionBehavior};

use crate::context::{self, Loaded};
use crate::queries::{commits, pending_inputs, sessions};
use crate::schema;

/// A [`Store`] in one SQLite file. One connection runs every read and write in call order on its own thread.
pub struct SqliteStore {
    connection: tokio_rusqlite::Connection,
    /// The folder of the lock files.
    locks: PathBuf,
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
            .field("locks", &self.locks)
            .finish_non_exhaustive()
    }
}

impl SqliteStore {
    /// Open the store in `folder`: the database `yuke.db` and the lock files in `locks/`. Create what is missing, and
    /// run the migrations that the database lacks.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Failed`] when a folder or the database does not open, or a migration fails. It also
    /// returns it when the schema version of the database is above the versions that this yuke knows.
    pub async fn open(folder: impl AsRef<Path>) -> Result<SqliteStore, StoreError> {
        let folder = folder.as_ref();
        let locks = folder.join("locks");
        std::fs::create_dir_all(&locks).map_err(failed)?;

        let connection = tokio_rusqlite::Connection::open(folder.join("yuke.db"))
            .await
            .map_err(failed)?;

        let store = SqliteStore {
            connection,
            locks,
            owners: Owners::default(),
        };
        store
            .call(|connection| schema::prepare(connection).map_err(StoreError::Failed))
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

    /// The lock file of session `id`.
    fn lock_path(&self, id: SessionId) -> PathBuf {
        self.locks
            .join(format!("{:032x}.lock", u128::from_be_bytes(*id.as_bytes())))
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
        let lock_path = self.lock_path(id);
        let params = sessions::InsertSessionParams {
            id: *id.as_bytes(),
            settings: serde_json::to_string(settings).map_err(failed)?,
        };

        let file = self
            .call(move |connection| {
                let file = take_lock(&lock_path)?;
                sessions::insert_session(connection, &params).map_err(failed)?;
                Ok(file)
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

    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<(), StoreError> {
        let owner = self.owner(id);
        let params = sessions::UpdateSettingsParams {
            id: *id.as_bytes(),
            settings: serde_json::to_string(settings).map_err(failed)?,
        };

        self.call(move |connection| {
            let changed = sessions::update_settings(connection, &params).map_err(failed)?;
            drop(owner);
            ensure_found(changed > 0)
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
        let lock_path = match access {
            Access::Read => None,
            Access::Write => Some(self.lock_path(id)),
        };
        let session = *id.as_bytes();

        let (loaded, file) = self
            .call(move |connection| {
                // The lock comes before the load, so no other writer commits between the lock and the load.
                let file = match lock_path {
                    Some(lock_path) => Some(lock_known_session(connection, session, &lock_path)?),
                    None => None,
                };

                let loaded = read(connection, |connection| context::load(connection, session))?;
                Ok((loaded.ok_or(StoreError::NotFound)?, file))
            })
            .await?;

        let Loaded {
            settings,
            context,
            turn_open,
        } = loaded;
        Ok(Opened {
            id,
            settings,
            context,
            turn_open,
            lease: file.map(|file| self.lease(id, file)),
        })
    }

    async fn commit(&self, id: SessionId, commit: &Commit<'_>, consumed: &[InputId]) -> Result<(), StoreError> {
        let owner = self.owner(id);
        let params = commit_params(id, commit).map_err(failed)?;
        let consumed: Vec<i64> = consumed.iter().map(|input| input.0).collect();

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
}

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

/// Save the commit row and remove the consumed inputs in one transaction. Returns `false` for an unknown session.
fn save_commit(
    connection: &mut Connection,
    params: &commits::InsertCommitParams,
    consumed: &[i64],
) -> rusqlite::Result<bool> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if commits::insert_commit(&transaction, params)? == 0 {
        return Ok(false);
    }

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

/// The row of `commit`, with its blocks as JSON text.
fn commit_params(id: SessionId, commit: &Commit<'_>) -> serde_json::Result<commits::InsertCommitParams> {
    let (head, keep) = match commit.replaced {
        Some(replaced) => (Some(serde_json::to_string(replaced.head)?), Some(replaced.keep)),
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

    Ok(commits::InsertCommitParams {
        session_id: *id.as_bytes(),
        head,
        keep,
        blocks: serde_json::to_string(commit.blocks)?,
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

/// Take the lock of session `session` at `lock_path`. An unknown session gets [`StoreError::NotFound`] and no lock
/// file.
fn lock_known_session(connection: &Connection, session: [u8; 16], lock_path: &Path) -> Result<File, StoreError> {
    let count = sessions::session_count(connection, session)
        .one()
        .map_err(failed)?
        .count;
    ensure_found(count > 0)?;

    take_lock(lock_path)
}

/// Open the lock file at `path`, and take its lock. Windows does not lock a file that is open only for append, so
/// the file opens for writing.
fn take_lock(path: &Path) -> Result<File, StoreError> {
    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(failed)?;

    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => Err(StoreError::Owned),
        Err(TryLockError::Error(error)) => Err(failed(error)),
    }
}

/// `Ok` when the session was found, and [`StoreError::NotFound`] otherwise.
fn ensure_found(session_found: bool) -> Result<(), StoreError> {
    if session_found {
        Ok(())
    } else {
        Err(StoreError::NotFound)
    }
}

fn failed(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> StoreError {
    StoreError::Failed(error.into())
}
