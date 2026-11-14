//! The shared behavior tests of a [`Store`]. Each function checks one behavior on a new store and panics when the store
//! fails it. [`store_tests!`](crate::store_tests) writes one test for each function.
#![expect(
    clippy::unwrap_used,
    clippy::missing_panics_doc,
    reason = "a behavior test fails by panicking"
)]

use std::borrow::Cow;
use std::path::{Path, PathBuf};

use yuke_engine::{
    Answer, CallDisplay, Commit, CommitDisplay, DisplayBlock, Preview, Replaced, ResultDisplay, Subject, SubjectKind,
    ToolHints, TurnEnd,
};

use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputId, InputKind, InputSource, ModelReference, PendingInput, SessionEvent,
    SessionId, SessionSettings, SessionTitle, StoredEvent,
};

use crate::PromptSection;
use crate::store::{Access, EventPage, NewestTurn, Store, StoreError, blob_of};

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
            an_open_gives_the_input_tokens_of_the_newest_answer,
            a_replacement_after_the_newest_answer_clears_its_input_tokens,
            a_second_writer_gets_owned,
            a_dropped_lease_lets_a_new_writer_open,
            a_reader_holds_no_lock,
            a_pending_input_stays_until_a_commit_consumes_it,
            a_recorded_input_keeps_its_reply_policy_after_a_saved_load,
            a_consumed_input_id_is_not_given_again,
            a_commit_of_an_input_that_is_not_pending_saves_nothing,
            a_load_gives_the_events_with_the_inputs_that_are_still_pending,
            a_page_before_an_event_gives_the_last_events_before_it_in_order,
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
            a_fork_to_another_folder_keeps_history_and_replaces_only_its_own_settings_and_prompt,
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
            the_context_holds_only_commit_blocks_across_pending_inputs_and_settings_events,
            the_list_gives_the_session_with_the_newest_event_first,
            the_pages_of_a_list_follow_each_other,
            a_new_session_after_a_delete_does_not_come_after_an_older_cursor,
            a_session_lists_in_the_folder_of_its_newest_settings,
            a_child_stays_out_of_the_default_list_and_its_parent_lists_it,
            a_child_keeps_its_parent_at_an_open_and_its_fork_has_none,
            a_fork_is_the_newest_session_and_names_its_source,
            the_first_message_with_text_gives_the_title,
            a_title_collapses_whitespace_from_each_text_block,
            a_rename_before_the_first_message_keeps_the_chosen_title,
            a_rename_changes_no_conversation_event_or_activity_time,
            a_fork_title_is_bounded_and_independent_of_its_source,
            a_fork_without_a_title_takes_its_first_text_message,
            a_summary_gives_the_saved_times_and_an_unknown_session_gets_not_found,
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
        settings: yuke_ai::RequestSettings::new(),
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

/// The display of a commit with one call and one result.
pub fn display() -> CommitDisplay {
    CommitDisplay {
        calls: vec![CallDisplay {
            block_index: 0,
            hints: ToolHints {
                title: Some("Read".to_owned()),
                subject: Some(Subject {
                    argument: "path".to_owned(),
                    kind: SubjectKind::File,
                }),
                preview: Preview::None,
            },
            cwd: Some("/repo".to_owned()),
        }],
        results: vec![ResultDisplay {
            block_index: 0,
            blocks: vec![DisplayBlock::Diff {
                path: "a.rs".to_owned(),
                patch: "@@ -1 +1 @@\n-a\n+b\n".to_owned(),
            }],
            duration_ms: Some(40),
        }],
    }
}

/// A commit in the middle of a turn.
pub fn step(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit::blocks(blocks)
}

/// A commit that ends a turn as completed.
pub fn end(blocks: &[yuke_ai::Block]) -> Commit<'_> {
    Commit {
        end: Some(TurnEnd::Completed {
            finish_reason: yuke_ai::FinishReason::Stop,
        }),
        ..step(blocks)
    }
}

/// A new session opens with its settings, an empty context, no pending input, and no open turn.
pub async fn a_new_session_opens_with_its_settings_and_no_context(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

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
    let created = store.create_session(&settings("one"), &sections, None).await.unwrap();
    let id = created.id;
    store.set_settings(id, &settings("two")).await.unwrap();

    let forked = store.fork_session(id, None, None).await.unwrap();

    assert_eq!(created.prompt, sections);
    assert_eq!(store.open(id, Access::Read).await.unwrap().prompt, sections);
    assert_eq!(forked.prompt, sections);
    assert_eq!(store.open(forked.id, Access::Read).await.unwrap().prompt, sections);
}

