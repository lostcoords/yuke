//! Durable sessions over `yuke-engine`. A [`Session`] runs turns on its context, and saves each commit of a turn in a
//! [`Store`] before the turn goes on. [`MemoryStore`] keeps its sessions in memory. The `testing` feature gives the
//! shared behavior tests of a store.

mod memory;
mod session;
mod store;
#[cfg(any(test, feature = "testing"))]
pub mod testing;
mod updates;

use std::sync::{Mutex, MutexGuard, PoisonError};

pub use memory::MemoryStore;
pub use session::{InputSender, Session, SessionError, SessionTurn};
pub use store::{Access, Lease, Loaded, Opened, Store, StoreError, blob_of, check_consumed_blocks};
pub use updates::SessionObserver;

// Each change of a guarded value is complete before the next statement, so a panic of another holder leaves a valid
// value.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
