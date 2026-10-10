//! The shared behavior tests of a [`Store`]. Each function checks one behavior on a new store and panics when the store
//! fails it. [`store_tests!`](crate::store_tests) writes one test for each function.
#![expect(
    clippy::unwrap_used,
    clippy::missing_panics_doc,
    reason = "a behavior test fails by panicking"
)]

use yuke_engine::{Commit, Outcome, Replaced, TurnEnd};

use crate::store::{Access, ModelReference, SessionId, SessionSettings, Store, StoreError};

/// Write one `#[tokio::test]` for each behavior of this module. `$make_store` is an async function that takes the
/// name of the test and returns a new store, such as an `Arc<impl Store>`. The calling crate needs `tokio` with the
/// `macros` and `rt` features.
#[macro_export]
macro_rules! store_tests {
    ($make_store:path) => {
        $crate::store_tests!(
            @behaviors $make_store;
            a_new_session_opens_with_its_settings_and_no_history,
            a_commit_adds_its_blocks_to_the_context,
            a_replacement_keeps_its_head_and_the_last_blocks,
            a_replacement_that_keeps_nothing_leaves_its_head,
            a_second_replacement_keeps_blocks_from_before_the_first,
            a_turn_is_open_until_its_end_commit,
            a_second_writer_gets_owned,
            a_dropped_lease_lets_a_new_writer_open,
            a_reader_opens_while_a_writer_holds_the_session,
            a_reader_holds_no_lock,
            a_pending_input_stays_until_a_commit_consumes_it,
            a_consumed_input_id_is_not_given_again,
            new_settings_replace_the_old_settings,
            an_unknown_session_is_not_found,
        );
    };
    (@behaviors $make_store:path; $($behavior:ident),* $(,)?) => {
        $(
            #[::tokio::test]
            async fn $behavior() {
                let store = $make_store(stringify!($behavior)).await;
                $crate::testing::$behavior(&*store).await;
            }
        )*
    };
}

/// Settings with the system prompt `system`.
fn settings(system: &str) -> SessionSettings {
    SessionSettings {
        model: ModelReference::new("test", "test-model"),
        settings: yuke_ai::Settings {
            system: system.to_owned(),
            ..yuke_ai::Settings::new()
        },
    }
}

/// A commit in the middle of a turn.
fn step(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit {
        replaced: None,
        blocks,
        answer: None,
        end: None,
    }
}

/// A commit that ends a turn.
fn end(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit {
        end: Some(TurnEnd::Outcome(Outcome::Completed {
            finish_reason: yuke_ai::FinishReason::Stop,
        })),
        ..step(blocks)
    }
}

/// A new session opens with its settings, an empty context, no pending input, and no open turn.
pub async fn a_new_session_opens_with_its_settings_and_no_history(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;

    let opened = store.open(id, Access::Read).await.unwrap();

    assert_eq!(opened.settings, settings("one"));
    assert_eq!(opened.context, []);
    assert!(!opened.turn_open);
    assert_eq!(store.pending(id).await.unwrap(), []);
}

/// Each commit adds its blocks after the blocks of the earlier commits.
pub async fn a_commit_adds_its_blocks_to_the_context(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;

    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    store
        .commit(id, &end(&[yuke_ai::Block::assistant_text("two")]), &[])
        .await
        .unwrap();

    let opened = store.open(id, Access::Read).await.unwrap();
    assert_eq!(
        opened.context,
        [yuke_ai::Block::user_text("one"), yuke_ai::Block::assistant_text("two")]
    );
}

/// A replacement makes its head the start of the context, keeps the last blocks, and the next commit adds after them.
pub async fn a_replacement_keeps_its_head_and_the_last_blocks(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;
    let first = [
        yuke_ai::Block::user_text("a"),
        yuke_ai::Block::assistant_text("b"),
        yuke_ai::Block::user_text("c"),
    ];
    store.commit(id, &step(&first), &[]).await.unwrap();
    let head = [yuke_ai::Block::user_text("summary")];

    let replacement = Commit {
        replaced: Some(Replaced { head: &head, keep: 1 }),
        ..step(&[])
    };
    store.commit(id, &replacement, &[]).await.unwrap();
    store
        .commit(id, &end(&[yuke_ai::Block::assistant_text("d")]), &[])
        .await
        .unwrap();

    let opened = store.open(id, Access::Read).await.unwrap();
    assert_eq!(
        opened.context,
        [
            yuke_ai::Block::user_text("summary"),
            yuke_ai::Block::user_text("c"),
            yuke_ai::Block::assistant_text("d")
        ]
    );
}

/// A replacement that keeps no block leaves only its head.
pub async fn a_replacement_that_keeps_nothing_leaves_its_head(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;
    store
        .commit(
            id,
            &step(&[yuke_ai::Block::user_text("a"), yuke_ai::Block::assistant_text("b")]),
            &[],
        )
        .await
        .unwrap();
    let head = [yuke_ai::Block::user_text("new")];

    let replacement = Commit {
        replaced: Some(Replaced { head: &head, keep: 0 }),
        ..step(&[])
    };
    store.commit(id, &replacement, &[]).await.unwrap();

    assert_eq!(store.open(id, Access::Read).await.unwrap().context, head);
}

