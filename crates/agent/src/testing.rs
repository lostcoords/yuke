//! The shared behavior tests of a [`Store`]. Each function checks one behavior on a new store and panics when the store
//! fails it. [`store_tests!`](crate::store_tests) writes one test for each function.
#![expect(
    clippy::unwrap_used,
    clippy::missing_panics_doc,
    reason = "a behavior test fails by panicking"
)]

use std::borrow::Cow;
use std::path::{Path, PathBuf};

use yuke_engine::{Answer, Commit, Outcome, Replaced, TurnEnd};

use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, InputKind, InputSource, ModelReference, PendingInput, SessionEvent,
    SessionId, SessionSettings, StoredEvent,
};

use crate::PromptSection;
use crate::store::{Access, NewestTurn, Store, StoreError, blob_of};

/// Write one `#[tokio::test]` for each behavior of this module. `$make_store` is an async function that takes the
/// name of the test and returns a new store, such as an `Arc<impl Store>`. The calling crate needs `tokio` with the
/// `macros` and `rt` features.
#[macro_export]
macro_rules! store_tests {
    ($make_store:path) => {
        $crate::store_tests!(
            @behaviors $make_store;
            a_new_session_opens_with_its_settings_and_no_context,
            a_session_keeps_its_prompt_and_a_fork_copies_it,
            a_commit_adds_its_blocks_to_the_context,
            a_replacement_keeps_its_head_and_the_last_blocks,
            a_replacement_that_keeps_nothing_leaves_its_head,
            a_second_replacement_keeps_blocks_from_before_the_first,
            a_turn_is_open_until_its_end_commit,
            the_newest_turn_keeps_a_cancelled_or_failed_end,
            a_second_writer_gets_owned,
            a_dropped_lease_lets_a_new_writer_open,
            a_reader_opens_while_a_writer_holds_the_session,
            a_reader_holds_no_lock,
            a_pending_input_stays_until_a_commit_consumes_it,
            a_consumed_input_id_is_not_given_again,
            a_commit_of_an_input_that_is_not_pending_saves_nothing,
            a_commit_with_fewer_blocks_than_its_inputs_saves_nothing,
            a_load_gives_the_events_with_the_inputs_that_are_still_pending,
            new_settings_give_the_number_of_their_event,
            a_removed_input_is_not_pending_and_cannot_be_removed_or_consumed_again,
            an_input_keeps_its_source_and_both_contents_through_its_commit,
            new_settings_replace_the_old_settings,
            an_unknown_session_is_not_found,
            a_put_blob_reads_back,
            the_same_bytes_give_the_same_blob,
            a_blob_of_another_session_does_not_read,
            a_deleted_session_is_not_found,
            a_delete_of_a_held_session_gets_owned,
            a_fork_has_the_settings_and_the_context_of_its_source_and_no_pending_input,
            a_source_forks_while_its_writer_keeps_its_lease_and_the_fork_has_its_own_lease,
            a_commit_to_a_fork_or_its_source_does_not_change_the_other,
            a_fork_keeps_the_blobs_of_its_source_after_the_delete_of_the_source,
            a_fork_of_a_source_in_a_running_turn_ends_at_its_newest_completed_turn,
            a_fork_at_an_earlier_completed_turn_has_the_context_and_the_settings_of_that_point,
            a_fork_point_that_does_not_end_a_completed_turn_gets_not_a_completed_turn,
            a_source_without_a_completed_turn_forks_to_its_settings_and_an_empty_context,
            a_new_session_has_its_settings_as_its_first_event,
            each_commit_and_each_new_settings_is_the_next_event_and_an_input_is_no_event,
            a_saved_commit_reads_back_equal,
            a_commit_receipt_names_its_saved_event_after_settings_and_a_fork,
            events_after_a_number_are_the_newer_events,
            a_fork_has_the_events_of_its_source_and_numbers_on_from_them,
            each_session_numbers_its_own_events,
            the_context_holds_only_commit_blocks_across_pending_inputs_and_settings_events,
            the_newest_session_of_a_folder_has_the_newest_event,
            a_session_works_in_the_folder_of_its_newest_settings,
            a_fork_is_the_newest_session_of_its_folder,
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

/// A system prompt of one section.
pub fn prompt() -> Vec<PromptSection> {
    vec![PromptSection::new("base", "the prompt")]
}

/// Settings with the model `model` of the test provider.
pub fn settings(model: &str) -> SessionSettings {
    SessionSettings {
        model: ModelReference {
            provider: "test".to_owned(),
            model: model.to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: PathBuf::from("/work"),
    }
}

/// An input of the user with one text block.
pub fn user_input(text: &str) -> Input {
    Input::new(
        InputSource::User,
        InputKind::Message,
        vec![yuke_ai::Block::user_text(text)],
    )
    .unwrap()
}

/// The record of input `id` of the user, consumed with `block_count` model blocks that the user saw too.
pub fn consumed(id: InputId, block_count: usize) -> ConsumedInput {
    ConsumedInput {
        id,
        source: InputSource::User,
        kind: InputKind::Message,
        display_content: None,
        block_count,
    }
}

/// A commit in the middle of a turn.
pub fn step(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit {
        replaced: None,
        blocks: Cow::Borrowed(blocks),
        answer: None,
        end: None,
    }
}

/// A commit that ends a turn as completed.
pub fn end(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit {
        end: Some(TurnEnd::Outcome(Outcome::Completed {
            finish_reason: yuke_ai::FinishReason::Stop,
        })),
        ..step(blocks)
    }
}

/// A new session opens with its settings, an empty context, no pending input, and no open turn.
pub async fn a_new_session_opens_with_its_settings_and_no_context(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

    let opened = store.open(id, Access::Read).await.unwrap();

    assert_eq!(opened.settings, settings("one"));
    assert_eq!(opened.context, []);
    assert!(!opened.newest_turn.is_open());
    assert_eq!(store.pending(id).await.unwrap(), []);
}

/// A session keeps the sections of its prompt in order after a settings change, and a fork copies them.
pub async fn a_session_keeps_its_prompt_and_a_fork_copies_it(store: &dyn Store) {
    let sections = [
        PromptSection::new("base", "the first prompt"),
        PromptSection::new("empty", ""),
        PromptSection::new("environment", "the place"),
    ];
    let created = store.create_session(&settings("one"), &sections).await.unwrap();
    let id = created.id;
    store.set_settings(id, &settings("two")).await.unwrap();

    let forked = store.fork_session(id, None).await.unwrap();

    assert_eq!(created.prompt, sections);
    assert_eq!(store.open(id, Access::Read).await.unwrap().prompt, sections);
    assert_eq!(forked.prompt, sections);
    assert_eq!(store.open(forked.id, Access::Read).await.unwrap().prompt, sections);
}

/// Each commit adds its blocks after the blocks of the earlier commits.
pub async fn a_commit_adds_its_blocks_to_the_context(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

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
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let first = [
        yuke_ai::Block::user_text("a"),
        yuke_ai::Block::assistant_text("b"),
        yuke_ai::Block::user_text("c"),
    ];
    store.commit(id, &step(&first), &[]).await.unwrap();
    let head = [yuke_ai::Block::user_text("summary")];

    let replacement = Commit {
        replaced: Some(Replaced {
            head: Cow::Borrowed(&head),
            keep: 1,
        }),
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
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
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
        replaced: Some(Replaced {
            head: Cow::Borrowed(&head),
            keep: 0,
        }),
        ..step(&[])
    };
    store.commit(id, &replacement, &[]).await.unwrap();

    assert_eq!(store.open(id, Access::Read).await.unwrap().context, head);
}

/// A second replacement can keep blocks that the first replacement kept and the end of the first head.
pub async fn a_second_replacement_keeps_blocks_from_before_the_first(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let first = [yuke_ai::Block::user_text("a"), yuke_ai::Block::assistant_text("b")];
    store.commit(id, &step(&first), &[]).await.unwrap();
    let first_head = [
        yuke_ai::Block::user_text("summary one"),
        yuke_ai::Block::assistant_text("noted"),
    ];
    let first_replacement = Commit {
        replaced: Some(Replaced {
            head: Cow::Borrowed(&first_head),
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
            head: Cow::Borrowed(&second_head),
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
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    let during = store.open(id, Access::Read).await.unwrap().newest_turn.is_open();
    store.commit(id, &end(&[]), &[]).await.unwrap();
    let after = store.open(id, Access::Read).await.unwrap().newest_turn.is_open();

    assert!(during);
    assert!(!after);
}

/// An open gives the end of the newest turn, so a session can tell the model how its last turn ended.
pub async fn the_newest_turn_keeps_a_cancelled_or_failed_end(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let newest = || async { store.open(id, Access::Read).await.unwrap().newest_turn };
    let ending = |end: TurnEnd| Commit {
        replaced: None,
        blocks: Cow::Owned(vec![yuke_ai::Block::user_text("one")]),
        answer: None,
        end: Some(end),
    };

    let empty = newest().await;
    store
        .commit(id, &ending(TurnEnd::Outcome(Outcome::Cancelled)), &[])
        .await
        .unwrap();
    let cancelled = newest().await;
    store
        .commit(id, &ending(TurnEnd::Failed("the disk is gone".to_owned())), &[])
        .await
        .unwrap();
    let failed = newest().await;

    assert_eq!(empty, NewestTurn::Empty);
    assert_eq!(cancelled, NewestTurn::Ended(TurnEnd::Outcome(Outcome::Cancelled)));
    assert_eq!(
        failed,
        NewestTurn::Ended(TurnEnd::Failed("the disk is gone".to_owned()))
    );
}

/// A second writer of a session gets [`StoreError::Owned`] while the first writer holds its lease.
pub async fn a_second_writer_gets_owned(store: &dyn Store) {
    let opened = store.create_session(&settings("one"), &prompt()).await.unwrap();

    let second = store.open(opened.id, Access::Write).await;

    assert!(matches!(second, Err(StoreError::Owned)), "{second:?}");
}

/// The drop of a lease lets a new writer open the session.
pub async fn a_dropped_lease_lets_a_new_writer_open(store: &dyn Store) {
    let opened = store.create_session(&settings("one"), &prompt()).await.unwrap();
    let id = opened.id;

    drop(opened);
    let again = store.open(id, Access::Write).await;

    assert!(again.is_ok(), "{again:?}");
}

/// A reader opens a session that a writer holds.
pub async fn a_reader_opens_while_a_writer_holds_the_session(store: &dyn Store) {
    let opened = store.create_session(&settings("one"), &prompt()).await.unwrap();

    let read = store.open(opened.id, Access::Read).await;

    assert!(read.is_ok(), "{read:?}");
}

/// A read open holds no lock, so a writer opens while the reader holds its open session.
pub async fn a_reader_holds_no_lock(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    #[expect(unused_variables, reason = "the read session stays open while the writer opens")]
    let read = store.open(id, Access::Read).await.unwrap();

    let write = store.open(id, Access::Write).await;

    assert!(write.is_ok(), "{write:?}");
}

/// An accepted input is pending, in id order, until a commit consumes it.
pub async fn a_pending_input_stays_until_a_commit_consumes_it(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let first = store.accept_input(id, user_input("one")).await.unwrap();
    let second = store.accept_input(id, user_input("two")).await.unwrap();

    let before = store.pending(id).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("two")]), &[consumed(second, 1)])
        .await
        .unwrap();
    let after = store.pending(id).await.unwrap();

    let ids: Vec<_> = before.iter().map(|input| input.id).collect();
    assert_eq!(ids, [first, second]);
    assert_eq!(before[1].input, user_input("two"));
    let ids: Vec<_> = after.iter().map(|input| input.id).collect();
    assert_eq!(ids, [first]);
}

/// The id of a consumed input does not go to a new input, also when the consumed input was the newest one.
pub async fn a_consumed_input_id_is_not_given_again(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let first = store.accept_input(id, user_input("one")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(first, 1)])
        .await
        .unwrap();

    let second = store.accept_input(id, user_input("two")).await.unwrap();

    assert!(second > first, "{second:?} after {first:?}");
}

/// A commit that consumes an input that is not pending fails, and it saves nothing: no event, and no change of the
/// pending inputs.
pub async fn a_commit_of_an_input_that_is_not_pending_saves_nothing(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let first = store.accept_input(id, user_input("one")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(first, 1)])
        .await
        .unwrap();
    let second = store.accept_input(id, user_input("two")).await.unwrap();
    let events = store.load(id, None).await.map(|loaded| loaded.events).unwrap();

    let again = store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(first, 1)])
        .await;
    // The pending input comes first, so a store that deletes as it goes would delete it before the failure.
    let mixed = store
        .commit(
            id,
            &step(&[yuke_ai::Block::user_text("two"), yuke_ai::Block::user_text("one")]),
            &[consumed(second, 1), consumed(first, 1)],
        )
        .await;

    let twice = store
        .commit(
            id,
            &step(&[yuke_ai::Block::user_text("two"), yuke_ai::Block::user_text("two")]),
            &[consumed(second, 1), consumed(second, 1)],
        )
        .await;

    assert!(
        matches!(again, Err(StoreError::InputNotPending(input)) if input == first),
        "{again:?}"
    );
    assert!(
        matches!(twice, Err(StoreError::InputNotPending(input)) if input == second),
        "{twice:?}"
    );
    assert!(
        matches!(mixed, Err(StoreError::InputNotPending(input)) if input == first),
        "{mixed:?}"
    );
    assert_eq!(store.load(id, None).await.map(|loaded| loaded.events).unwrap(), events);
    let pending: Vec<_> = store.pending(id).await.unwrap().iter().map(|input| input.id).collect();
    assert_eq!(pending, [second]);
}

