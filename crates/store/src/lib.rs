//! A file [`Store`](yuke_agent::Store) for the sessions of `yuke-agent`. One index file holds the facts and the pending
//! inputs of all sessions. Each session has a folder with its lock file, its event log, and its blobs.

mod files;
mod index;
mod log;
mod store;

pub use store::FileStore;

/// A [`StoreError::Failed`](yuke_agent::StoreError::Failed) with the cause `error`.
pub(crate) fn failed(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> yuke_agent::StoreError {
    yuke_agent::StoreError::Failed(error.into())
}

// Each change of a guarded value is complete before the next statement, so a panic of another holder leaves a valid
// value.
pub(crate) fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The time since the Unix epoch. A clock before 1970 gives zero, as the times of a store need no more.
pub(crate) fn since_epoch() -> std::time::Duration {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
}
