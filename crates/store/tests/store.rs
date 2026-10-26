//! The shared store behaviors, and the behaviors of the file: a reopen, and the owner lock across two stores.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::future::Future;
use std::path::PathBuf;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use tokio_rusqlite::rusqlite;
use yuke_agent::testing::{consumed, end, prompt, settings, step, user_input};
use yuke_agent::{Access, EventPage, Store, StoreError};
use yuke_engine::{Answer, Commit};
use yuke_protocol::EventNumber;
use yuke_store::SqliteStore;

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("store", name)
}

async fn make_store(name: &str) -> std::sync::Arc<SqliteStore> {
    std::sync::Arc::new(SqliteStore::open(folder(name)).await.unwrap())
}

yuke_agent::store_tests!(make_store);

#[tokio::test]
async fn a_session_survives_a_close_and_an_open_of_the_file() {
    let folder = folder("a_session_survives_a_close_and_an_open_of_the_file");
    let first = SqliteStore::open(&folder).await.unwrap();
    let opened = first.create_session(&settings("one"), &prompt()).await.unwrap();
    let id = opened.id;
    first.set_settings(id, &settings("two")).await.unwrap();
    first
        .commit(id, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    let input = first.accept_input(id, user_input("b")).await.unwrap();
    drop(opened);
    drop(first);

    let second = SqliteStore::open(&folder).await.unwrap();
    let opened = second.open(id, Access::Write).await.unwrap();

    assert_eq!(opened.settings, settings("two"));
    assert_eq!(opened.prompt, prompt());
    assert_eq!(opened.context, [yuke_ai::Block::user_text("a")]);
    assert!(opened.newest_turn.is_open());
    let pending = second.pending(id).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, input);
    assert_eq!(pending[0].input, user_input("b"));
}

#[tokio::test]
async fn a_queued_write_finishes_before_the_lock_releases() {
    let folder = folder("a_queued_write_finishes_before_the_lock_releases");
    let first = SqliteStore::open(&folder).await.unwrap();
    let second = SqliteStore::open(&folder).await.unwrap();
    let opened = first.create_session(&settings("one"), &prompt()).await.unwrap();
    let id = opened.id;
    // A writer outside the stores holds the database, so the commit of the first store waits on its thread.
    let blocker = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();

    let blocks = [yuke_ai::Block::user_text("queued")];
    {
        let commit = step(&blocks);
        let mut future = pin!(first.commit(id, &commit, &[]));
        // The first poll sends the write to the connection. The write stays in the queue after the future drops.
        let poll = future.as_mut().poll(&mut Context::from_waker(Waker::noop()));
        assert!(matches!(poll, Poll::Pending), "{poll:?}");
    }
    drop(opened);
    let during = second.open(id, Access::Write).await;
    // A lease from this open would hold the session, so check it before the next open.
    assert!(matches!(during, Err(StoreError::Owned)), "{during:?}");
    blocker.execute_batch("COMMIT").unwrap();
    // A read runs after the queued write on the same connection.
    first.pending(id).await.unwrap();
    let after = second.open(id, Access::Write).await.unwrap();

    assert_eq!(after.context, blocks);
}

#[tokio::test]
async fn a_blob_survives_a_close_and_an_open_of_the_file() {
    let folder = folder("a_blob_survives_a_close_and_an_open_of_the_file");
    let first = SqliteStore::open(&folder).await.unwrap();
    let id = first.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let blob = first.put_blob(id, b"image".to_vec()).await.unwrap();
    drop(first);

    let second = SqliteStore::open(&folder).await.unwrap();

    assert_eq!(
        second.read_blob(id, &blob.digest).unwrap().as_deref(),
        Some(&b"image"[..])
    );
}

#[tokio::test]
async fn a_delete_removes_the_folder_of_the_session() {
    let folder = folder("a_delete_removes_the_folder_of_the_session");
    let store = SqliteStore::open(&folder).await.unwrap();
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store.put_blob(id, b"image".to_vec()).await.unwrap();
    let sessions = || std::fs::read_dir(folder.join("sessions")).unwrap().count();
    let before = sessions();

    store.delete_session(id).await.unwrap();

    assert_eq!(before, 1);
    assert_eq!(sessions(), 0);
}

