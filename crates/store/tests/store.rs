//! The shared store behaviors, and the behaviors of the file: a reopen, and the owner lock across two stores.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::future::Future;
use std::path::PathBuf;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use yuke_agent::testing::{consumed, end, prompt, settings, step, user_input};
use yuke_agent::{Access, EventPage, Store, StoreError};
use yuke_engine::{Answer, Commit};
use yuke_protocol::{EventNumber, SessionTitle};
use yuke_store::FileStore;

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("store", name)
}

/// The log of session `id` in the store folder `folder`.
fn log_of(folder: &std::path::Path, id: yuke_protocol::SessionId) -> PathBuf {
    folder
        .join("sessions")
        .join(format!("{:032x}", u128::from_be_bytes(*id.as_bytes())))
        .join("events.jsonl")
}

async fn make_store(name: &str) -> std::sync::Arc<FileStore> {
    std::sync::Arc::new(FileStore::open(folder(name)).await.unwrap())
}

yuke_agent::store_tests!(make_store);

#[tokio::test]
async fn a_session_survives_a_close_and_an_open_of_the_file() {
    let folder = folder("a_session_survives_a_close_and_an_open_of_the_file");
    let first = FileStore::open(&folder).await.unwrap();
    let opened = first.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    first.set_settings(id, &settings("two")).await.unwrap();
    first
        .commit(id, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    let input = first.accept_input(id, user_input("b")).await.unwrap();
    first
        .rename_session(id, &SessionTitle::new("Saved title").unwrap())
        .await
        .unwrap();
    drop(opened);
    drop(first);

    let second = FileStore::open(&folder).await.unwrap();
    let opened = second.open(id, Access::Write).await.unwrap();

    assert_eq!(
        second.session_summary(id).await.unwrap().title.as_deref(),
        Some("Saved title")
    );
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
    let first = FileStore::open(&folder).await.unwrap();
    let second = FileStore::open(&folder).await.unwrap();
    let opened = first.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    // A writer outside the stores holds the store lock, so the commit of the first store waits on its thread.
    let blocker = std::fs::OpenOptions::new()
        .write(true)
        .open(folder.join("store.lock"))
        .unwrap();
    blocker.lock().unwrap();

    let blocks = [yuke_ai::Block::user_text("queued")];
    {
        // A turn end writes the index. A step of a turn writes only the log, so it would not wait.
        let commit = end(&blocks);
        let mut future = pin!(first.commit(id, &commit, &[]));
        // The first poll sends the write to the connection. The write stays in the queue after the future drops.
        let poll = future.as_mut().poll(&mut Context::from_waker(Waker::noop()));
        assert!(matches!(poll, Poll::Pending), "{poll:?}");
    }
    drop(opened);
    let during = second.open(id, Access::Write).await;
    // A lease from this open would hold the session, so check it before the next open.
    assert!(matches!(during, Err(StoreError::Owned)), "{during:?}");
    blocker.unlock().unwrap();
    // A read runs after the queued write on the same connection.
    first.pending(id).await.unwrap();
    let after = second.open(id, Access::Write).await.unwrap();

    assert_eq!(after.context, blocks);
}

#[tokio::test]
async fn a_delete_removes_the_folder_of_the_session() {
    let folder = folder("a_delete_removes_the_folder_of_the_session");
    let store = FileStore::open(&folder).await.unwrap();
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let store = FileStore::open(&folder).await.unwrap();
    let id = yuke_protocol::SessionId::generate();

    let open = store.open(id, Access::Write).await;

    assert!(matches!(open, Err(StoreError::NotFound)), "{open:?}");
    let folders = std::fs::read_dir(folder.join("sessions")).map_or(0, Iterator::count);
    assert_eq!(folders, 0);
}

#[tokio::test]
async fn the_sweep_removes_a_folder_without_a_log_and_keeps_a_locked_one() {
    let folder = folder("the_sweep_removes_a_folder_without_a_log_and_keeps_a_locked_one");
    drop(FileStore::open(&folder).await.unwrap());
    // This folder has no log, as after a crash during a delete.
    let left = folder.join("sessions").join("0123456789abcdef0123456789abcdef");
    std::fs::create_dir_all(&left).unwrap();
    std::fs::write(left.join("blob"), b"image").unwrap();
    // This folder has no log, and its lock is held, as during a create in another process.
    let deleting = folder.join("sessions").join("fedcba9876543210fedcba9876543210");
    std::fs::create_dir_all(&deleting).unwrap();
    let lock = std::fs::File::create(deleting.join("lock")).unwrap();
    lock.try_lock().unwrap();

    drop(FileStore::open(&folder).await.unwrap());

    assert!(!left.exists());
    assert!(deleting.exists());
}

// An index that this yuke cannot read, such as one of another version, must not cost the sessions.
#[tokio::test]
async fn a_lost_index_removes_no_session_folder() {
    let folder = folder("a_lost_index_removes_no_session_folder");
    let store = FileStore::open(&folder).await.unwrap();
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    drop(store);
    let log = std::fs::read(log_of(&folder, id)).unwrap();
    std::fs::remove_file(folder.join("sessions.jsonl")).unwrap();

    drop(FileStore::open(&folder).await.unwrap());

    assert_eq!(std::fs::read(log_of(&folder, id)).unwrap(), log);
}

// A change of the event format makes an old line unreadable. The open must fail, not cut the events after it.
#[tokio::test]
async fn a_complete_line_that_is_not_an_event_fails_the_open_and_keeps_the_log() {
    let folder = folder("a_complete_line_that_is_not_an_event_fails_the_open_and_keeps_the_log");
    let store = FileStore::open(&folder).await.unwrap();
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    for text in ["a", "b"] {
        store
            .commit(id, &step(&[yuke_ai::Block::user_text(text)]), &[])
            .await
            .unwrap();
    }
    drop(opened);
    let log = log_of(&folder, id);
    let changed = std::fs::read_to_string(&log)
        .unwrap()
        .replacen(r#""kind":"commit""#, r#""kind":"newCommit""#, 1);
    std::fs::write(&log, &changed).unwrap();

    let written = store.open(id, Access::Write).await;

    assert!(matches!(written, Err(StoreError::Failed(_))), "{written:?}");
    assert_eq!(std::fs::read_to_string(&log).unwrap(), changed);
}

#[tokio::test]
async fn a_fork_keeps_the_token_usage_of_each_copied_commit() {
    let folder = folder("a_fork_keeps_the_token_usage_of_each_copied_commit");
    let store = FileStore::open(&folder).await.unwrap();
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let fork = store.fork_session(source, None).await.unwrap().id;

    // The log keeps no time of an event, so a fork keeps the copied lines as they are.
    let forked = store.load(fork, EventPage::After(None)).await.unwrap().events;
    let copied = store.load(source, EventPage::After(None)).await.unwrap().events;
    assert_eq!(forked, copied);
}

#[tokio::test]
async fn a_failed_copy_of_the_blobs_leaves_no_fork() {
    let folder = folder("a_failed_copy_of_the_blobs_leaves_no_fork");
    let store = FileStore::open(&folder).await.unwrap();
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store.put_blob(source, b"image".to_vec()).await.unwrap();
    let sessions = folder.join("sessions");
    let source_folder = std::fs::read_dir(&sessions).unwrap().next().unwrap().unwrap().path();
    // A folder in place of a blob file makes the copy fail.
    std::fs::create_dir(source_folder.join("f".repeat(64))).unwrap();

    let fork = store.fork_session(source, None).await;

    assert!(matches!(fork, Err(StoreError::Failed(_))), "{fork:?}");
    assert_eq!(std::fs::read_dir(&sessions).unwrap().count(), 1);
    assert_eq!(
        store.list_sessions(None, None, None, 10).await.unwrap().sessions.len(),
        1
    );
}

#[tokio::test]
async fn a_fork_copies_only_the_blob_files() {
    let folder = folder("a_fork_copies_only_the_blob_files");
    let store = FileStore::open(&folder).await.unwrap();
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let blob = store.put_blob(source, b"image".to_vec()).await.unwrap();
    let sessions = folder.join("sessions");
    let source_folder = std::fs::read_dir(&sessions).unwrap().next().unwrap().unwrap().path();
    // A file manager can add a file of its own to the folder.
    std::fs::write(source_folder.join(".DS_Store"), b"x").unwrap();

    store.fork_session(source, None).await.unwrap();

    let fork_folder = std::fs::read_dir(&sessions)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| *path != source_folder)
        .unwrap();
    let mut names: Vec<String> = std::fs::read_dir(&fork_folder)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    let mut expected = vec![blob.digest.to_string(), "events.jsonl".to_owned(), "lock".to_owned()];
    expected.sort();
    assert_eq!(names, expected);
}

#[tokio::test]
async fn a_refused_fork_point_leaves_no_session_and_no_folder() {
    let folder = folder("a_refused_fork_point_leaves_no_session_and_no_folder");
    let store = FileStore::open(&folder).await.unwrap();
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();

    let fork = store.fork_session(source, Some(EventNumber(2))).await;

    assert!(matches!(fork, Err(StoreError::NotACompletedTurn)), "{fork:?}");
    assert_eq!(std::fs::read_dir(folder.join("sessions")).unwrap().count(), 1);
    assert_eq!(
        store.list_sessions(None, None, None, 10).await.unwrap().sessions.len(),
        1
    );
}

#[tokio::test]
async fn a_create_that_cannot_make_its_folder_leaves_no_session() {
    let folder = folder("a_create_that_cannot_make_its_folder_leaves_no_session");
    let store = FileStore::open(&folder).await.unwrap();
    // A file in place of the folder of the session folders makes each new folder fail.
    std::fs::remove_dir(folder.join("sessions")).unwrap();
    std::fs::write(folder.join("sessions"), b"").unwrap();

    let created = store.create_session(&settings("one"), &prompt(), None).await;

    assert!(matches!(created, Err(StoreError::Failed(_))), "{created:?}");
    assert!(folder.join("sessions").is_file());
}

#[tokio::test]
async fn a_failed_append_to_the_index_returns_no_receipt_and_keeps_the_input() {
    let folder = folder("a_failed_append_to_the_index_returns_no_receipt_and_keeps_the_input");
    let store = FileStore::open(&folder).await.unwrap();
    let session = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let blocks = [yuke_ai::Block::user_text("task")];
    let input = store.accept_input(session.id, user_input("task")).await.unwrap();
    let index = folder.join("sessions.jsonl");
    let saved = folder.join("sessions.jsonl.saved");
    // A folder in place of the index makes the read and the append of the index fail.
    std::fs::rename(&index, &saved).unwrap();
    std::fs::create_dir(&index).unwrap();

    let error = store
        .commit(session.id, &end(&blocks), &[consumed(input, 1)])
        .await
        .unwrap_err();
    assert!(matches!(error, StoreError::Failed(_)), "{error}");
    std::fs::remove_dir(&index).unwrap();
    std::fs::rename(&saved, &index).unwrap();
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

    let receipt = store
        .commit(session.id, &end(&blocks), &[consumed(input, 1)])
        .await
        .unwrap();
    assert_eq!(receipt, EventNumber(2));
    assert_eq!(store.pending(session.id).await.unwrap(), []);
    let id = session.id;
    drop(session);
    drop(store);
    let reopened = FileStore::open(&folder).await.unwrap();
    let events = reopened
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    assert_eq!(events.last().unwrap().event_number, EventNumber(2));
}

/// The milliseconds since 1970.
fn now_ms() -> u64 {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap()
}

#[tokio::test]
async fn each_line_of_the_log_holds_the_millisecond_of_its_write() {
    let folder = folder("each_line_of_the_log_holds_the_millisecond_of_its_write");
    let store = FileStore::open(&folder).await.unwrap();
    let before = now_ms();
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    let after = now_ms();
    let log = folder
        .join("sessions")
        .join(format!("{:032x}", u128::from_be_bytes(*id.as_bytes())))
        .join("events.jsonl");

    let text = std::fs::read_to_string(log).unwrap();
    let times: Vec<u64> = text
        .lines()
        .map(|line| {
            let at = line.split_once(",\"at\":").unwrap().1;
            at[..at.find(',').unwrap()].parse().unwrap()
        })
        .collect();
    assert_eq!(times.len(), 2);
    assert!(times.iter().all(|&at| (before..=after).contains(&at)));
    drop(opened);
}

#[tokio::test]
async fn a_torn_line_of_a_crash_reads_as_no_event_and_the_next_writer_cuts_it() {
    let folder = folder("a_torn_line_of_a_crash_reads_as_no_event_and_the_next_writer_cuts_it");
    let store = FileStore::open(&folder).await.unwrap();
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("kept")]), &[])
        .await
        .unwrap();
    drop(opened);
    let log = log_of(&folder, id);
    let complete = std::fs::metadata(&log).unwrap().len();
    let mut file = std::fs::OpenOptions::new().append(true).open(&log).unwrap();
    std::io::Write::write_all(&mut file, br#"{"seq":3,"kind":"comm"#).unwrap();
    drop(file);

    let read = store.open(id, Access::Read).await.unwrap();
    assert_eq!(read.context, [yuke_ai::Block::user_text("kept")]);
    let written = store.open(id, Access::Write).await.unwrap();
    assert_eq!(std::fs::metadata(&log).unwrap().len(), complete);
    let next = store
        .commit(id, &step(&[yuke_ai::Block::user_text("next")]), &[])
        .await
        .unwrap();
    assert_eq!(next, EventNumber(3));
    drop(written);
}