/// Each commit adds its blocks after the blocks of the earlier commits.
pub async fn a_commit_adds_its_blocks_to_the_context(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let newest = || async { store.open(id, Access::Read).await.unwrap().newest_turn };
    let ending = |end: TurnEnd| Commit {
        replaced: None,
        blocks: Cow::Owned(vec![yuke_ai::Block::user_text("one")]),
        answer: None,
        end: Some(end),
        display: CommitDisplay::default(),
    };

    let empty = newest().await;
    store.commit(id, &ending(TurnEnd::Cancelled), &[]).await.unwrap();
    let cancelled = newest().await;
    store
        .commit(
            id,
            &ending(TurnEnd::Failed {
                error: "the disk is gone".to_owned(),
            }),
            &[],
        )
        .await
        .unwrap();
    let failed = newest().await;

    assert_eq!(empty, NewestTurn::Empty);
    assert_eq!(cancelled, NewestTurn::Ended(TurnEnd::Cancelled));
    assert_eq!(
        failed,
        NewestTurn::Ended(TurnEnd::Failed {
            error: "the disk is gone".to_owned()
        })
    );
}

/// A second writer of a session gets [`StoreError::Owned`] while the first writer holds its lease.
pub async fn a_second_writer_gets_owned(store: &dyn Store) {
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();

    let second = store.open(opened.id, Access::Write).await;

    assert!(matches!(second, Err(StoreError::Owned)), "{second:?}");
}

/// The drop of a lease lets a new writer open the session.
pub async fn a_dropped_lease_lets_a_new_writer_open(store: &dyn Store) {
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = opened.id;

    drop(opened);
    let again = store.open(id, Access::Write).await;

    assert!(again.is_ok(), "{again:?}");
}

/// A read open holds no lock, so a writer opens while the reader holds its open session.
pub async fn a_reader_holds_no_lock(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    #[expect(unused_variables, reason = "the read session stays open while the writer opens")]
    let read = store.open(id, Access::Read).await.unwrap();

    let write = store.open(id, Access::Write).await;

    assert!(write.is_ok(), "{write:?}");
}

/// An accepted input is pending, in id order, until a commit consumes it.
pub async fn a_pending_input_stays_until_a_commit_consumes_it(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let first = store.accept_input(id, user_input("one")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(first, 1)])
        .await
        .unwrap();
    let second = store.accept_input(id, user_input("two")).await.unwrap();
    let events = store
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();

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

    assert!(
        matches!(again, Err(StoreError::InputNotPending(input)) if input == first),
        "{again:?}"
    );
    assert!(
        matches!(mixed, Err(StoreError::InputNotPending(input)) if input == first),
        "{mixed:?}"
    );
    assert_eq!(
        store
            .load(id, EventPage::After(None))
            .await
            .map(|loaded| loaded.events)
            .unwrap(),
        events
    );
    let pending: Vec<_> = store.pending(id).await.unwrap().iter().map(|input| input.id).collect();
    assert_eq!(pending, [second]);
}