#[tokio::test]
async fn an_open_for_writing_of_an_unknown_session_makes_no_folder() {
    let folder = folder("an_open_for_writing_of_an_unknown_session_makes_no_folder");
    let store = SqliteStore::open(&folder).await.unwrap();
    let id = yuke_protocol::SessionId::generate();

    let open = store.open(id, Access::Write).await;

    assert!(matches!(open, Err(StoreError::NotFound)), "{open:?}");
    let folders = std::fs::read_dir(folder.join("sessions")).map_or(0, Iterator::count);
    assert_eq!(folders, 0);
}

#[tokio::test]
async fn the_sweep_removes_a_folder_without_a_session_and_keeps_a_locked_one() {
    let folder = folder("the_sweep_removes_a_folder_without_a_session_and_keeps_a_locked_one");
    drop(SqliteStore::open(&folder).await.unwrap());
    // This folder has no session row, as after a crash during a delete.
    let left = folder.join("sessions").join("0123456789abcdef0123456789abcdef");
    std::fs::create_dir_all(&left).unwrap();
    std::fs::write(left.join("blob"), b"image").unwrap();
    // This folder has no session row and a held lock, as during a delete in another process.
    let deleting = folder.join("sessions").join("fedcba9876543210fedcba9876543210");
    std::fs::create_dir_all(&deleting).unwrap();
    let lock = std::fs::File::create(deleting.join("lock")).unwrap();
    lock.try_lock().unwrap();

    drop(SqliteStore::open(&folder).await.unwrap());

    assert!(!left.exists());
    assert!(deleting.exists());
}

