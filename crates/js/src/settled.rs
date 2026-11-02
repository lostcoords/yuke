//! The wait until the runtime of the thread is settled, for tests. `yuke:test` exports it as `settled`.

use std::cell::Cell;
use std::time::Duration;

thread_local! {
    /// The count of the waits that run on this thread. The first one pauses the clock, and the last one resumes it.
    static WAITS: Cell<usize> = const { Cell::new(0) };
}

/// Ends a wait. The drop of the last wait resumes the clock, also when the caller drops the future.
struct Wait;

impl Drop for Wait {
    fn drop(&mut self) {
        let left = WAITS.get() - 1;
        WAITS.set(left);
        if left == 0 {
            tokio::time::resume();
        }
    }
}

/// Wait until no task of the current runtime can run and no `spawn_blocking` task of it runs. Under a paused clock,
/// tokio moves the clock only when the runtime has nothing else to do, and a running `spawn_blocking` task holds it.
/// The wait moves tokio time by 1 ms, not wall time. It does not see a later timer, a thread of its own such as the
/// store thread, a socket peer, or a child process.
///
/// # Panics
///
/// Panics outside a current-thread runtime, and when a caller other than this function paused the clock.
pub async fn settled() {
    if WAITS.get() == 0 {
        tokio::time::pause();
    }
    WAITS.set(WAITS.get() + 1);
    let _wait = Wait;
    tokio::time::sleep(Duration::from_millis(1)).await;
}