/// A commit whose consumed inputs have more model blocks than the commit fails, and it saves nothing.
pub async fn a_commit_with_fewer_blocks_than_its_inputs_saves_nothing(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let input = store.accept_input(id, user_input("one")).await.unwrap();
    let events = store.load(id, None).await.map(|loaded| loaded.events).unwrap();

    let short = store.commit(id, &step(&[]), &[consumed(input, 1)]).await;
    let overflow = store
        .commit(
            id,
            &step(&[yuke_ai::Block::user_text("one")]),
            &[consumed(input, usize::MAX), consumed(input, 2)],
        )
        .await;

    assert!(matches!(short, Err(StoreError::InputBlocksExceedCommit)), "{short:?}");
    assert!(
        matches!(overflow, Err(StoreError::InputBlocksExceedCommit)),
        "{overflow:?}"
    );
    assert_eq!(store.load(id, None).await.map(|loaded| loaded.events).unwrap(), events);
    let pending: Vec<_> = store.pending(id).await.unwrap().iter().map(|input| input.id).collect();
    assert_eq!(pending, [input]);
}

/// A load gives the events after a number and the inputs that no commit consumed. A consumed input is in the commit
/// event, not in the pending inputs.
pub async fn a_load_gives_the_events_with_the_inputs_that_are_still_pending(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let first = store.accept_input(id, user_input("one")).await.unwrap();
    let second = store.accept_input(id, user_input("two")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(first, 1)])
        .await
        .unwrap();

    let loaded = store.load(id, Some(EventNumber(1))).await.unwrap();

    assert_eq!(
        loaded.events,
        [StoredEvent {
            event_number: EventNumber(2),
            event: SessionEvent::Commit {
                commit: step(&[yuke_ai::Block::user_text("one")]).into_owned(),
                consumed: vec![consumed(first, 1)],
            },
        }]
    );
    assert_eq!(
        loaded.pending,
        [PendingInput {
            id: second,
            input: user_input("two"),
        }]
    );
}

