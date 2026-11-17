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