/// A load gives the events after a number and the inputs that no commit consumed. A consumed input is in the commit
/// event, not in the pending inputs.
pub async fn a_load_gives_the_events_with_the_inputs_that_are_still_pending(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let first = store.accept_input(id, user_input("one")).await.unwrap();
    let second = store.accept_input(id, user_input("two")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[consumed(first, 1)])
        .await
        .unwrap();

    let loaded = store.load(id, EventPage::After(Some(EventNumber(1)))).await.unwrap();

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

/// A page before an event gives at most `limit` of the events before it, the newest of them, in number order. A page
/// with no event gives the last events.
pub async fn a_page_before_an_event_gives_the_last_events_before_it_in_order(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    for _ in 0..4 {
        store.commit(id, &step(&[]), &[]).await.unwrap();
    }
    let numbers = |events: Vec<StoredEvent>| events.iter().map(|event| event.event_number.0).collect::<Vec<_>>();
    let page = async |before, limit| {
        numbers(
            store
                .load(id, EventPage::Before { before, limit })
                .await
                .unwrap()
                .events,
        )
    };

    let last = page(None, 2).await;
    let before_four = page(Some(EventNumber(4)), 2).await;
    let before_two = page(Some(EventNumber(2)), 5).await;
    let before_one = page(Some(EventNumber(1)), 5).await;
    let all = page(None, 10).await;
    let beyond = page(Some(EventNumber(100)), 10).await;

    assert_eq!(last, [4, 5]);
    assert_eq!(before_four, [2, 3]);
    assert_eq!(before_two, [1]);
    assert_eq!(before_one, Vec::<u64>::new());
    assert_eq!(all, [1, 2, 3, 4, 5]);
    assert_eq!(beyond, [1, 2, 3, 4, 5]);
}

/// New settings give the number of the event that holds them.
pub async fn new_settings_give_the_number_of_their_event(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store.commit(id, &step(&[]), &[]).await.unwrap();

    let event_number = store.set_settings(id, &settings("two")).await.unwrap();

    assert_eq!(event_number, EventNumber(3));
    let events = store
        .load(id, EventPage::After(Some(EventNumber(2))))
        .await
        .unwrap()
        .events;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let events = store
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

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
    let fork = store.fork_session(id, None, None).await;
    let fork_at = store.fork_session(id, Some(EventNumber(2)), None).await;
    let load = store.load(id, EventPage::After(None)).await;
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

    let blob = store.put_blob(id, b"image".to_vec()).await.unwrap();

    // The SHA-256 of "image", as `printf image | shasum -a 256` gives it.
    assert_eq!(
        blob.digest.to_string(),
        "6105d6cc76af400325e94d588ce511be5bfdbb73b437dc51eca43917d7a43e3d"
    );
    assert_eq!(blob.len, 5);
    assert_eq!(
        store.read_blob(id, &blob.digest).unwrap().as_deref(),
        Some(&b"image"[..])
    );
}

/// A second put of the same bytes gives the same blob, and the blob still reads back.
pub async fn the_same_bytes_give_the_same_blob(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

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
    let owner = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let other = store
        .create_session(&settings("two"), &prompt(), None)
        .await
        .unwrap()
        .id;

    let blob = store.put_blob(owner, b"image".to_vec()).await.unwrap();

    assert_eq!(store.read_blob(other, &blob.digest).unwrap(), None);
}

/// A deleted session is not found, and its pending inputs and its blobs are not found.
pub async fn a_deleted_session_is_not_found(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
    let opened = store.create_session(&settings("one"), &prompt(), None).await.unwrap();

    let delete = store.delete_session(opened.id).await;

    assert!(matches!(delete, Err(StoreError::Owned)), "{delete:?}");
    assert!(store.open(opened.id, Access::Read).await.is_ok());
}

/// A fork has a new id, and the settings and the context of its source. It has a closed turn and no pending input.
pub async fn a_fork_has_the_settings_and_the_context_of_its_source_and_no_pending_input(store: &dyn Store) {
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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

    let fork = store.fork_session(source, None, None).await.unwrap();

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
    let source = store.create_session(&settings("one"), &prompt(), None).await.unwrap();

    let fork = store.fork_session(source.id, None, None).await.unwrap();

    assert!(fork.lease.is_some());
    let fork_writer = store.open(fork.id, Access::Write).await;
    let source_writer = store.open(source.id, Access::Write).await;
    assert!(matches!(fork_writer, Err(StoreError::Owned)), "{fork_writer:?}");
    assert!(matches!(source_writer, Err(StoreError::Owned)), "{source_writer:?}");
}

/// A fork changes its folder and prompt atomically while its source keeps its history and context.
pub async fn a_fork_to_another_folder_keeps_history_and_replaces_only_its_own_settings_and_prompt(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let blocks = [
        yuke_ai::Block::user_text("keep this history"),
        yuke_ai::Block::assistant_text("saved answer"),
    ];
    store.commit(source.id, &end(&blocks), &[]).await.unwrap();
    let destination_prompt = vec![PromptSection::new("instructions", "destination instructions")];
    let fork = store
        .fork_session(
            source.id,
            None,
            Some(crate::ForkDestination {
                cwd: "/destination".into(),
                prompt: destination_prompt.clone(),
            }),
        )
        .await
        .unwrap();
    assert_eq!(fork.context, blocks);
    assert_eq!(fork.settings.cwd, Path::new("/destination"));
    assert_eq!(fork.settings.model, settings("one").model);
    assert_eq!(fork.prompt, destination_prompt);
    let saved = store.open(fork.id, Access::Read).await.unwrap();
    assert_eq!(saved.settings, fork.settings);
    assert_eq!(saved.prompt, destination_prompt);
    let original = store.open(source.id, Access::Read).await.unwrap();
    assert_eq!(original.context, blocks);
    assert_eq!(original.settings, settings("one"));
    assert_eq!(original.prompt, prompt());
}

/// A commit to a fork does not change its source, and a commit to the source does not change the fork.
pub async fn a_commit_to_a_fork_or_its_source_does_not_change_the_other(store: &dyn Store) {
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .commit(source, &end(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    let fork = store.fork_session(source, None, None).await.unwrap().id;

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
    let source = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let first = store.put_blob(source.id, b"image".to_vec()).await.unwrap();
    let second = store.put_blob(source.id, b"audio".to_vec()).await.unwrap();
    let fork = store.fork_session(source.id, None, None).await.unwrap().id;
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
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("a")]), &[])
        .await
        .unwrap();
    store.set_settings(source, &settings("two")).await.unwrap();
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("running")]), &[])
        .await
        .unwrap();

    let fork = store.fork_session(source, None, None).await.unwrap();

    assert_eq!(fork.context, [yuke_ai::Block::assistant_text("a")]);
    assert_eq!(fork.settings, settings("one"));
    assert!(!fork.newest_turn.is_open());
    assert_eq!(
        kinds(
            &store
                .load(fork.id, EventPage::After(None))
                .await
                .map(|loaded| loaded.events)
                .unwrap()
        ),
        [(1, "settings"), (2, "commit")]
    );
}