/// New settings give the number of the event that holds them.
pub async fn new_settings_give_the_number_of_their_event(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store.commit(id, &step(&[]), &[]).await.unwrap();

    let event_number = store.set_settings(id, &settings("two")).await.unwrap();

    assert_eq!(event_number, EventNumber(3));
    let events = store.load(id, Some(EventNumber(2))).await.unwrap().events;
    assert_eq!(
        events,
        [StoredEvent {
            event_number,
            event: SessionEvent::Settings(settings("two")),
        }]
    );
}

/// A removed input leaves the pending inputs. A second removal fails, and so does a commit that consumes it. An input
/// that a commit consumed cannot be removed.
pub async fn a_removed_input_is_not_pending_and_cannot_be_removed_or_consumed_again(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let removed = store.accept_input(id, user_input("one")).await.unwrap();
    let kept = store.accept_input(id, user_input("two")).await.unwrap();

    store.remove_input(id, removed).await.unwrap();
    let again = store.remove_input(id, removed).await;
    let consume = store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(removed, 1)])
        .await;
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("two")]), &[consumed(kept, 1)])
        .await
        .unwrap();
    let consumed_then_removed = store.remove_input(id, kept).await;

    assert!(
        matches!(again, Err(StoreError::InputNotPending(input)) if input == removed),
        "{again:?}"
    );
    assert!(
        matches!(consume, Err(StoreError::InputNotPending(input)) if input == removed),
        "{consume:?}"
    );
    assert!(
        matches!(consumed_then_removed, Err(StoreError::InputNotPending(input)) if input == kept),
        "{consumed_then_removed:?}"
    );
    assert_eq!(store.pending(id).await.unwrap(), []);
}