#[tokio::test]
async fn an_input_that_a_crash_left_in_the_index_after_its_line_is_not_pending_and_the_next_writer_removes_it() {
    let folder = folder("an_input_left_in_the_index_by_a_crash");
    let store = FileStore::open(&folder).await.unwrap();
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    let input = store.accept_input(id, user_input("task")).await.unwrap();
    let index = folder.join("sessions.jsonl");
    let saved = std::fs::read(&index).unwrap();
    store
        .commit(id, &end(&[yuke_ai::Block::user_text("task")]), &[consumed(input, 1)])
        .await
        .unwrap();
    drop(opened);
    // A crash between the line of the log and the line of the index leaves the input in the index.
    std::fs::write(&index, &saved).unwrap();

    assert_eq!(store.pending(id).await.unwrap().len(), 1);
    let loaded = store.load(id, EventPage::After(None)).await.unwrap();
    assert_eq!(loaded.pending, []);
    let written = store.open(id, Access::Write).await.unwrap();
    assert_eq!(store.pending(id).await.unwrap(), []);
    drop(written);
}

#[tokio::test]
async fn a_torn_line_of_the_index_reads_as_no_change_and_the_next_writer_cuts_it() {
    let folder = folder("a_torn_line_of_the_index_reads_as_no_change_and_the_next_writer_cuts_it");
    let store = FileStore::open(&folder).await.unwrap();
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;
    let index = folder.join("sessions.jsonl");
    let complete = std::fs::metadata(&index).unwrap().len();
    let mut file = std::fs::OpenOptions::new().append(true).open(&index).unwrap();
    std::io::Write::write_all(&mut file, br#"{"id":"0","dele"#).unwrap();
    drop(file);

    let other = FileStore::open(&folder).await.unwrap();
    assert_eq!(
        other.list_sessions(None, None, None, 10).await.unwrap().sessions.len(),
        1
    );
    other
        .rename_session(id, &SessionTitle::new("kept").unwrap())
        .await
        .unwrap();

    let bytes = std::fs::read(&index).unwrap();
    assert!(!bytes[usize::try_from(complete).unwrap()..].starts_with(br#"{"id":"0""#));
    let summary = store.session_summary(id).await.unwrap();
    assert_eq!(summary.title.unwrap().to_string(), "kept");
    drop(opened);
}
