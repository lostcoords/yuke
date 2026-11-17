//! Two processes on one store folder: the test binary starts itself again as the second process. The index, the store
//! lock, and the owner locks must hold across processes, not only across two stores of one process.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]
#![expect(clippy::print_stderr, reason = "the harness of this test is its own main")]

use std::collections::HashSet;
use std::path::Path;
use std::process::Command;

use yuke_agent::testing::{prompt, settings, user_input};
use yuke_agent::{Access, Store, StoreError};
use yuke_protocol::SessionId;
use yuke_store::FileStore;

/// The variable that makes the binary the second process. Its value is the store folder.
const CHILD: &str = "YUKE_STORE_TEST_CHILD";
/// The sessions and the inputs that each process makes at the same time.
const EACH: u64 = 60;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Ok(folder) = std::env::var(CHILD) {
        let mut args = std::env::args().skip(1);
        let leased: SessionId = serde_json::from_str(&args.next().unwrap()).unwrap();
        let shared: SessionId = serde_json::from_str(&args.next().unwrap()).unwrap();
        work(Path::new(&folder), leased, shared, "child").await;
        return;
    }
    two_processes_share_one_store().await;
    eprintln!("test two_processes_share_one_store ... ok");
}

/// What each process does at the same time: a write open of the session that the parent leases, then new sessions
/// and inputs to one shared session.
async fn work(folder: &Path, leased: SessionId, shared: SessionId, model: &str) {
    let store = FileStore::open(folder).await.unwrap();
    if model == "child" {
        let refused = store.open(leased, Access::Write).await;
        assert!(matches!(refused, Err(StoreError::Owned)), "{refused:?}");
    }
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
    // The parent reads the index before the child writes, so the next list must fold the lines of the child.
    assert_eq!(
        store.list_sessions(None, None, None, 100).await.unwrap().sessions.len(),
        2
    );

    let mut child = Command::new(std::env::current_exe().unwrap())
        .arg(serde_json::to_string(&leased.id).unwrap())
        .arg(serde_json::to_string(&shared).unwrap())
        .env(CHILD, &folder)
        .spawn()
        .unwrap();
    work(&folder, leased.id, shared, "parent").await;
    assert!(child.wait().unwrap().success(), "the child process failed");

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

    // A second store reads the same state from the file alone.
    let other = FileStore::open(&folder).await.unwrap();
    assert_eq!(other.pending(shared).await.unwrap().len() as u64, 2 * EACH);
    drop(leased);
    drop(
        other
            .open(seen.into_iter().next().unwrap(), Access::Write)
            .await
            .unwrap(),
    );
}