/// An input keeps its source, its content, and its model content while it is pending. The commit that consumes it
/// keeps the source and the content that the user saw.
pub async fn an_input_keeps_its_source_and_both_contents_through_its_commit(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let source = InputSource::Plugin {
        name: "host:jobs".to_owned(),
    };
    let input = Input::new(
        source.clone(),
        InputKind::Notification,
        vec![yuke_ai::Block::user_text("job-1 finished")],
    )
    .unwrap()
    .with_model_content(vec![yuke_ai::Block::user_text("job-1 ended with exit code 0.")])
    .unwrap();
    let input_id = store.accept_input(id, input.clone()).await.unwrap();

    let pending = store.pending(id).await.unwrap();
    let (record, blocks) = PendingInput {
        id: input_id,
        input: input.clone(),
    }
    .into_consumed();
    store.commit(id, &step(&blocks), &[record]).await.unwrap();

    assert_eq!(pending, [PendingInput { id: input_id, input }]);
    let events = store.load(id, None).await.map(|loaded| loaded.events).unwrap();
    assert_eq!(
        events[1].event,
        SessionEvent::Commit {
            commit: step(&[yuke_ai::Block::user_text("job-1 ended with exit code 0.")]).into_owned(),
            consumed: vec![ConsumedInput {
                id: input_id,
                source,
                kind: InputKind::Notification,
                display_content: Some(vec![yuke_ai::Block::user_text("job-1 finished")]),
                block_count: 1,
            }],
        }
    );
}

/// New settings replace the settings that a session opens with.
pub async fn new_settings_replace_the_old_settings(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

    store.set_settings(id, &settings("two")).await.unwrap();

    assert_eq!(store.open(id, Access::Read).await.unwrap().settings, settings("two"));
}

/// Each method on a session that the store lacks gets [`StoreError::NotFound`].
pub async fn an_unknown_session_is_not_found(store: &dyn Store) {
    let id = SessionId::generate();

    let open = store.open(id, Access::Read).await;
    let settings = store.set_settings(id, &settings("one")).await;
    let input = store.accept_input(id, user_input("one")).await;
    let commit = store.commit(id, &step(&[]), &[]).await;
    let pending = store.pending(id).await;
    let put = store.put_blob(id, b"image".to_vec()).await;
    let read = store.read_blob(id, &blob_of(b"image").digest);
    let delete = store.delete_session(id).await;
    let fork = store.fork_session(id, None).await;
    let fork_at = store.fork_session(id, Some(EventNumber(2))).await;
    let load = store.load(id, None).await;
    let remove = store.remove_input(id, InputId(1)).await;

    assert!(matches!(open, Err(StoreError::NotFound)), "{open:?}");
    assert!(matches!(settings, Err(StoreError::NotFound)), "{settings:?}");
    assert!(matches!(input, Err(StoreError::NotFound)), "{input:?}");
    assert!(matches!(commit, Err(StoreError::NotFound)), "{commit:?}");
    assert!(matches!(pending, Err(StoreError::NotFound)), "{pending:?}");
    assert!(matches!(put, Err(StoreError::NotFound)), "{put:?}");
    assert!(matches!(read, Err(StoreError::NotFound)), "{read:?}");
    assert!(matches!(delete, Err(StoreError::NotFound)), "{delete:?}");
    assert!(matches!(fork, Err(StoreError::NotFound)), "{fork:?}");
    assert!(matches!(fork_at, Err(StoreError::NotFound)), "{fork_at:?}");
    assert!(matches!(load, Err(StoreError::NotFound)), "{load:?}");
    assert!(matches!(remove, Err(StoreError::NotFound)), "{remove:?}");
}