/// A fork through an earlier completed turn has the context and the settings of that point.
pub async fn a_fork_at_an_earlier_completed_turn_has_the_context_and_the_settings_of_that_point(store: &dyn Store) {
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("a")]), &[])
        .await
        .unwrap();
    store.set_settings(source, &settings("two")).await.unwrap();
    store
        .commit(source, &end(&[yuke_ai::Block::assistant_text("b")]), &[])
        .await
        .unwrap();

    let first = store.fork_session(source, Some(EventNumber(2)), None).await.unwrap();
    let second = store.fork_session(source, Some(EventNumber(4)), None).await.unwrap();

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
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let ends = [
        Some(TurnEnd::Stopped),
        Some(TurnEnd::Cancelled),
        Some(TurnEnd::Failed {
            error: "the request failed".to_owned(),
        }),
    ];
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("a")]), &[])
        .await
        .unwrap();
    for end in ends {
        store.commit(source, &Commit { end, ..step(&[]) }, &[]).await.unwrap();
    }

    for through in [0, 1, 2, 3, 4, 5, 6, u64::MAX] {
        let fork = store.fork_session(source, Some(EventNumber(through)), None).await;

        assert!(
            matches!(fork, Err(StoreError::NotACompletedTurn)),
            "{through}: {fork:?}"
        );
    }
}

