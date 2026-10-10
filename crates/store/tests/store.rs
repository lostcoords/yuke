//! The shared store behaviors, and the behaviors of the file: a reopen, and the owner lock across two stores.
#![expect(clippy::unwrap_used, clippy::panic, reason = "a test fails by panicking")]

use std::future::Future;
use std::path::PathBuf;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use tokio_rusqlite::rusqlite;
use yuke_agent::{Access, ModelReference, SessionSettings, Store, StoreError};
use yuke_engine::Commit;
use yuke_store::SqliteStore;

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("yuke-store").join(name);
    match std::fs::remove_dir_all(&folder) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => panic!("{}: {error}", folder.display()),
    }
    folder
}

async fn make_store(name: &str) -> std::sync::Arc<SqliteStore> {
    std::sync::Arc::new(SqliteStore::open(folder(name)).await.unwrap())
}

yuke_agent::store_tests!(make_store);

fn settings(system: &str) -> SessionSettings {
    SessionSettings {
        model: ModelReference::new("test", "test-model"),
        settings: yuke_ai::Settings {
            system: system.to_owned(),
            ..yuke_ai::Settings::new()
        },
    }
}

fn step(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit {
        replaced: None,
        blocks,
        answer: None,
        end: None,
    }
}

#[tokio::test]
async fn a_session_survives_a_close_and_an_open_of_the_file() {
    let folder = folder("a_session_survives_a_close_and_an_open_of_the_file");
    let first = SqliteStore::open(&folder).await.unwrap();
    let opened = first.create_session(&settings("one")).await.unwrap();
    let id = opened.id;
    first.set_settings(id, &settings("two")).await.unwrap();
    first
        .commit(id, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    let input = first.accept_input(id, &[yuke_ai::Block::user_text("b")]).await.unwrap();
    drop(opened);
    drop(first);

    let second = SqliteStore::open(&folder).await.unwrap();
    let opened = second.open(id, Access::Write).await.unwrap();

    assert_eq!(opened.settings, settings("two"));
    assert_eq!(opened.context, [yuke_ai::Block::user_text("a")]);
    assert!(opened.turn_open);
    let pending = second.pending(id).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, input);
    assert_eq!(pending[0].blocks, [yuke_ai::Block::user_text("b")]);
}

#[tokio::test]
async fn a_queued_write_finishes_before_the_lock_releases() {
    let folder = folder("a_queued_write_finishes_before_the_lock_releases");
    let first = SqliteStore::open(&folder).await.unwrap();
    let second = SqliteStore::open(&folder).await.unwrap();
    let opened = first.create_session(&settings("one")).await.unwrap();
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