/// A put returns the digest and the length of the bytes, and the blob reads back.
pub async fn a_put_blob_reads_back(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

    let blob = store.put_blob(id, b"image".to_vec()).await.unwrap();

    // The SHA-256 of "image", as `printf image | shasum -a 256` gives it.
    let digest = [
        0x61, 0x05, 0xd6, 0xcc, 0x76, 0xaf, 0x40, 0x03, 0x25, 0xe9, 0x4d, 0x58, 0x8c, 0xe5, 0x11, 0xbe, 0x5b, 0xfd,
        0xbb, 0x73, 0xb4, 0x37, 0xdc, 0x51, 0xec, 0xa4, 0x39, 0x17, 0xd7, 0xa4, 0x3e, 0x3d,
    ];
    assert_eq!(blob, yuke_ai::Blob { digest, len: 5 });
    assert_eq!(
        store.read_blob(id, &blob.digest).unwrap().as_deref(),
        Some(&b"image"[..])
    );
}

/// A second put of the same bytes gives the same blob, and the blob still reads back.
pub async fn the_same_bytes_give_the_same_blob(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

    let first = store.put_blob(id, b"image".to_vec()).await.unwrap();
    let second = store.put_blob(id, b"image".to_vec()).await.unwrap();

    assert_eq!(first, second);
    assert_eq!(
        store.read_blob(id, &second.digest).unwrap().as_deref(),
        Some(&b"image"[..])
    );
}

/// A blob belongs to the session that put it. Another session has no blob with its digest.
pub async fn a_blob_of_another_session_does_not_read(store: &dyn Store) {
    let owner = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let other = store.create_session(&settings("two"), &prompt()).await.unwrap().id;

    let blob = store.put_blob(owner, b"image".to_vec()).await.unwrap();

    assert_eq!(store.read_blob(other, &blob.digest).unwrap(), None);
}

/// A deleted session is not found, and its pending inputs and its blobs are not found.
pub async fn a_deleted_session_is_not_found(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(id, &end(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    store.accept_input(id, user_input("two")).await.unwrap();
    let blob = store.put_blob(id, b"image".to_vec()).await.unwrap();

    store.delete_session(id).await.unwrap();

    let open = store.open(id, Access::Read).await;
    let pending = store.pending(id).await;
    let read = store.read_blob(id, &blob.digest);
    assert!(matches!(open, Err(StoreError::NotFound)), "{open:?}");
    assert!(matches!(pending, Err(StoreError::NotFound)), "{pending:?}");
    assert!(matches!(read, Err(StoreError::NotFound)), "{read:?}");
}

/// A delete of a session that a writer holds gets [`StoreError::Owned`], and the session stays.
pub async fn a_delete_of_a_held_session_gets_owned(store: &dyn Store) {
    let opened = store.create_session(&settings("one"), &prompt()).await.unwrap();

    let delete = store.delete_session(opened.id).await;

    assert!(matches!(delete, Err(StoreError::Owned)), "{delete:?}");
    assert!(store.open(opened.id, Access::Read).await.is_ok());
}

/// A fork has a new id, and the settings and the context of its source. It has a closed turn and no pending input.
pub async fn a_fork_has_the_settings_and_the_context_of_its_source_and_no_pending_input(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(
            source,
            &step(&[yuke_ai::Block::user_text("a"), yuke_ai::Block::assistant_text("b")]),
            &[],
        )
        .await
        .unwrap();
    // A replacement makes the context depend on the order and the columns of the copied commits.
    let head = [yuke_ai::Block::user_text("summary")];
    let replacement = Commit {
        replaced: Some(Replaced {
            head: Cow::Borrowed(&head),
            keep: 1,
        }),
        ..step(&[])
    };
    store.commit(source, &replacement, &[]).await.unwrap();
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("c")]), &[])
        .await
        .unwrap();
    store.accept_input(source, user_input("d")).await.unwrap();
    let blocks = [
        yuke_ai::Block::user_text("summary"),
        yuke_ai::Block::assistant_text("b"),
        yuke_ai::Block::assistant_text("c"),
    ];

    let fork = store.fork_session(source, None).await.unwrap();

    assert_ne!(fork.id, source);
    assert_eq!(fork.settings, settings("one"));
    assert_eq!(fork.context, blocks);
    assert!(!fork.newest_turn.is_open());
    assert_eq!(store.pending(fork.id).await.unwrap(), []);
    assert_eq!(store.pending(source).await.unwrap().len(), 1);
    let saved = store.open(fork.id, Access::Read).await.unwrap();
    assert_eq!(saved.settings, settings("one"));
    assert_eq!(saved.context, blocks);
}

/// A source forks while its writer keeps its lease. The fork has its own lease, and the source keeps its lease.
pub async fn a_source_forks_while_its_writer_keeps_its_lease_and_the_fork_has_its_own_lease(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap();

    let fork = store.fork_session(source.id, None).await.unwrap();

    assert!(fork.lease.is_some());
    let fork_writer = store.open(fork.id, Access::Write).await;
    let source_writer = store.open(source.id, Access::Write).await;
    assert!(matches!(fork_writer, Err(StoreError::Owned)), "{fork_writer:?}");
    assert!(matches!(source_writer, Err(StoreError::Owned)), "{source_writer:?}");
}