/// A second replacement can keep blocks that the first replacement kept and the end of the first head.
pub async fn a_second_replacement_keeps_blocks_from_before_the_first(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;
    let first = [yuke_ai::Block::user_text("a"), yuke_ai::Block::assistant_text("b")];
    store.commit(id, &step(&first), &[]).await.unwrap();
    let first_head = [
        yuke_ai::Block::user_text("summary one"),
        yuke_ai::Block::assistant_text("noted"),
    ];
    let first_replacement = Commit {
        replaced: Some(Replaced {
            head: &first_head,
            keep: 1,
        }),
        ..step(&[])
    };
    store.commit(id, &first_replacement, &[]).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("c")]), &[])
        .await
        .unwrap();
    let second_head = [yuke_ai::Block::user_text("summary two")];

    let second_replacement = Commit {
        replaced: Some(Replaced {
            head: &second_head,
            keep: 3,
        }),
        ..step(&[])
    };
    store.commit(id, &second_replacement, &[]).await.unwrap();
    store
        .commit(id, &end(&[yuke_ai::Block::assistant_text("d")]), &[])
        .await
        .unwrap();

    let opened = store.open(id, Access::Read).await.unwrap();
    assert_eq!(
        opened.context,
        [
            yuke_ai::Block::user_text("summary two"),
            yuke_ai::Block::assistant_text("noted"),
            yuke_ai::Block::assistant_text("b"),
            yuke_ai::Block::user_text("c"),
            yuke_ai::Block::assistant_text("d")
        ]
    );
}

/// A turn is open after a commit without an end, and closed after a commit with an end.
pub async fn a_turn_is_open_until_its_end_commit(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;

    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    let during = store.open(id, Access::Read).await.unwrap().turn_open;
    store.commit(id, &end(&[]), &[]).await.unwrap();
    let after = store.open(id, Access::Read).await.unwrap().turn_open;

    assert!(during);
    assert!(!after);
}

/// A second writer of a session gets [`StoreError::Owned`] while the first writer holds its lease.
pub async fn a_second_writer_gets_owned(store: &dyn Store) {
    let opened = store.create_session(&settings("one")).await.unwrap();

    let second = store.open(opened.id, Access::Write).await;

    assert!(matches!(second, Err(StoreError::Owned)), "{second:?}");
}

/// The drop of a lease lets a new writer open the session.
pub async fn a_dropped_lease_lets_a_new_writer_open(store: &dyn Store) {
    let opened = store.create_session(&settings("one")).await.unwrap();
    let id = opened.id;

    drop(opened);
    let again = store.open(id, Access::Write).await;

    assert!(again.is_ok(), "{again:?}");
}

/// A reader opens a session that a writer holds.
pub async fn a_reader_opens_while_a_writer_holds_the_session(store: &dyn Store) {
    let opened = store.create_session(&settings("one")).await.unwrap();

    let read = store.open(opened.id, Access::Read).await;

    assert!(read.is_ok(), "{read:?}");
}

/// A read open holds no lock, so a writer opens while the reader holds its open session.
pub async fn a_reader_holds_no_lock(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;
    let _read = store.open(id, Access::Read).await.unwrap();

    let write = store.open(id, Access::Write).await;

    assert!(write.is_ok(), "{write:?}");
}

/// An accepted input is pending, in id order, until a commit consumes it.
pub async fn a_pending_input_stays_until_a_commit_consumes_it(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;
    let first = store
        .accept_input(id, &[yuke_ai::Block::user_text("one")])
        .await
        .unwrap();
    let second = store
        .accept_input(id, &[yuke_ai::Block::user_text("two")])
        .await
        .unwrap();

    let before = store.pending(id).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("two")]), &[second])
        .await
        .unwrap();
    let after = store.pending(id).await.unwrap();

    let ids: Vec<_> = before.iter().map(|input| input.id).collect();
    assert_eq!(ids, [first, second]);
    assert_eq!(before[1].blocks, [yuke_ai::Block::user_text("two")]);
    let ids: Vec<_> = after.iter().map(|input| input.id).collect();
    assert_eq!(ids, [first]);
}

/// The id of a consumed input does not go to a new input, also when the consumed input was the newest one.
pub async fn a_consumed_input_id_is_not_given_again(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;
    let first = store
        .accept_input(id, &[yuke_ai::Block::user_text("one")])
        .await
        .unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[first])
        .await
        .unwrap();

    let second = store
        .accept_input(id, &[yuke_ai::Block::user_text("two")])
        .await
        .unwrap();

    assert!(second > first, "{second:?} after {first:?}");
}

/// New settings replace the settings that a session opens with.
pub async fn new_settings_replace_the_old_settings(store: &dyn Store) {
    let id = store.create_session(&settings("one")).await.unwrap().id;

    store.set_settings(id, &settings("two")).await.unwrap();

    assert_eq!(store.open(id, Access::Read).await.unwrap().settings, settings("two"));
}

/// Each method on a session that the store lacks gets [`StoreError::NotFound`].
pub async fn an_unknown_session_is_not_found(store: &dyn Store) {
    let id = SessionId::generate();

    let open = store.open(id, Access::Read).await;
    let settings = store.set_settings(id, &settings("one")).await;
    let input = store.accept_input(id, &[yuke_ai::Block::user_text("one")]).await;
    let commit = store.commit(id, &step(&[]), &[]).await;
    let pending = store.pending(id).await;

    assert!(matches!(open, Err(StoreError::NotFound)), "{open:?}");
    assert!(matches!(settings, Err(StoreError::NotFound)), "{settings:?}");
    assert!(matches!(input, Err(StoreError::NotFound)), "{input:?}");
    assert!(matches!(commit, Err(StoreError::NotFound)), "{commit:?}");
    assert!(matches!(pending, Err(StoreError::NotFound)), "{pending:?}");
}