/// A source with no completed turn forks to the settings before its first commit and an empty context.
pub async fn a_source_without_a_completed_turn_forks_to_its_settings_and_an_empty_context(store: &dyn Store) {
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store.set_settings(source, &settings("two")).await.unwrap();
    store
        .commit(source, &step(&[yuke_ai::Block::user_text("running")]), &[])
        .await
        .unwrap();
    store.set_settings(source, &settings("three")).await.unwrap();

    let fork = store.fork_session(source, None, None).await.unwrap();

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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

    let events = store
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();

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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let blocks = [yuke_ai::Block::user_text("one")];

    let input = store.accept_input(id, user_input("one")).await.unwrap();
    let after_input = store
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    store.commit(id, &step(&blocks), &[consumed(input, 1)]).await.unwrap();
    store.set_settings(id, &settings("two")).await.unwrap();

    let events = store
        .load(id, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
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

/// An open gives the input tokens of the newest answer. A session without an answer has none. A later commit without an
/// answer and without a replacement keeps them.
pub async fn an_open_gives_the_input_tokens_of_the_newest_answer(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let before = store.open(id, Access::Read).await.unwrap().input_tokens;
    let blocks = [yuke_ai::Block::assistant_text("answer")];
    let answer = Answer {
        origin: yuke_ai::Origin {
            model: "test-model".to_owned(),
            base_url: "https://example.test".to_owned(),
        },
        usage: yuke_ai::Usage {
            input: Some(1200),
            ..yuke_ai::Usage::default()
        },
        finish_reason: yuke_ai::FinishReason::Stop,
    };
    let answered = Commit {
        answer: Some(answer),
        ..step(&blocks)
    };
    store.commit(id, &answered, &[]).await.unwrap();
    store.commit(id, &end(&[]), &[]).await.unwrap();

    let after = store.open(id, Access::Read).await.unwrap().input_tokens;

    assert_eq!(before, None);
    assert_eq!(after, Some(1200));
}

/// An open after a newer replacement gives no input tokens, because the count of the old context does not describe the
/// new one. The next answer gives its own count again.
pub async fn a_replacement_after_the_newest_answer_clears_its_input_tokens(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let blocks = [yuke_ai::Block::assistant_text("answer")];
    let answered = |input| Commit {
        answer: Some(Answer {
            origin: yuke_ai::Origin {
                model: "test-model".to_owned(),
                base_url: "https://example.test".to_owned(),
            },
            usage: yuke_ai::Usage {
                input: Some(input),
                ..yuke_ai::Usage::default()
            },
            finish_reason: yuke_ai::FinishReason::Stop,
        }),
        ..step(&blocks)
    };
    store.commit(id, &answered(1200), &[]).await.unwrap();
    let head = [yuke_ai::Block::user_text("summary")];
    let replacement = Commit {
        replaced: Some(Replaced {
            head: Cow::Borrowed(&head),
            keep: 1,
        }),
        ..step(&[])
    };
    store.commit(id, &replacement, &[]).await.unwrap();

    let replaced = store.open(id, Access::Read).await.unwrap().input_tokens;
    store.commit(id, &answered(300), &[]).await.unwrap();
    let answered_again = store.open(id, Access::Read).await.unwrap().input_tokens;

    assert_eq!(replaced, None);
    assert_eq!(answered_again, Some(300));
}

/// A commit reads back equal to the saved one: its replacement, its blocks, its answer, and each kind of end.
pub async fn a_saved_commit_reads_back_equal(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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
            end: Some(TurnEnd::Completed {
                finish_reason: yuke_ai::FinishReason::ToolCalls,
            }),
            ..step(&[])
        },
        Commit {
            end: Some(TurnEnd::Stopped),
            ..step(&[])
        },
        Commit {
            end: Some(TurnEnd::Cancelled),
            ..step(&[])
        },
        Commit {
            end: Some(TurnEnd::Failed {
                error: "the request failed".to_owned(),
            }),
            ..step(&[])
        },
        Commit {
            display: display(),
            ..step(&blocks)
        },
    ];
    for commit in &commits {
        store.commit(id, commit, &[]).await.unwrap();
    }

    let events = store
        .load(id, EventPage::After(Some(EventNumber(1))))
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
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .commit(id, &step(&[yuke_ai::Block::user_text("one")]), &[])
        .await
        .unwrap();
    store.set_settings(id, &settings("two")).await.unwrap();

    let after_one = store
        .load(id, EventPage::After(Some(EventNumber(1))))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    let after_last = store
        .load(id, EventPage::After(Some(EventNumber(3))))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    let after_largest = store
        .load(id, EventPage::After(Some(EventNumber(u64::MAX))))
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
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let blocks = [yuke_ai::Block::user_text("one")];
    let commit = Commit {
        display: display(),
        ..end(&blocks)
    };
    store.commit(source, &commit, &[]).await.unwrap();
    let source_events = store
        .load(source, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();

    let fork = store.fork_session(source, None, None).await.unwrap().id;
    store.set_settings(fork, &settings("two")).await.unwrap();

    let fork_events = store
        .load(fork, EventPage::After(None))
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    assert_eq!(fork_events[..2], source_events[..]);
    assert_eq!(
        fork_events[2],
        StoredEvent {
            event_number: EventNumber(3),
            event: SessionEvent::Settings(settings("two")),
        }
    );
    assert_eq!(
        store
            .load(source, EventPage::After(None))
            .await
            .map(|loaded| loaded.events)
            .unwrap(),
        source_events
    );
}

/// The context holds the blocks of the commits only. Pending inputs and settings events before and after a replacement
/// add no block.
pub async fn the_context_holds_only_commit_blocks_across_pending_inputs_and_settings_events(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
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

/// The ids of the sessions of `page`, in page order.
fn listed(page: &crate::SessionPage) -> Vec<SessionId> {
    page.sessions.iter().map(|summary| summary.session_id).collect()
}

/// The list gives the newest event first. A commit moves its session to the front, and a folder filter keeps only the
/// sessions of that folder.
pub async fn the_list_gives_the_session_with_the_newest_event_first(store: &dyn Store) {
    let first = store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let second = store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let other = store
        .create_session(&settings_in("/other"), &prompt(), None)
        .await
        .unwrap()
        .id;

    let all = store.list_sessions(None, None, None, 10).await.unwrap();
    assert_eq!(listed(&all), [other, second, first]);
    store.commit(first, &step(&[]), &[]).await.unwrap();
    let work = store
        .list_sessions(Some(Path::new("/work")), None, None, 10)
        .await
        .unwrap();
    assert_eq!(listed(&work), [first, second]);
    let none = store
        .list_sessions(Some(Path::new("/none")), None, None, 10)
        .await
        .unwrap();
    assert_eq!(listed(&none), []);
}

/// Pages follow each other with no gap and no repeat. A full last page gives no next position.
pub async fn the_pages_of_a_list_follow_each_other(store: &dyn Store) {
    let mut ids = Vec::new();
    for _ in 0..3 {
        ids.push(
            store
                .create_session(&settings_in("/work"), &prompt(), None)
                .await
                .unwrap()
                .id,
        );
    }
    ids.reverse();

    let first = store.list_sessions(None, None, None, 2).await.unwrap();
    let second = store.list_sessions(None, None, first.next, 2).await.unwrap();
    let exact = store.list_sessions(None, None, None, 3).await.unwrap();

    assert_eq!(listed(&first), ids[..2]);
    assert_eq!(listed(&second), ids[2..]);
    assert_eq!(second.next, None);
    assert_eq!(listed(&exact), ids);
    assert_eq!(exact.next, None);
}

/// A cursor keeps its meaning after the newest sessions go: a new session comes before it, never after it.
pub async fn a_new_session_after_a_delete_does_not_come_after_an_older_cursor(store: &dyn Store) {
    let first = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let second = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let third = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let page = store.list_sessions(None, None, None, 1).await.unwrap();
    store.delete_session(third).await.unwrap();
    store.delete_session(second).await.unwrap();
    let new = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;

    let older = store.list_sessions(None, None, page.next, 10).await.unwrap();

    assert_eq!(listed(&page), [third]);
    assert_eq!(listed(&older), [first]);
    assert_eq!(
        listed(&store.list_sessions(None, None, None, 10).await.unwrap()),
        [new, first]
    );
}

/// A session lists in the folder of its newest settings, not in the folder of earlier settings.
pub async fn a_session_lists_in_the_folder_of_its_newest_settings(store: &dyn Store) {
    let id = store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .create_session(&settings_in("/other"), &prompt(), None)
        .await
        .unwrap();

    store.set_settings(id, &settings_in("/other")).await.unwrap();

    let work = store
        .list_sessions(Some(Path::new("/work")), None, None, 10)
        .await
        .unwrap();
    let other = store
        .list_sessions(Some(Path::new("/other")), None, None, 10)
        .await
        .unwrap();
    assert_eq!(listed(&work), []);
    assert_eq!(listed(&other)[0], id);
    assert_eq!(store.session_summary(id).await.unwrap().cwd, Path::new("/other"));
}

/// The default list holds the sessions without a parent, and a list with a parent holds only its children.
pub async fn a_child_stays_out_of_the_default_list_and_its_parent_lists_it(store: &dyn Store) {
    let parent = store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let child = store
        .create_session(&settings_in("/work"), &prompt(), Some(parent))
        .await
        .unwrap()
        .id;
    let other = store
        .create_session(&settings_in("/other"), &prompt(), Some(parent))
        .await
        .unwrap()
        .id;

    let roots = store.list_sessions(None, None, None, 10).await.unwrap();
    let children = store.list_sessions(None, Some(parent), None, 10).await.unwrap();
    let in_folder = store
        .list_sessions(Some(Path::new("/work")), Some(parent), None, 10)
        .await
        .unwrap();
    let of_child = store.list_sessions(None, Some(child), None, 10).await.unwrap();

    assert_eq!(listed(&roots), [parent]);
    assert_eq!(listed(&children), [other, child]);
    assert_eq!(listed(&in_folder), [child]);
    assert_eq!(listed(&of_child), []);
    assert_eq!(children.sessions[0].parent, Some(parent));
    assert_eq!(store.session_summary(child).await.unwrap().parent, Some(parent));
}

/// An open gives the parent back. A fork of a child has no parent, because a fork works for no session.
pub async fn a_child_keeps_its_parent_at_an_open_and_its_fork_has_none(store: &dyn Store) {
    let parent = store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let child = store
        .create_session(&settings_in("/work"), &prompt(), Some(parent))
        .await
        .unwrap()
        .id;

    let opened = store.open(child, Access::Read).await.unwrap();
    let fork = store.fork_session(child, None, None).await.unwrap();

    assert_eq!(opened.parent, Some(parent));
    assert_eq!(fork.parent, None);
    assert_eq!(store.session_summary(fork.id).await.unwrap().parent, None);
    assert_eq!(
        listed(&store.list_sessions(None, None, None, 1).await.unwrap()),
        [fork.id]
    );
}

/// A fork is the newest session. It names its source, prefixes the title of the source, and has the settings of its cut.
pub async fn a_fork_is_the_newest_session_and_names_its_source(store: &dyn Store) {
    let source = store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store.accept_input(source, user_input("first task")).await.unwrap();
    store.commit(source, &end(&[]), &[]).await.unwrap();
    store.set_settings(source, &settings_in("/later")).await.unwrap();
    store
        .create_session(&settings_in("/work"), &prompt(), None)
        .await
        .unwrap();

    let fork = store.fork_session(source, None, None).await.unwrap().id;

    let summary = store.session_summary(fork).await.unwrap();
    assert_eq!(listed(&store.list_sessions(None, None, None, 1).await.unwrap()), [fork]);
    assert_eq!(summary.fork_of, Some(source));
    assert_eq!(summary.title.as_deref(), Some("Fork — first task"));
    assert_eq!(summary.cwd, Path::new("/work"));
    assert_eq!(store.session_summary(source).await.unwrap().fork_of, None);
}

/// The first message input with text gives a bounded title. A notification and a later message change nothing.
pub async fn the_first_message_with_text_gives_the_title(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let notification = Input::new(
        InputSource::User,
        InputKind::Notification,
        vec![yuke_ai::Block::user_text("a job ended")],
    )
    .unwrap();
    store.accept_input(id, notification).await.unwrap();
    let blob = store.put_blob(id, vec![1, 2, 3]).await.unwrap();
    let image = Input::new(
        InputSource::User,
        InputKind::Message,
        vec![yuke_ai::Block::Media(yuke_ai::Media::new(blob, "image/png"))],
    )
    .unwrap();
    store.accept_input(id, image).await.unwrap();
    assert_eq!(store.session_summary(id).await.unwrap().title, None);

    store
        .accept_input(id, user_input(&format!("  {}  ", "é".repeat(300))))
        .await
        .unwrap();
    store.accept_input(id, user_input("later")).await.unwrap();

    assert_eq!(
        store.session_summary(id).await.unwrap().title.as_deref(),
        Some("é".repeat(200)).as_deref()
    );
}

/// Each text block contributes to the initial title, with each whitespace run reduced to one space.
pub async fn a_title_collapses_whitespace_from_each_text_block(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let input = Input::new(
        InputSource::User,
        InputKind::Message,
        vec![
            yuke_ai::Block::user_text("  Fix\n the\tlogin  "),
            yuke_ai::Block::user_text("  tests\u{2003}now  "),
        ],
    )
    .unwrap();

    store.accept_input(id, input).await.unwrap();

    assert_eq!(
        store.session_summary(id).await.unwrap().title.as_deref(),
        Some("Fix the login tests now")
    );
}

/// An explicit title before any input survives the first message.
pub async fn a_rename_before_the_first_message_keeps_the_chosen_title(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .rename_session(id, &SessionTitle::new("  Login\nfix  ").unwrap())
        .await
        .unwrap();

    store
        .accept_input(id, user_input("Investigate the token refresh error."))
        .await
        .unwrap();

    assert_eq!(
        store.session_summary(id).await.unwrap().title.as_deref(),
        Some("Login fix")
    );
}

/// A rename changes only the title, also while a writer holds the session. Unknown sessions reject the write.
pub async fn a_rename_changes_no_conversation_event_or_activity_time(store: &dyn Store) {
    let session = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let id = session.id;
    store.accept_input(id, user_input("First task")).await.unwrap();
    store
        .commit(id, &step(&[yuke_ai::Block::assistant_text("Working")]), &[])
        .await
        .unwrap();
    let before = store.load(id, EventPage::After(None)).await.unwrap();
    let summary = store.session_summary(id).await.unwrap();
    let other = store.create_session(&settings("two"), &prompt(), None).await.unwrap();

    store
        .rename_session(id, &SessionTitle::new("Token refresh").unwrap())
        .await
        .unwrap();

    let renamed = store.session_summary(id).await.unwrap();
    assert_eq!(renamed.title.as_deref(), Some("Token refresh"));
    assert_eq!(renamed.created_at, summary.created_at);
    assert_eq!(renamed.updated_at, summary.updated_at);
    assert_eq!(renamed.model, summary.model);
    assert_eq!(renamed.cwd, summary.cwd);
    let after = store.load(id, EventPage::After(None)).await.unwrap();
    assert_eq!(after.events, before.events);
    assert_eq!(after.pending, before.pending);
    assert_eq!(
        listed(&store.list_sessions(None, None, None, 10).await.unwrap()),
        [other.id, id]
    );
    assert!(matches!(
        store
            .rename_session(SessionId::generate(), &SessionTitle::new("Missing").unwrap())
            .await,
        Err(StoreError::NotFound)
    ));
}

/// Forks prefix and bound their display titles. A rename of either session changes only that session.
pub async fn a_fork_title_is_bounded_and_independent_of_its_source(store: &dyn Store) {
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    store
        .rename_session(source, &SessionTitle::new(&"é".repeat(200)).unwrap())
        .await
        .unwrap();

    let fork = store.fork_session(source, None, None).await.unwrap().id;

    assert_eq!(
        store.session_summary(fork).await.unwrap().title.as_deref(),
        Some(format!("Fork — {}", "é".repeat(193))).as_deref()
    );
    store
        .rename_session(source, &SessionTitle::new("Source").unwrap())
        .await
        .unwrap();
    store
        .rename_session(fork, &SessionTitle::new("Alternative").unwrap())
        .await
        .unwrap();
    assert_eq!(
        store.session_summary(source).await.unwrap().title.as_deref(),
        Some("Source")
    );
    assert_eq!(
        store.session_summary(fork).await.unwrap().title.as_deref(),
        Some("Alternative")
    );
}

/// A fork with no title takes its own first text message, independently of its source.
pub async fn a_fork_without_a_title_takes_its_first_text_message(store: &dyn Store) {
    let source = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let fork = store.fork_session(source, None, None).await.unwrap().id;
    assert_eq!(store.session_summary(fork).await.unwrap().title, None);

    store.accept_input(fork, user_input("A fork task")).await.unwrap();
    store
        .accept_input(source, user_input("The original task"))
        .await
        .unwrap();

    assert_eq!(
        store.session_summary(fork).await.unwrap().title.as_deref(),
        Some("A fork task")
    );
    assert_eq!(
        store.session_summary(source).await.unwrap().title.as_deref(),
        Some("The original task")
    );
}

/// A summary gives the saved times: the creation time, and the time of the newest event, which a commit moves on. An
/// unknown session gets not found.
pub async fn a_summary_gives_the_saved_times_and_an_unknown_session_gets_not_found(store: &dyn Store) {
    let id = store
        .create_session(&settings("one"), &prompt(), None)
        .await
        .unwrap()
        .id;
    let created = store.session_summary(id).await.unwrap();
    // The times count milliseconds, so the commit comes in a later millisecond.
    std::thread::sleep(std::time::Duration::from_millis(5));
    store.commit(id, &step(&[]), &[]).await.unwrap();

    let committed = store.session_summary(id).await.unwrap();
    assert_eq!(committed.created_at, created.created_at);
    assert!(
        committed.updated_at > created.updated_at,
        "{committed:?} after {created:?}"
    );
    assert!(matches!(
        store.session_summary(SessionId::generate()).await,
        Err(StoreError::NotFound)
    ));
}

/// A receipt gives the saved commit's session-local event number after settings changes, other-session writes, and a fork.
pub async fn a_commit_receipt_names_its_saved_event_after_settings_and_a_fork(store: &dyn Store) {
    let source = store.create_session(&settings("one"), &prompt(), None).await.unwrap();
    let other = store.create_session(&settings("other"), &prompt(), None).await.unwrap();
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
            .load(source.id, EventPage::After(Some(EventNumber(2))))
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

    let fork = store.fork_session(source.id, Some(receipt), None).await.unwrap();
    let fork_receipt = store.commit(fork.id, &end(&[]), &[]).await.unwrap();
    let source_receipt = store.commit(source.id, &end(&[]), &[]).await.unwrap();
    assert_eq!(fork_receipt, EventNumber(4));
    assert_eq!(source_receipt, EventNumber(4));
    assert_eq!(
        store
            .load(fork.id, EventPage::After(Some(receipt)))
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

/// An accepted local record keeps its no-reply policy through the store's saved JSON.
pub async fn a_recorded_input_keeps_its_reply_policy_after_a_saved_load(store: &dyn Store) {
    let opened = store
        .create_session(&settings("test-model"), &prompt(), None)
        .await
        .unwrap();
    let input = Input::notification("shell", "pwd", "/workspace").recorded();
    store.accept_input(opened.id, input.clone()).await.unwrap();
    let loaded = store.load(opened.id, EventPage::After(None)).await.unwrap();
    assert_eq!(loaded.pending.len(), 1);
    assert_eq!(loaded.pending[0].input, input);
    assert!(!loaded.pending[0].input.needs_reply());
}