/// A commit to a fork does not change its source, and a commit to the source does not change the fork.
pub async fn a_commit_to_a_fork_or_its_source_does_not_change_the_other(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(source, &end(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    let fork = store.fork_session(source, None).await.unwrap().id;

    store
        .commit(fork, &end(&[yuke_ai::Block::user_text("fork")]), &[])
        .await
        .unwrap();
    store
        .commit(source, &end(&[yuke_ai::Block::user_text("source")]), &[])
        .await
        .unwrap();

    let fork = store.open(fork, Access::Read).await.unwrap().context;
    let source = store.open(source, Access::Read).await.unwrap().context;
    assert_eq!(
        fork,
        [yuke_ai::Block::user_text("a"), yuke_ai::Block::user_text("fork")]
    );
    assert_eq!(
        source,
        [yuke_ai::Block::user_text("a"), yuke_ai::Block::user_text("source")]
    );
}

/// A fork reads each blob of its source, also after the delete of the source.
pub async fn a_fork_keeps_the_blobs_of_its_source_after_the_delete_of_the_source(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap();
    let first = store.put_blob(source.id, b"image".to_vec()).await.unwrap();
    let second = store.put_blob(source.id, b"audio".to_vec()).await.unwrap();
    let fork = store.fork_session(source.id, None).await.unwrap().id;
    let source_id = source.id;

    drop(source);
    store.delete_session(source_id).await.unwrap();

    assert_eq!(
        store.read_blob(fork, &first.digest).unwrap().as_deref(),
        Some(&b"image"[..])
    );
    assert_eq!(
        store.read_blob(fork, &second.digest).unwrap().as_deref(),
        Some(&b"audio"[..])
    );
}

/// A fork of a source in a running turn ends at the newest completed turn: it has neither the running turn nor the
/// settings after the completed turn, and it has no open turn.
pub async fn a_fork_of_a_source_in_a_running_turn_ends_at_its_newest_completed_turn(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("a")]), &[])
        .await
        .unwrap();
    store.set_settings(source, &settings("two")).await.unwrap();
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("running")]), &[])
        .await
        .unwrap();

    let fork = store.fork_session(source, None).await.unwrap();

    assert_eq!(fork.context, [yuke_ai::Block::assistant_text("a")]);
    assert_eq!(fork.settings, settings("one"));
    assert!(!fork.newest_turn.is_open());
    assert_eq!(
        kinds(&store.load(fork.id, None).await.map(|loaded| loaded.events).unwrap()),
        [(1, "settings"), (2, "commit")]
    );
}

/// A fork through an earlier completed turn has the context and the settings of that point.
pub async fn a_fork_at_an_earlier_completed_turn_has_the_context_and_the_settings_of_that_point(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("a")]), &[])
        .await
        .unwrap();
    store.set_settings(source, &settings("two")).await.unwrap();
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("b")]), &[])
        .await
        .unwrap();

    let first = store.fork_session(source, Some(EventNumber(2))).await.unwrap();
    let second = store.fork_session(source, Some(EventNumber(4))).await.unwrap();

    assert_eq!(first.context, [yuke_ai::Block::assistant_text("a")]);
    assert_eq!(first.settings, settings("one"));
    assert_eq!(
        second.context,
        [yuke_ai::Block::assistant_text("a"), yuke_ai::Block::assistant_text("b")]
    );
    assert_eq!(second.settings, settings("two"));
}

/// A fork point that is no end of a completed turn gets [`StoreError::NotACompletedTurn`]: 0, a settings event, a
/// commit in the middle of a turn, a turn that stopped, was cancelled, or failed, and a number after the newest event, also
/// the largest number.
pub async fn a_fork_point_that_does_not_end_a_completed_turn_gets_not_a_completed_turn(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let ends = [
        Some(TurnEnd::Outcome(Outcome::Stopped)),
        Some(TurnEnd::Outcome(Outcome::Cancelled)),
        Some(TurnEnd::Failed("the request failed".to_owned())),
    ];
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    for end in ends {
        store.commit(source, &Commit { end, ..step(&[]) }, &[]).await.unwrap();
    }

    for through in [0, 1, 2, 3, 4, 5, 6, u64::MAX] {
        let fork = store.fork_session(source, Some(EventNumber(through))).await;

        assert!(
            matches!(fork, Err(StoreError::NotACompletedTurn)),
            "{through}: {fork:?}"
        );
    }
}

/// A source with no completed turn forks to the settings before its first commit and an empty context.
pub async fn a_source_without_a_completed_turn_forks_to_its_settings_and_an_empty_context(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store.set_settings(source, &settings("two")).await.unwrap();
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("running")]), &[])
        .await
        .unwrap();
    store.set_settings(source, &settings("three")).await.unwrap();

    let fork = store.fork_session(source, None).await.unwrap();

    assert_eq!(fork.context, []);
    assert_eq!(fork.settings, settings("two"));
    assert!(!fork.newest_turn.is_open());
}

/// The kind of each event, for a short comparison.
fn kinds(events: &[StoredEvent]) -> Vec<(u64, &'static str)> {
    events
        .iter()
        .map(|stored| {
            let kind = match stored.event {
                SessionEvent::Commit { .. } => "commit",
                SessionEvent::Settings(_) => "settings",
            };
            (stored.event_number.0, kind)
        })
        .collect()
}

/// A new session has one event: its settings, with the number 1.
pub async fn a_new_session_has_its_settings_as_its_first_event(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;

    let events = store.load(id, None).await.map(|loaded| loaded.events).unwrap();

    assert_eq!(
        events,
        [StoredEvent {
            event_number: EventNumber(1),
            event: SessionEvent::Settings(settings("one")),
        }]
    );
}

