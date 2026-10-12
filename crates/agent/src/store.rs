//! The durable steps of a session, and the types that a store saves and loads.

use std::fmt;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use yuke_engine::Commit;

/// Saves and loads sessions. Each method is one atomic durable step. One writer at a time owns a session. A second
/// [`Access::Write`] open gets [`StoreError::Owned`] until the [`Lease`] of the first writer drops and its writes end.
/// Only the holder of the lease calls [`Store::set_settings`] and [`Store::commit`]. Any caller can accept input.
#[async_trait]
pub trait Store: Send + Sync {
    /// Save a new session with `settings`, and open it for writing.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Failed`] when the save fails.
    async fn create_session(&self, settings: &SessionSettings) -> Result<Opened, StoreError>;

    /// Save a new session with a copy of the settings, the commits, and the blobs of session `source`, and open it for
    /// writing. The copy has no pending input. A writer of `source` can keep its lease during the fork.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown source, and [`StoreError::Failed`] when the save fails. After a
    /// failed save, the store deletes the new session, and an error of that delete returns in its place.
    async fn fork_session(&self, source: SessionId) -> Result<Opened, StoreError>;

    /// Replace the settings of session `id` with `settings`.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the save fails.
    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<(), StoreError>;

    /// Save `blocks` as a pending input of session `id`. The input stays pending until a commit consumes it.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the save fails.
    async fn accept_input(&self, id: SessionId, blocks: &[yuke_ai::Block]) -> Result<InputId, StoreError>;

    /// Load session `id`. [`Access::Write`] also takes the owner lock.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, [`StoreError::Owned`] when another writer holds the
    /// session, and [`StoreError::Failed`] when the load fails.
    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError>;

    /// Save `commit` after the commits of session `id`, and remove the `consumed` pending inputs, in one step. Replay
    /// the saved commits in order: apply `replaced`, then append `blocks`.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the save fails.
    async fn commit(&self, id: SessionId, commit: &Commit<'_>, consumed: &[InputId]) -> Result<(), StoreError>;

    /// The inputs of session `id` that no commit consumed, in id order.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the load fails.
    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError>;

    /// Save `bytes` as a blob of session `id`, and return its [`blob_of`] reference. Only this session reads the blob.
    /// The same bytes again give the same blob. Any caller can put a blob.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the save fails.
    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, StoreError>;

    /// The bytes of the blob with `digest` in session `id`, or `None` when the session has no such blob. The read
    /// blocks, because the request encoder reads blobs synchronously.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the read fails.
    fn read_blob(&self, id: SessionId, digest: &yuke_ai::Digest) -> Result<Option<Vec<u8>>, StoreError>;

    /// Delete session `id` with its commits, inputs, and blobs.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, [`StoreError::Owned`] while a writer holds the
    /// session, and [`StoreError::Failed`] when the delete fails.
    async fn delete_session(&self, id: SessionId) -> Result<(), StoreError>;
}

/// The blob of `bytes`: their SHA-256 and their length. Each store finds a blob by this digest.
pub fn blob_of(bytes: &[u8]) -> yuke_ai::Blob {
    use sha2::Digest;

    yuke_ai::Blob {
        digest: sha2::Sha256::digest(bytes).into(),
        len: bytes.len(),
    }
}

/// The id of a session: a version 7 UUID, so a new id sorts after an old one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(uuid::Uuid);

impl SessionId {
    /// A new id from the current time and random bits.
    pub fn generate() -> Self {
        SessionId(uuid::Uuid::now_v7())
    }

    /// The 16 bytes of the id, in the order that sorts by time.
    pub fn as_bytes(&self) -> &[u8; 16] {
        self.0.as_bytes()
    }
}

/// The id of a pending input. A store gives each input of a session a larger id than the inputs before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct InputId(pub i64);

/// The current choice of a session: the model and the request settings. It holds no credential and no route, so the
/// agent makes the target from the model reference and its config.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionSettings {
    /// The model of the next turn.
    pub model: ModelReference,
    /// The request settings of the next turn.
    pub settings: yuke_ai::Settings,
}

/// A model of a provider, by the ids of the config.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelReference {
    /// The id of the provider.
    pub provider: String,
    /// The id of the model at the provider.
    pub model: String,
}

impl ModelReference {
    /// The model `model` of the provider `provider`.
    pub fn new(provider: impl Into<String>, model: impl Into<String>) -> Self {
        ModelReference {
            provider: provider.into(),
            model: model.into(),
        }
    }
}

/// How [`Store::open`] opens a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    /// Load the session, with no lock.
    Read,
    /// Load the session, and take the owner lock.
    Write,
}

/// A loaded session.
#[derive(Debug)]
pub struct Opened {
    /// The id of the session.
    pub id: SessionId,
    /// The current settings.
    pub settings: SessionSettings,
    /// The model context: the head of the newest replacement, the blocks that it keeps, and the blocks after it.
    pub context: Vec<yuke_ai::Block>,
    /// Whether the newest commit has no end. A process that stopped during a turn leaves the turn open.
    pub turn_open: bool,
    /// The owner lock of an [`Access::Write`] open. A read holds no lock.
    pub lease: Option<Lease>,
}

/// An input that no commit consumed.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingInput {
    /// The id that [`Store::accept_input`] gave.
    pub id: InputId,
    /// The blocks of the input.
    pub blocks: Vec<yuke_ai::Block>,
}

/// Holds the owner lock of a session. The drop releases the lock.
pub struct Lease {
    #[expect(dead_code, reason = "only the drop of the guard matters: it releases the lock")]
    guard: Box<dyn Send + Sync>,
}

impl Lease {
    /// A lease that releases its lock when `guard` drops.
    pub fn new(guard: impl Send + Sync + 'static) -> Self {
        Lease { guard: Box::new(guard) }
    }
}

impl fmt::Debug for Lease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Lease").finish_non_exhaustive()
    }
}

/// The failure of a [`Store`] method.
#[derive(Debug)]
pub enum StoreError {
    /// Another writer holds the session.
    Owned,
    /// The store has no session with this id.
    NotFound,
    /// The store failed to save or load.
    Failed(Box<dyn std::error::Error + Send + Sync>),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Owned => f.write_str("another writer holds the session"),
            Self::NotFound => f.write_str("the store has no such session"),
            // The text names no cause, because `source` returns it.
            Self::Failed(_) => f.write_str("the store failed"),
        }
    }
}

impl std::error::Error for StoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Failed(error) => Some(error.as_ref()),
            Self::Owned | Self::NotFound => None,
        }
    }
}
