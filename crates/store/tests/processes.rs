//! Two processes on one store folder: the test binary starts itself again as the second process. The index, the store
//! lock, and the owner locks must hold across processes, not only across two stores of one process.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]
#![expect(clippy::print_stderr, reason = "the harness of this test is its own main")]

use std::collections::HashSet;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use yuke_agent::testing::{prompt, settings, user_input};
use yuke_agent::{Access, Store, StoreError};
use yuke_protocol::{SessionId, SessionTitle};
use yuke_store::FileStore;

/// The variable that makes the binary the second process. Its value is the store folder.
const CHILD: &str = "YUKE_STORE_TEST_CHILD";
/// The sessions and the inputs that each process makes at the same time.
const EACH: u64 = 60;
/// The longest wait for the child process. A lock that never frees fails the test, not the run.
const CHILD_DEADLINE: Duration = Duration::from_secs(60);

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Ok(folder) = std::env::var(CHILD) {
        let ids: Vec<SessionId> = std::env::args()
            .skip(1)
            .map(|arg| serde_json::from_str(&arg).unwrap())
            .collect();
        let [leased, shared, doomed] = <[SessionId; 3]>::try_from(ids).unwrap();
        let store = FileStore::open(Path::new(&folder)).await.unwrap();
        let refused = store.open(leased, Access::Write).await;
        assert!(matches!(refused, Err(StoreError::Owned)), "{refused:?}");
        work(&store, shared, "child").await;
        store
            .rename_session(shared, &SessionTitle::new("named by the child").unwrap())
            .await
            .unwrap();
        store.delete_session(doomed).await.unwrap();
        return;
    }
    two_processes_share_one_store().await;
    eprintln!("test two_processes_share_one_store ... ok");
}

/// What each process does at the same time: new sessions with the model `model`, and inputs to one shared session.
async fn work(store: &FileStore, shared: SessionId, model: &str) {
    for round in 0..EACH {
        let opened = store.create_session(&settings(model), &prompt(), None).await.unwrap();
        drop(opened);
        store
            .accept_input(shared, user_input(&format!("{model} {round}")))
            .await
            .unwrap();
    }
}

async fn two_processes_share_one_store() {
    let folder = yuke_testing::folder("store-processes", "two_processes_share_one_store");
    let store = FileStore::open(&folder).await.unwrap();
    let leased = store
        .create_session(&settings("parent"), &prompt(), None)
        .await
        .unwrap();
    let shared = store
        .create_session(&settings("shared"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let doomed = store
        .create_session(&settings("doomed"), &prompt(), None)
        .await
        .unwrap()
        .id;
    // The parent reads the index before the child writes, so the next list must fold the lines of the child.
    assert_eq!(
        store.list_sessions(None, None, None, 100).await.unwrap().sessions.len(),
        3
    );

    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([leased.id, shared, doomed].map(|id| serde_json::to_string(&id).unwrap()))
        .env(CHILD, &folder)
        .spawn()
        .unwrap();
    work(&store, shared, "parent").await;
    let deadline = Instant::now() + CHILD_DEADLINE;
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() > deadline {
            // The kill ends the child with a signal, so the check below fails.
            child.kill().unwrap();
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(
        status.success(),
        "the child process failed or passed {CHILD_DEADLINE:?}: {status}"
    );

    // The parent folds the rename and the delete of the child.
    let title = store.session_summary(shared).await.unwrap().title.unwrap();
    assert_eq!(title.to_string(), "named by the child");
    let gone = store.session_summary(doomed).await;
    assert!(matches!(gone, Err(StoreError::NotFound)), "{gone:?}");

    // Small pages walk the whole list, so no two positions of the two processes tie.
    let mut seen = HashSet::new();
    let mut after = None;
    loop {
        let page = store.list_sessions(None, None, after, 7).await.unwrap();
        for session in &page.sessions {
            assert!(seen.insert(session.session_id), "a session twice");
        }
        match page.next {
            Some(next) => after = Some(next),
            None => break,
        }
    }
    assert_eq!(seen.len() as u64, 2 + 2 * EACH);
    let models: Vec<String> = store
        .list_sessions(None, None, None, 1000)
        .await
        .unwrap()
        .sessions
        .into_iter()
        .map(|session| session.model.model)
        .collect();
    assert_eq!(models.iter().filter(|model| *model == "child").count() as u64, EACH);

    // The store lock gives each input of the shared session its own id.
    let mut ids: Vec<u64> = store
        .pending(shared)
        .await
        .unwrap()
        .iter()
        .map(|input| input.id.0)
        .collect();
    ids.sort_unstable();
    assert_eq!(ids, (1..=2 * EACH).collect::<Vec<_>>());

    // A second store reads the same state from the file alone, and the drop of the lease frees the session for it.
    let other = FileStore::open(&folder).await.unwrap();
    assert_eq!(other.pending(shared).await.unwrap().len() as u64, 2 * EACH);
    let leased_id = leased.id;
    drop(leased);
    drop(other.open(leased_id, Access::Write).await.unwrap());
}
