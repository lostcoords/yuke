//! The durable steps of a session, and the types that a store saves and loads.

use std::fmt;
use std::path::Path;

use async_trait::async_trait;
use yuke_engine::{Commit, TurnEnd};
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, PendingInput, SessionId, SessionSettings, StoredEvent,
};

/// Saves and loads sessions. Each method is one atomic durable step. One writer at a time owns a session. A second
/// [`Access::Write`] open gets [`StoreError::Owned`] until the [`Lease`] of the first writer drops and its writes end.
/// Only the holder of the lease calls [`Store::set_settings`] and [`Store::commit`]. Any caller can accept input.
///
/// Each commit and each settings change also save one [`SessionEvent`](yuke_protocol::SessionEvent) with the next event number of the session. A
/// reader of [`Store::load`] sees each of them once and in order. An accepted input is no event: it enters the events
/// with the commit that consumes it.
#[async_trait]
pub trait Store: Send + Sync {
    /// Save a new session with `settings`, and open it for writing. Its first event holds the settings.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Failed`] when the save fails.
    async fn create_session(&self, settings: &SessionSettings) -> Result<Opened, StoreError>;

    /// Save a new session with the events of session `source` up to the end of a completed turn, and open it for
    /// writing. `through` is the event number of that end. `None` takes the newest completed turn, and a source with no
    /// completed turn gives the settings before its first commit. The copy has the settings at that point, every blob of
    /// the source, no pending input, and no open turn. A writer of `source` can keep its lease during the fork.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown source, [`StoreError::NotACompletedTurn`] when event `through`
    /// does not end a completed turn, and [`StoreError::Failed`] when the save fails. A failed save leaves no new
    /// session. When the delete of a partial copy fails, the error of that delete returns in place of the first one.
    async fn fork_session(&self, source: SessionId, through: Option<EventNumber>) -> Result<Opened, StoreError>;

    /// Replace the settings of session `id` with `settings`. Return the event number of the settings event only after
    /// the durable write succeeds.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the save fails.
    async fn set_settings(&self, id: SessionId, settings: &SessionSettings) -> Result<EventNumber, StoreError>;

    /// Save `input` as a pending input of session `id`. The input stays pending until a commit consumes it.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the save fails.
    async fn accept_input(&self, id: SessionId, input: Input) -> Result<InputId, StoreError>;

    /// Remove the pending input `input` of session `id`. Any caller can remove an input.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session. Returns [`StoreError::InputNotPending`] when the input is
    /// not pending, for example because a commit consumed it. Returns [`StoreError::Failed`] when the save fails.
    async fn remove_input(&self, id: SessionId, input: InputId) -> Result<(), StoreError>;

    /// The session that works in the folder `cwd` and has the newest event of those sessions. The newest settings of a
    /// session name its folder. `None` when no session works in `cwd`. A fork counts as a new event.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Failed`] when the load fails.
    async fn newest_session(&self, cwd: &Path) -> Result<Option<SessionId>, StoreError>;

    /// Load session `id`. [`Access::Write`] also takes the owner lock.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, [`StoreError::Owned`] when another writer holds the
    /// session, and [`StoreError::Failed`] when the load fails.
    async fn open(&self, id: SessionId, access: Access) -> Result<Opened, StoreError>;

    /// Save `commit` after the commits of session `id`. Keep the records of its `consumed` inputs in the same event,
    /// and remove those pending inputs in the same step. The commit starts with their model blocks. Replay the saved
    /// commits in order: apply `replaced`, then append `blocks`. Return the event number of the commit only after the
    /// durable write succeeds.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session. Returns [`StoreError::InputNotPending`] when a consumed
    /// input is not pending. Returns [`StoreError::InputBlocksExceedCommit`] when the consumed inputs have more blocks
    /// than the commit. Returns [`StoreError::Failed`] when the save fails. A failed commit saves nothing.
    async fn commit(
        &self,
        id: SessionId,
        commit: &Commit<'_>,
        consumed: &[ConsumedInput],
    ) -> Result<EventNumber, StoreError>;

    /// The inputs of session `id` that no commit consumed, in id order.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the load fails.
    async fn pending(&self, id: SessionId) -> Result<Vec<PendingInput>, StoreError>;

    /// The events of session `id` after event `after`, in event-number order, and its pending inputs, in id order. The
    /// two come from one moment. An input that is not pending left in a returned event, in an event at or before
    /// `after`, or by a removal. `None` gives every event.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::NotFound`] for an unknown session, and [`StoreError::Failed`] when the load fails.
    async fn load(&self, id: SessionId, after: Option<EventNumber>) -> Result<Loaded, StoreError>;

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

    /// Delete session `id` with its events, pending inputs, and blobs.
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

/// Check that the model blocks of the `consumed` inputs fit in `commit`. A commit starts with those blocks, so their
/// counts sum to at most its block count. A store calls this before it saves a commit.
///
/// # Errors
///
/// Returns [`StoreError::InputBlocksExceedCommit`] when the counts sum to more than the blocks of `commit`.
pub fn check_consumed_blocks(commit: &Commit<'_>, consumed: &[ConsumedInput]) -> Result<(), StoreError> {
    let sum = consumed
        .iter()
        .try_fold(0_usize, |sum, input| sum.checked_add(input.block_count));
    match sum {
        Some(sum) if sum <= commit.blocks.len() => Ok(()),
        _ => Err(StoreError::InputBlocksExceedCommit),
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

/// The saved events and the pending inputs of a session at one moment, as [`Store::load`] gives them.
#[derive(Debug, Clone, PartialEq)]
pub struct Loaded {
    /// The events after the requested event number.
    pub events: Vec<StoredEvent>,
    /// The inputs that no commit consumed.
    pub pending: Vec<PendingInput>,
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
    /// The newest turn of the session.
    pub newest_turn: NewestTurn,
    /// The owner lock of an [`Access::Write`] open. A read holds no lock.
    pub lease: Option<Lease>,
}

/// The newest turn of a session, as its newest commit shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NewestTurn {
    /// The session has no commit.
    Empty,
    /// The newest commit has no end. A failed write, a dropped turn, or a stopped process leaves the turn open.
    Open,
    /// The newest commit ends the turn.
    Ended(TurnEnd),
}

impl NewestTurn {
    /// Whether a turn is open.
    pub fn is_open(&self) -> bool {
        matches!(self, NewestTurn::Open)
    }
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
    /// The event that a fork names does not end a completed turn.
    NotACompletedTurn,
    /// A commit consumes this input, or a caller removes it, but the input is not pending.
    InputNotPending(InputId),
    /// The consumed inputs of a commit have more model blocks than the commit.
    InputBlocksExceedCommit,
    /// The store failed to save or load.
    Failed(Box<dyn std::error::Error + Send + Sync>),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Owned => f.write_str("another writer holds the session"),
            Self::NotFound => f.write_str("the store has no such session"),
            Self::NotACompletedTurn => f.write_str("the event does not end a completed turn"),
            Self::InputNotPending(InputId(id)) => write!(f, "input {id} is not pending"),
            Self::InputBlocksExceedCommit => f.write_str("the consumed inputs have more blocks than the commit"),
            // The text names no cause, because `source` returns it.
            Self::Failed(_) => f.write_str("the store failed"),
        }
    }
}

impl std::error::Error for StoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Failed(error) => Some(error.as_ref()),
            Self::Owned
            | Self::NotFound
            | Self::NotACompletedTurn
            | Self::InputNotPending(_)
            | Self::InputBlocksExceedCommit => None,
        }
    }
}