/// A commit and new settings each save the next event. An accepted input saves no event, and the commit that
/// consumes it keeps its record.
pub async fn each_commit_and_each_new_settings_is_the_next_event_and_an_input_is_no_event(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let blocks = [yuke_ai::Block::user_text("one")];

    let input = store.accept_input(id, user_input("one")).await.unwrap();
    let after_input = store.load(id, None).await.map(|loaded| loaded.events).unwrap();
    store.commit(id, &step(&blocks), &[consumed(input, 1)]).await.unwrap();
    store.set_settings(id, &settings("two")).await.unwrap();

    let events = store.load(id, None).await.map(|loaded| loaded.events).unwrap();
    assert_eq!(kinds(&after_input), [(1, "settings")]);
    assert_eq!(kinds(&events), [(1, "settings"), (2, "commit"), (3, "settings")]);
    assert_eq!(
        events[1].event,
        SessionEvent::Commit {
            commit: step(&blocks).into_owned(),
            consumed: vec![consumed(input, 1)],
        }
    );
    assert_eq!(events[2].event, SessionEvent::Settings(settings("two")));
}

/// A commit reads back equal to the saved one: its replacement, its blocks, its answer, and each kind of end.
pub async fn a_saved_commit_reads_back_equal(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    let head = [yuke_ai::Block::user_text("summary")];
    let blocks = [yuke_ai::Block::assistant_text("answer")];
    let answer = Answer {
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
        finish_reason: yuke_ai::FinishReason::Length,
    };
    let commits = [
        Commit {
            replaced: Some(Replaced {
                head: Cow::Borrowed(&head),
                keep: 2,
            }),
            ..step(&[])
        },
        Commit {
            answer: Some(answer),
            ..step(&blocks)
        },
        Commit {
            end: Some(TurnEnd::Outcome(Outcome::Completed {
                finish_reason: yuke_ai::FinishReason::ToolCalls,
            })),
            ..step(&[])
        },
        Commit {
            end: Some(TurnEnd::Outcome(Outcome::Stopped)),
            ..step(&[])
        },
        Commit {
            end: Some(TurnEnd::Outcome(Outcome::Cancelled)),
            ..step(&[])
        },
        Commit {
            end: Some(TurnEnd::Failed("the request failed".to_owned())),
            ..step(&[])
        },
    ];
    for commit in &commits {
        store.commit(id, commit, &[]).await.unwrap();
    }

    let events = store
        .load(id, Some(EventNumber(1)))
        .await
        .map(|loaded| loaded.events)
        .unwrap();

    let read: Vec<&SessionEvent> = events.iter().map(|stored| &stored.event).collect();
    let saved: Vec<SessionEvent> = commits
        .iter()
        .map(|commit| SessionEvent::Commit {
            commit: commit.clone().into_owned(),
            consumed: Vec::new(),
        })
        .collect();
    assert_eq!(read, saved.iter().collect::<Vec<_>>());
}

/// The events after a number are the events with a larger number, in order. After the newest number, also after the
/// largest number, there are none.
pub async fn events_after_a_number_are_the_newer_events(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    store.set_settings(id, &settings("two")).await.unwrap();

    let after_one = store
        .load(id, Some(EventNumber(1)))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    let after_last = store
        .load(id, Some(EventNumber(3)))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    let after_largest = store
        .load(id, Some(EventNumber(u64::MAX)))
        .await
        .map(|loaded| loaded.events)
        .unwrap();

    assert_eq!(kinds(&after_one), [(2, "commit"), (3, "settings")]);
    assert_eq!(after_last, []);
    assert_eq!(after_largest, []);
}

/// A fork has the events of its source with their numbers. The next event of the fork takes the next number, and the
/// source does not change.
pub async fn a_fork_has_the_events_of_its_source_and_numbers_on_from_them(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(source, &end(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    let source_events = store.load(source, None).await.map(|loaded| loaded.events).unwrap();

    let fork = store.fork_session(source, None).await.unwrap().id;
    store.set_settings(fork, &settings("two")).await.unwrap();

    let fork_events = store.load(fork, None).await.map(|loaded| loaded.events).unwrap();
    assert_eq!(fork_events[..2], source_events[..]);
    assert_eq!(
        fork_events[2],
        StoredEvent {
            event_number: EventNumber(3),
            event: SessionEvent::Settings(settings("two")),
        }
    );
    assert_eq!(
        store.load(source, None).await.map(|loaded| loaded.events).unwrap(),
        source_events
    );
}

/// The event numbers of a session do not depend on the events of other sessions.
pub async fn each_session_numbers_its_own_events(store: &dyn Store) {
    let busy = store.create_session(&settings("busy"), &prompt()).await.unwrap().id;
    for text in ["one", "two"] {
        store
            .commit(busy, &end(&[yuke_ai::Block::user_text(text)]), &[])
            .await
            .unwrap();
    }

    let quiet = store.create_session(&settings("quiet"), &prompt()).await.unwrap().id;
    store.set_settings(quiet, &settings("still quiet")).await.unwrap();

    let numbers: Vec<EventNumber> = store
        .load(quiet, None)
        .await
        .map(|loaded| loaded.events)
        .unwrap()
        .into_iter()
        .map(|event| event.event_number)
        .collect();
    assert_eq!(numbers, [EventNumber(1), EventNumber(2)]);
}

/// The context holds the blocks of the commits only. Pending inputs and settings events before and after a replacement
/// add no block.
pub async fn the_context_holds_only_commit_blocks_across_pending_inputs_and_settings_events(store: &dyn Store) {
    let id = store.create_session(&settings("one"), &prompt()).await.unwrap().id;
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    store.accept_input(id, user_input("queued")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::assistant_text("b")]), &[])
        .await
        .unwrap();
    store.set_settings(id, &settings("two")).await.unwrap();
    let head = [yuke_ai::Block::user_text("summary")];
    let replacement = Commit {
        replaced: Some(Replaced {
            head: Cow::Borrowed(&head),
            keep: 2,
        }),
        ..step(&[])
    };
    store.commit(id, &replacement, &[]).await.unwrap();
    store.accept_input(id, user_input("queued later")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("c")]), &[])
        .await
        .unwrap();

    let opened = store.open(id, Access::Read).await.unwrap();

    assert_eq!(
        opened.context,
        [
            yuke_ai::Block::user_text("summary"),
            yuke_ai::Block::user_text("a"),
            yuke_ai::Block::assistant_text("b"),
            yuke_ai::Block::user_text("c"),
        ]
    );
}