/// The model, the token usage, and the creation time of each commit event of session `id` in the database of `folder`,
/// in event-number order, as JSON arrays.
fn commit_rows(folder: &std::path::Path, id: yuke_protocol::SessionId) -> Vec<String> {
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    let mut statement = connection
        .prepare(
            "SELECT json_array(model, input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, \
             cache_write_tokens, created_at) FROM events WHERE session_id = ? AND kind = 'commit' ORDER BY seq",
        )
        .unwrap();
    statement
        .query_map([id.as_bytes()], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

#[tokio::test]
async fn a_fork_keeps_the_token_usage_and_the_creation_time_of_each_copied_commit() {
    let folder = folder("a_fork_keeps_the_token_usage_and_the_creation_time_of_each_copied_commit");
    let store = SqliteStore::open(&folder).await.unwrap();
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let blocks = [yuke_ai::Block::assistant_text("a")];
    let answer = Commit {
        answer: Some(Answer {
            origin: yuke_ai::Origin {
                model: "test-model".to_owned(),
                base_url: "https://example.test".to_owned(),
            },
            usage: yuke_ai::Usage {
                input: Some(10),
                output: Some(20),
                reasoning: Some(3),
                cache_read: Some(4),
                cache_write: Some(5),
            },
            finish_reason: yuke_ai::FinishReason::Stop,
        }),
        ..step(&blocks)
    };
    store.commit(source, &answer, &[]).await.unwrap();
    store
        .commit(source, &end(&[yuke_ai::Block::user_text("b")]), &[])
        .await
        .unwrap();
    // An old time tells a copied time apart from the time of the fork.
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    connection.execute("UPDATE events SET created_at = 1000", []).unwrap();

    let fork = store.fork_session(source, None).await.unwrap().id;

    assert_eq!(
        commit_rows(&folder, fork),
        [
            r#"["test-model",10,20,3,4,5,1000]"#,
            "[null,null,null,null,null,null,1000]",
        ]
    );
}

#[tokio::test]
async fn a_failed_copy_of_the_blobs_leaves_no_fork() {
    let folder = folder("a_failed_copy_of_the_blobs_leaves_no_fork");
    let store = SqliteStore::open(&folder).await.unwrap();
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store.put_blob(source, b"image".to_vec()).await.unwrap();
    let sessions = folder.join("sessions");
    let source_folder = std::fs::read_dir(&sessions).unwrap().next().unwrap().unwrap().path();
    // A folder in place of a blob file makes the copy fail.
    std::fs::create_dir(source_folder.join("f".repeat(64))).unwrap();

    let fork = store.fork_session(source, None).await;

    assert!(matches!(fork, Err(StoreError::Failed(_))), "{fork:?}");
    assert_eq!(std::fs::read_dir(&sessions).unwrap().count(), 1);
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    let rows: i64 = connection
        .query_row("SELECT count(*) FROM sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 1);
}

#[tokio::test]
async fn a_refused_fork_point_leaves_no_session_row_and_no_folder() {
    let folder = folder("a_refused_fork_point_leaves_no_session_row_and_no_folder");
    let store = SqliteStore::open(&folder).await.unwrap();
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();

    let fork = store.fork_session(source, Some(EventNumber(2))).await;

    assert!(matches!(fork, Err(StoreError::NotACompletedTurn)), "{fork:?}");
    assert_eq!(std::fs::read_dir(folder.join("sessions")).unwrap().count(), 1);
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    let rows: i64 = connection
        .query_row("SELECT count(*) FROM sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 1);
}

#[tokio::test]
async fn a_create_that_cannot_make_its_folder_leaves_no_session_row() {
    let folder = folder("a_create_that_cannot_make_its_folder_leaves_no_session_row");
    let store = SqliteStore::open(&folder).await.unwrap();
    // A file in place of the folder of the session folders makes each new folder fail.
    std::fs::remove_dir(folder.join("sessions")).unwrap();
    std::fs::write(folder.join("sessions"), b"").unwrap();

    let created = store.create_session(&settings("one"), &prompt()).await;

    assert!(matches!(created, Err(StoreError::Failed(_))), "{created:?}");
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    let rows: i64 = connection
        .query_row("SELECT count(*) FROM sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 0);
}

#[tokio::test]
async fn a_failed_transaction_returns_no_receipt_and_keeps_the_input() {
    let folder = folder("a_failed_transaction_returns_no_receipt_and_keeps_the_input");
    let store = SqliteStore::open(&folder).await.unwrap();
    let session = store.create_session(&settings("one"), &prompt()).await.unwrap();
    let blocks = [yuke_ai::Block::user_text("task")];
    let input = store.accept_input(session.id, user_input("task")).await.unwrap();
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    // A deferred constraint lets both statements run, but it makes COMMIT fail.
    connection
        .execute_batch(
            "CREATE TABLE receipt_parent (id INTEGER PRIMARY KEY);
         CREATE TABLE receipt_child (parent INTEGER REFERENCES receipt_parent(id) DEFERRABLE INITIALLY DEFERRED);
         CREATE TRIGGER reject_commit AFTER DELETE ON pending_inputs
         BEGIN INSERT INTO receipt_child VALUES (1); END;",
        )
        .unwrap();

    let error = store
        .commit(session.id, &end(&blocks), &[consumed(input, 1)])
        .await
        .unwrap_err();
    assert!(
        std::error::Error::source(&error)
            .unwrap()
            .to_string()
            .contains("FOREIGN KEY constraint failed"),
        "{error}"
    );
    assert_eq!(
        store
            .load(session.id, EventPage::After(None))
            .await
            .map(|loaded| loaded.events)
            .unwrap()
            .len(),
        1
    );
    let pending = store.pending(session.id).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, input);
    assert_eq!(pending[0].input, user_input("task"));

    connection.execute_batch("DROP TRIGGER reject_commit;").unwrap();
    let receipt = store
        .commit(session.id, &end(&blocks), &[consumed(input, 1)])
        .await
        .unwrap();
    assert_eq!(receipt, EventNumber(2));
    assert_eq!(store.pending(session.id).await.unwrap(), []);
    let id = session.id;
    drop(session);
    drop(store);
    let reopened = SqliteStore::open(&folder).await.unwrap();
    let events = reopened
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    assert_eq!(events.last().unwrap().event_number, EventNumber(2));
}

#[tokio::test]
async fn a_saved_input_without_content_does_not_load() {
    let folder = folder("a_saved_input_without_content_does_not_load");
    let store = SqliteStore::open(&folder).await.unwrap();
    let session = store.create_session(&settings("one"), &prompt()).await.unwrap();
    let connection = rusqlite::Connection::open(folder.join("yuke.db")).unwrap();
    connection
        .execute(
            r#"INSERT INTO pending_inputs(session_id, input) VALUES (?1, '{"source":{"kind":"user"},"kind":"message","content":[]}')"#,
            [session.id.as_bytes().as_slice()],
        )
        .unwrap();

    let error = store.pending(session.id).await.unwrap_err();

    let causes: Vec<String> = std::iter::successors(Some(&error as &dyn std::error::Error), |error| error.source())
        .map(ToString::to_string)
        .collect();
    assert!(
        causes.iter().any(|cause| cause.contains("the input has no content")),
        "{causes:?}"
    );
}
