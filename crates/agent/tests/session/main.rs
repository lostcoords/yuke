//! A session over a memory store: it opens again with its context, ends an open turn, keeps pending inputs,
//! takes input during a turn, and recovers after a failed commit.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

mod input_hook;
mod support;
mod updates;

use std::sync::Arc;

use std::pin::pin;
use std::task::{Context, Waker};

use support::{FailingStore, SendsInput, StoreBehavior, consumed_inputs, prompt, settings, user_input};
use yuke_agent::{Access, MemoryStore, NewestTurn, PromptSection, Session, SessionError, Store, StoreError};
use yuke_ai::route::SessionHeader;
use yuke_ai::transport::Header;
use yuke_ai::{Block, Media, ToolCall, ToolDefinition, ToolResult};
use yuke_engine::{Commit, Driver, Hooks, RoundError, RoundPlan, RoundStart, Toolset, TurnEnd, chain_text};
use yuke_protocol::{
    ConsumedInput, Input, InputId, InputKind, InputSource, ModelReference, SessionEvent, SessionSettings,
};
use yuke_testing::{
    NoWait, ScriptedTransport, Stalled, assert_in_order, counted, failed_reply, model, text_reply, tool_reply,
};

/// The failure of a turn that a recovery ends.
const TURN_STOPPED: &str = "the turn stopped before it saved its end";

/// A commit in the middle of a turn.
fn step(blocks: &[Block]) -> Commit<'_> {
    Commit {
        replaced: None,
        blocks: std::borrow::Cow::Borrowed(blocks),
        answer: None,
        end: None,
    }
}

#[tokio::test]
async fn a_session_that_opens_again_has_the_same_context() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();
    let context = session.context().to_vec();
    let id = session.id();
    drop(session);
    let again = Session::open(store, id).await.unwrap();

    assert_eq!(context, [Block::user_text("one"), Block::assistant_text("two")]);
    assert_eq!(again.context(), context);
}

#[tokio::test]
async fn a_session_keeps_its_lease_after_a_turn() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();
    let other_writer = store.open(session.id(), Access::Write).await;

    assert!(matches!(other_writer, Err(StoreError::Owned)), "{other_writer:?}");
}

#[tokio::test]
async fn a_turn_with_no_waiting_input_asks_the_model_nothing_and_saves_nothing() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let before = store.load(session.id(), None).await.unwrap().events;

    let ran = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;

    assert!(matches!(ran, Err(SessionError::NoInput)), "{ran:?}");
    assert_eq!(transport.requests(), Vec::<String>::new());
    assert_eq!(store.load(session.id(), None).await.unwrap().events, before);
}