/// Settings that work in the folder `cwd`.
fn settings_in(cwd: &str) -> SessionSettings {
    SessionSettings {
        cwd: PathBuf::from(cwd),
        ..settings("")
    }
}

/// The newest session of a folder is the session of that folder with the newest event. A session of another folder
/// does not count.
pub async fn the_newest_session_of_a_folder_has_the_newest_event(store: &dyn Store) {
    let first = store.create_session(&settings_in("/work"), &prompt()).await.unwrap().id;
    let second = store.create_session(&settings_in("/work"), &prompt()).await.unwrap().id;
    let other = store
        .create_session(&settings_in("/other"), &prompt())
        .await
        .unwrap()
        .id;

    assert_eq!(store.newest_session(Path::new("/work")).await.unwrap(), Some(second));
    store.commit(first, &step(&[]), &[]).await.unwrap();
    assert_eq!(store.newest_session(Path::new("/work")).await.unwrap(), Some(first));
    assert_eq!(store.newest_session(Path::new("/other")).await.unwrap(), Some(other));
    assert_eq!(store.newest_session(Path::new("/none")).await.unwrap(), None);
}

/// A session works in the folder of its newest settings, not in the folder of earlier settings.
pub async fn a_session_works_in_the_folder_of_its_newest_settings(store: &dyn Store) {
    let id = store.create_session(&settings_in("/work"), &prompt()).await.unwrap().id;
    store.create_session(&settings_in("/other"), &prompt()).await.unwrap();

    store.set_settings(id, &settings_in("/other")).await.unwrap();

    assert_eq!(store.newest_session(Path::new("/work")).await.unwrap(), None);
    assert_eq!(store.newest_session(Path::new("/other")).await.unwrap(), Some(id));
}

/// A fork is newer than its source and than the other sessions of its folder.
pub async fn a_fork_is_the_newest_session_of_its_folder(store: &dyn Store) {
    let source = store.create_session(&settings_in("/work"), &prompt()).await.unwrap().id;
    store.create_session(&settings_in("/work"), &prompt()).await.unwrap();

    let fork = store.fork_session(source, None).await.unwrap().id;

    assert_eq!(store.newest_session(Path::new("/work")).await.unwrap(), Some(fork));
}

/// A receipt gives the saved commit's session-local event number after settings changes, other-session writes, and a fork.
pub async fn a_commit_receipt_names_its_saved_event_after_settings_and_a_fork(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt()).await.unwrap();
    let other = store.create_session(&settings("other"), &prompt()).await.unwrap();
    store.commit(other.id, &end(&[]), &[]).await.unwrap();
    store.set_settings(source.id, &settings("two")).await.unwrap();
    let blocks = [yuke_ai::Block::user_text("task")];
    let input = store.accept_input(source.id, user_input("task")).await.unwrap();
    let receipt = store
        .commit(source.id, &end(&blocks), &[consumed(input, 1)])
        .await
        .unwrap();
    assert_eq!(receipt, EventNumber(3));
    assert_eq!(
        store
            .load(source.id, Some(EventNumber(2)))
            .await
            .map(|loaded| loaded.events)
            .unwrap(),
        [StoredEvent {
            event_number: EventNumber(3),
            event: SessionEvent::Commit {
                commit: end(&blocks).into_owned(),
                consumed: vec![consumed(input, 1)],
            },
        }]
    );
    assert_eq!(store.pending(source.id).await.unwrap(), []);

    let fork = store.fork_session(source.id, Some(receipt)).await.unwrap();
    let fork_receipt = store.commit(fork.id, &end(&[]), &[]).await.unwrap();
    let source_receipt = store.commit(source.id, &end(&[]), &[]).await.unwrap();
    assert_eq!(fork_receipt, EventNumber(4));
    assert_eq!(source_receipt, EventNumber(4));
    assert_eq!(
        store
            .load(fork.id, Some(receipt))
            .await
            .map(|loaded| loaded.events)
            .unwrap(),
        [StoredEvent {
            event_number: EventNumber(4),
            event: SessionEvent::Commit {
                commit: end(&[]).into_owned(),
                consumed: vec![],
            },
        }]
    );
}