#[tokio::test]
async fn a_session_keeps_its_lease_after_a_failed_request() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([failed_reply("cut")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    let other_writer = store.open(session.id(), Access::Write).await;

    assert!(matches!(failed, Err(SessionError::Round(_))), "{failed:?}");
    assert!(matches!(other_writer, Err(StoreError::Owned)), "{other_writer:?}");
}

#[tokio::test]
async fn an_open_turn_ends_with_an_error_result_for_each_call_without_a_result() {
    let store = Arc::new(MemoryStore::new());
    let id = store.create_session(&settings(), &prompt()).await.unwrap().id;
    let answered = [
        Block::user_text("one"),
        // A provider can give an id again in a later answer.
        Block::ToolCall(ToolCall {
            call_id: "c1".to_owned(),
            name: "read".to_owned(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolResult(ToolResult::success("c1", "text")),
    ];
    let open = [
        Block::ToolCall(ToolCall {
            call_id: "c1".to_owned(),
            name: "read".to_owned(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolCall(ToolCall {
            call_id: "c2".to_owned(),
            name: "write".to_owned(),
            arguments: "{}".to_owned(),
        }),
    ];
    store.commit(id, &step(&answered), &[]).await.unwrap();
    store.commit(id, &step(&open), &[]).await.unwrap();

    let session = Session::open(store.clone(), id).await.unwrap();

    let results: Vec<(&str, bool)> = session.context()[answered.len() + open.len()..]
        .iter()
        .map(|block| match block {
            Block::ToolResult(result) => (result.call_id.as_str(), result.is_error),
            other => panic!("a result was expected, not {other:?}"),
        })
        .collect();
    assert_eq!(results, [("c1", true), ("c2", true)]);
    let saved = store.open(id, Access::Read).await.unwrap();
    assert!(!saved.newest_turn.is_open());
    assert_eq!(saved.context, session.context());
}

#[tokio::test]
async fn a_pending_input_waits_for_the_next_turn_after_an_open() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let id = session.id();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    drop(session);

    let mut session = Session::open(store.clone(), id).await.unwrap();
    let before = store.open(id, Access::Read).await.unwrap();
    let pending = store.pending(id).await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert_eq!(pending.len(), 1);
    assert_eq!(before.context, []);
    assert_in_order(&transport.requests()[0], &["one"]);
    assert_eq!(store.pending(id).await.unwrap(), []);
}

// A store can save new settings after the caller dropped the write, so the session must not trust its old copy.
#[tokio::test]
async fn a_dropped_settings_write_leaves_the_next_turn_with_the_saved_settings() {
    let store = FailingStore::new(StoreBehavior::StallSettings);
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let mut brief = settings();
    brief.settings = yuke_ai::Settings::new().temperature(0.25);
    {
        let mut write = pin!(session.set_settings(brief));
        let polled = write.as_mut().poll(&mut Context::from_waker(Waker::noop()));
        assert!(polled.is_pending());
    }
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    let stale = session.is_stale();
    session.recover().await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(stale);
    assert!(transport.requests()[0].contains(r#""temperature":0.25"#));
}

// The caller gives the driver no prompt, no settings, and no session id. Each comes from the session. The prompt is
// the joined text of the sections.
#[tokio::test]
async fn a_turn_sends_the_prompt_the_settings_and_the_id_of_its_session() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let mut model = model();
    model.target.route.session_header = SessionHeader::XOpencodeSession;
    let mut session_settings = settings();
    session_settings.settings = yuke_ai::Settings::new().temperature(0.25);
    let sections = [
        PromptSection::new("base", "Be brief."),
        PromptSection::new("empty", ""),
        PromptSection::new("environment", "Here."),
    ];
    let mut session = Session::create(store.clone(), &session_settings, &sections)
        .await
        .unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert_in_order(
        &transport.requests()[0],
        &["Be brief.\n\n<environment>\nHere.\n</environment>", "one"],
    );
    assert!(transport.requests()[0].contains(r#""temperature":0.25"#));
    let session_header = Header::new("x-opencode-session", session.id().to_string());
    assert!(
        transport.headers()[0].contains(&session_header),
        "the request headers lack the session header: {:?}",
        transport.headers()
    );
}

#[tokio::test]
async fn a_turn_sends_the_bytes_of_its_media_from_the_store() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("seen")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let blob = store.put_blob(session.id(), b"image-bytes".to_vec()).await.unwrap();
    let input = vec![Block::user_text("look"), Block::Media(Media::new(blob, "image/png"))];
    store
        .accept_input(
            session.id(),
            Input::new(InputSource::User, InputKind::Message, input).unwrap(),
        )
        .await
        .unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    // The driver has no blob store of the caller, so the bytes come through the session.
    assert_in_order(&transport.requests()[0], &["look", "aW1hZ2UtYnl0ZXM="]);
}

#[tokio::test]
async fn input_that_arrives_during_a_turn_joins_the_next_request_and_stays_pending_no_more() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "send", "{}")]), text_reply("done")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let mut toolset = Toolset::new();
    let tool = SendsInput {
        store: store.clone(),
        session: session.id(),
        text: "also this",
    };
    toolset
        .add(
            ToolDefinition {
                name: "send".to_owned(),
                description: "Send input.".to_owned(),
                input_schema: r#"{"type":"object"}"#.to_owned(),
                defer_loading: false,
            },
            tool,
        )
        .unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait).toolset(&toolset))
        .run()
        .await
        .unwrap();

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_in_order(&requests[1], &["one", "c1", "sent", "also this"]);
    assert_eq!(store.pending(session.id()).await.unwrap(), []);
}

#[tokio::test]
async fn a_failed_commit_leaves_the_session_stale_until_a_recovery_ends_the_open_turn() {
    // The second commit of a turn saves its answer.
    let store = FailingStore::new(StoreBehavior::FailCommit(2));
    let transport = ScriptedTransport::new([text_reply("lost"), text_reply("three")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    store.accept_input(session.id(), user_input("two")).await.unwrap();
    let refused = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    let repair = session.recover().await.unwrap().expect("the turn was open");
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(
        matches!(failed, Err(SessionError::Store(StoreError::Failed(_)))),
        "{failed:?}"
    );
    assert!(matches!(refused, Err(SessionError::Stale)), "{refused:?}");
    let SessionEvent::Commit { commit, consumed } = repair.event else {
        panic!("{:?}", repair.event);
    };
    assert_eq!(commit.end, Some(TurnEnd::Failed(TURN_STOPPED.to_owned())));
    assert_eq!(consumed, []);
    let second = &transport.requests()[1];
    assert_in_order(second, &["one", "two"]);
    assert!(!second.contains("lost"), "{second}");
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert_eq!(
        saved.context,
        [
            Block::user_text("one"),
            Block::user_text("two"),
            Block::user_text(format!(
                r#"<system_notification plugin="host:session">The previous turn ended with an error: {TURN_STOPPED}</system_notification>"#
            )),
            Block::assistant_text("three")
        ]
    );
}

#[tokio::test]
async fn the_input_of_a_failed_commit_joins_the_next_turn_and_is_consumed_once() {
    // The first commit of a turn saves its input, before any request.
    let store = FailingStore::new(StoreBehavior::FailCommit(1));
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let input = store.accept_input(session.id(), user_input("one")).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    // The failed commit saved nothing, so no turn was open.
    let repair = session.recover().await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(failed.is_err(), "{failed:?}");
    assert!(repair.is_none(), "{repair:?}");
    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    assert_in_order(&requests[0], &["one"]);
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert_eq!(saved.context, [Block::user_text("one"), Block::assistant_text("two")]);
    assert_eq!(store.pending(session.id()).await.unwrap(), []);
    let ids: Vec<InputId> = consumed_inputs(&*store, session.id())
        .await
        .iter()
        .map(|consumed| consumed.id)
        .collect();
    assert_eq!(ids, [input]);
}

#[tokio::test]
async fn the_model_reads_the_model_content_and_the_saved_record_keeps_what_the_user_saw() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("noted")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let source = InputSource::Plugin {
        name: "host:jobs".to_owned(),
    };
    let input = Input::new(
        source.clone(),
        InputKind::Notification,
        vec![Block::user_text("job-1 finished")],
    )
    .unwrap()
    .with_model_content(vec![
        Block::user_text("job-1 ended with exit code 0."),
        Block::user_text("Read its output file."),
    ])
    .unwrap();
    let first = store.accept_input(session.id(), input).await.unwrap();
    let second = store.accept_input(session.id(), user_input("thanks")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    let request = &transport.requests()[0];
    assert_in_order(
        request,
        &["job-1 ended with exit code 0.", "Read its output file.", "thanks"],
    );
    assert!(!request.contains("job-1 finished"), "{request}");
    assert_eq!(
        consumed_inputs(&*store, session.id()).await,
        [
            ConsumedInput {
                id: first,
                source,
                kind: InputKind::Notification,
                display_content: Some(vec![Block::user_text("job-1 finished")]),
                block_count: 2,
            },
            ConsumedInput {
                id: second,
                source: InputSource::User,
                kind: InputKind::Message,
                display_content: None,
                block_count: 1,
            },
        ]
    );
}

#[tokio::test]
async fn a_dropped_turn_releases_the_lease_and_the_next_turn_reads_a_note_about_it() {
    let store = Arc::new(MemoryStore::new());
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    {
        let mut run = pin!(session.turn(Driver::new(&Stalled, &model, &NoWait)).run());
        // The turn saves its input, sends the request, and waits for the answer that never comes.
        let poll = run.as_mut().poll(&mut Context::from_waker(Waker::noop()));
        assert!(poll.is_pending());
    }
    let other_writer = store.open(session.id(), Access::Write).await.map(drop);
    session.recover().await.unwrap();
    let transport = ScriptedTransport::new([text_reply("three")]);
    // The interrupted turn ended at the recovery, so no turn runs before the next input.
    let idle = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    store.accept_input(session.id(), user_input("two")).await.unwrap();
    store.accept_input(session.id(), user_input("also two")).await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(other_writer.is_ok(), "{other_writer:?}");
    assert!(matches!(idle, Err(SessionError::NoInput)), "{idle:?}");
    let note = format!("The previous turn ended with an error: {TURN_STOPPED}");
    let request = &transport.requests()[0];
    assert_in_order(
        request,
        &[
            "one",
            "two",
            "also two",
            &format!(r#"<system_notification plugin="host:session">{note}</system_notification>"#),
        ],
    );
    assert_eq!(request.matches("<system_notification").count(), 1, "{request}");
    let consumed = consumed_inputs(&*store, session.id()).await;
    let note = consumed.last().unwrap();
    assert_eq!(
        note.source,
        InputSource::Plugin {
            name: "host:session".to_owned()
        }
    );
    assert_eq!(note.kind, InputKind::Notification);
    assert_eq!(note.block_count, 1);
    assert_eq!(
        note.display_content,
        Some(vec![Block::user_text("The previous turn failed.")])
    );
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert!(!saved.newest_turn.is_open());
    assert_eq!(saved.context.last(), Some(&Block::assistant_text("three")));
}

#[tokio::test]
async fn new_settings_give_their_event_number_and_a_removed_input_never_reaches_the_model() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let removed = store.accept_input(session.id(), user_input("removed")).await.unwrap();
    store.accept_input(session.id(), user_input("kept")).await.unwrap();

    let event_number = session.set_settings(settings()).await.unwrap();
    store.remove_input(session.id(), removed).await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert_eq!(event_number, yuke_protocol::EventNumber(2));
    let request = &transport.requests()[0];
    assert_in_order(request, &["kept"]);
    assert!(!request.contains("removed"), "{request}");
}

#[tokio::test]
async fn a_stale_session_refuses_new_settings_and_its_recovery_gets_owned_while_another_writer_holds_it() {
    let store = Arc::new(MemoryStore::new());
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    {
        let mut run = pin!(session.turn(Driver::new(&Stalled, &model, &NoWait)).run());
        assert!(run.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
    }
    #[expect(
        unused_variables,
        reason = "the other writer holds the lock while the session changes its settings"
    )]
    let other_writer = store.open(session.id(), Access::Write).await.unwrap();
    let other_model = SessionSettings {
        model: ModelReference {
            provider: "test".to_owned(),
            model: "other-model".to_owned(),
        },
        ..settings()
    };

    let changed = session.set_settings(other_model).await;
    let recovered = session.recover().await;

    assert!(matches!(changed, Err(SessionError::Stale)), "{changed:?}");
    assert!(matches!(recovered, Err(StoreError::Owned)), "{recovered:?}");
    assert!(session.is_stale());
    assert_eq!(
        store.open(session.id(), Access::Read).await.unwrap().settings,
        settings()
    );
}

#[tokio::test]
async fn a_cancelled_turn_gives_the_next_turn_a_note_after_its_input() {
    let store = Arc::new(MemoryStore::new());
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    let token = yuke_engine::CancellationToken::new();
    {
        let mut run = pin!(
            session
                .turn(Driver::new(&Stalled, &model, &NoWait))
                .cancellation_token(token.clone())
                .run()
        );
        assert!(run.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
        token.cancel();
        let ended = run.await;
        assert!(matches!(ended, Ok(yuke_engine::Outcome::Cancelled)), "{ended:?}");
    }
    let transport = ScriptedTransport::new([text_reply("three")]);
    store.accept_input(session.id(), user_input("two")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert_in_order(
        &transport.requests()[0],
        &[
            "one",
            "two",
            r#"<system_notification plugin="host:session">The user cancelled the previous turn before it ended.</system_notification>"#,
        ],
    );
    let consumed = consumed_inputs(&*store, session.id()).await;
    let [.., two, note] = consumed.as_slice() else {
        panic!("{consumed:?}");
    };
    assert_eq!((two.display_content.as_ref(), two.block_count), (None, 1));
    assert_eq!(
        note.display_content,
        Some(vec![Block::user_text("The previous turn was cancelled.")])
    );
}

#[tokio::test]
async fn a_failed_turn_gives_the_next_turn_a_note_also_after_an_open_and_a_completed_turn_gives_none() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("three"), text_reply("five")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    let failed = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    let id = session.id();
    drop(session);

    // A new open reads the end of the failed turn from the store.
    let mut session = Session::open(store.clone(), id).await.unwrap();
    store.accept_input(session.id(), user_input("two")).await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();
    store.accept_input(session.id(), user_input("four")).await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(matches!(failed, Err(SessionError::Round(_))), "{failed:?}");
    let requests = transport.requests();
    let note = r#"<system_notification plugin=\"host:session\">The previous turn ended with an error: "#;
    assert!(requests[1].contains(note), "{}", requests[1]);
    assert!(requests[1].find("\"two\"") < requests[1].find(note), "{}", requests[1]);
    // The note went with the turn after the failure, and the request after a completed turn adds none.
    assert_eq!(
        requests[2].matches("<system_notification").count(),
        1,
        "{}",
        requests[2]
    );
}

#[tokio::test]
async fn a_failed_turn_gives_the_next_turn_of_the_same_session_a_note() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("three")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    let failed = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    store.accept_input(session.id(), user_input("two")).await.unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(matches!(failed, Err(SessionError::Round(_))), "{failed:?}");
    let request = &transport.requests()[1];
    assert!(request.contains("The previous turn ended with an error: "), "{request}");
}

#[tokio::test]
async fn a_failed_read_of_the_inbox_after_a_round_ends_the_turn_as_failed_and_keeps_the_session() {
    // The commits save the input and the answer. The read after the round fails.
    let store = FailingStore::new(StoreBehavior::FailPendingAfterCommits(2));
    let transport = ScriptedTransport::new([text_reply("two")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();

    let ran = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;

    assert!(
        matches!(&ran, Err(SessionError::Round(RoundError::Inbox(error))) if chain_text(error.as_ref()) == "the store failed: the disk is gone"),
        "{ran:?}"
    );
    assert!(!session.is_stale());
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert_eq!(
        saved.newest_turn,
        NewestTurn::Ended(TurnEnd::Failed("the store failed: the disk is gone".to_owned()))
    );
}

#[tokio::test]
async fn a_note_that_a_failed_first_commit_left_pending_goes_to_the_model_once() {
    // The first turn saves its input and its cancelled end. The first commit of the second turn fails.
    let store = FailingStore::new(StoreBehavior::FailCommit(3));
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    let token = yuke_engine::CancellationToken::new();
    {
        let mut run = pin!(
            session
                .turn(Driver::new(&Stalled, &model, &NoWait))
                .cancellation_token(token.clone())
                .run()
        );
        assert!(run.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
        token.cancel();
        run.await.unwrap();
    }
    store.accept_input(session.id(), user_input("two")).await.unwrap();
    let transport = ScriptedTransport::new([text_reply("three")]);

    let failed = session.turn(Driver::new(&transport, &model, &NoWait)).run().await;
    session.recover().await.unwrap();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(matches!(failed, Err(SessionError::Store(_))), "{failed:?}");
    let request = &transport.requests()[0];
    assert_eq!(request.matches("<system_notification").count(), 1, "{request}");
}

// A panic can leave the session with its lease, so a recovery must also work on a session that is not stale.
#[tokio::test]
async fn a_recovery_of_a_session_that_holds_its_lease_opens_it_again() {
    let store = Arc::new(MemoryStore::new());
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();

    let recovered = session.recover().await;
    let other_writer = store.open(session.id(), Access::Write).await;

    assert!(matches!(recovered, Ok(None)), "{recovered:?}");
    assert!(!session.is_stale());
    assert!(matches!(other_writer, Err(StoreError::Owned)), "{other_writer:?}");
}

// A session that holds its lease reads the store under it, so no other writer can take the session during a recovery.
#[tokio::test]
async fn a_recovery_under_the_lease_needs_no_open_for_writing() {
    let store = FailingStore::new(StoreBehavior::RefuseWriteOpen);
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();

    let recovered = session.recover().await;

    assert!(matches!(recovered, Ok(None)), "{recovered:?}");
    assert!(!session.is_stale());
}

/// Hooks that keep the input tokens of each round start.
#[derive(Default)]
struct InputTokens(std::sync::Mutex<Vec<Option<u64>>>);

#[async_trait::async_trait]
impl Hooks for InputTokens {
    async fn before_round(
        &self,
        round: &RoundStart<'_>,
    ) -> Result<RoundPlan, Box<dyn std::error::Error + Send + Sync>> {
        self.0.lock().unwrap().push(round.input_tokens);
        Ok(RoundPlan::default())
    }
}

#[tokio::test]
async fn a_turn_starts_from_the_input_tokens_of_the_newest_answer_also_after_an_open() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([
        counted(&text_reply("two"), 900),
        counted(&text_reply("four"), 1500),
        text_reply("six"),
    ]);
    let model = model();
    let hooks = InputTokens::default();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    for text in ["one", "three"] {
        store.accept_input(session.id(), user_input(text)).await.unwrap();
        let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
        session.turn(driver).run().await.unwrap();
    }
    let id = session.id();
    drop(session);
    let mut again = Session::open(store.clone(), id).await.unwrap();
    store.accept_input(id, user_input("five")).await.unwrap();

    again
        .turn(Driver::new(&transport, &model, &NoWait).hooks(&hooks))
        .run()
        .await
        .unwrap();

    assert_eq!(*hooks.0.lock().unwrap(), [None, Some(900), Some(1500)]);
}
