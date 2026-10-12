//! A session over a memory store: it opens again with its context, ends an open turn, keeps pending inputs,
//! takes input during a turn, and opens again after a failed commit.
#![expect(clippy::unwrap_used, clippy::expect_used, reason = "a test fails by panicking")]

mod support;

use std::sync::Arc;

use std::pin::pin;
use std::task::{Context, Waker};

use support::{
    FailingStore, NoWait, ScriptedTransport, SendsInput, Stalled, assert_in_order, failed_reply, settings, target,
    text_reply, tool_reply,
};
use yuke_agent::{
    Access, InputId, MemoryStore, ModelReference, Session, SessionError, SessionEvent, SessionSettings, Store,
    StoreError,
};
use yuke_ai::{Block, Media, ToolCall, ToolDefinition, ToolResult};
use yuke_engine::{Commit, Driver, Toolset};

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
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    session
        .turn(Driver::new(&transport, &target, &NoWait))
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
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();
    let other_writer = store.open(session.id(), Access::Write).await;

    assert!(matches!(other_writer, Err(StoreError::Owned)), "{other_writer:?}");
}

#[tokio::test]
async fn a_session_keeps_its_lease_after_a_failed_request() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([failed_reply("cut")]);
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &target, &NoWait)).run().await;
    let other_writer = store.open(session.id(), Access::Write).await;

    assert!(matches!(failed, Err(SessionError::Model(_))), "{failed:?}");
    assert!(matches!(other_writer, Err(StoreError::Owned)), "{other_writer:?}");
}

#[tokio::test]
async fn an_open_turn_ends_with_an_error_result_for_each_call_without_a_result() {
    let store = Arc::new(MemoryStore::new());
    let id = store.create_session(&settings()).await.unwrap().id;
    let answered = [
        Block::user_text("one"),
        // A provider can give an id again in a later answer.
        Block::ToolCall(ToolCall::new("c1", "read", "{}")),
        Block::ToolResult(ToolResult::success("c1", "text")),
    ];
    let open = [
        Block::ToolCall(ToolCall::new("c1", "read", "{}")),
        Block::ToolCall(ToolCall::new("c2", "write", "{}")),
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
    assert!(!saved.turn_open);
    assert_eq!(saved.context, session.context());
}

#[tokio::test]
async fn a_pending_input_waits_for_the_next_turn_after_an_open() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("two")]);
    let target = target();
    let session = Session::create(store.clone(), settings()).await.unwrap();
    let id = session.id();
    session.input().send(&[Block::user_text("one")]).await.unwrap();
    drop(session);

    let mut session = Session::open(store.clone(), id).await.unwrap();
    let before = store.open(id, Access::Read).await.unwrap();
    let pending = store.pending(id).await.unwrap();
    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();

    assert_eq!(pending.len(), 1);
    assert_eq!(before.context, []);
    assert_in_order(&transport.requests()[0], &["one"]);
    assert_eq!(store.pending(id).await.unwrap(), []);
}

#[tokio::test]
async fn a_turn_sends_the_bytes_of_its_media_from_the_store() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("seen")]);
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    let blob = store.put_blob(session.id(), b"image-bytes".to_vec()).await.unwrap();
    let input = [Block::user_text("look"), Block::Media(Media::new(blob, "image/png"))];
    session.input().send(&input).await.unwrap();

    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();

    // The driver has no blob store of the caller, so the bytes come through the session.
    assert_in_order(&transport.requests()[0], &["look", "aW1hZ2UtYnl0ZXM="]);
}

#[tokio::test]
async fn input_that_arrives_during_a_turn_joins_the_next_request_and_stays_pending_no_more() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([tool_reply("c1", "send"), text_reply("done")]);
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    let mut toolset = Toolset::new();
    let tool = SendsInput {
        sender: session.input(),
        text: "also this",
    };
    toolset
        .add(ToolDefinition::new("send", "Send input.", r#"{"type":"object"}"#), tool)
        .unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    session
        .turn(Driver::new(&transport, &target, &NoWait).toolset(&toolset))
        .run()
        .await
        .unwrap();

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_in_order(&requests[1], &["one", "c1", "sent", "also this"]);
    assert_eq!(store.pending(session.id()).await.unwrap(), []);
}

#[tokio::test]
async fn a_failed_commit_makes_the_next_turn_open_the_session_again() {
    // The second commit of a turn saves its answer.
    let store = FailingStore::new(2);
    let transport = ScriptedTransport::new([text_reply("lost"), text_reply("three")]);
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &target, &NoWait)).run().await;
    session.input().send(&[Block::user_text("two")]).await.unwrap();
    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(
        matches!(failed, Err(SessionError::Store(StoreError::Failed(_)))),
        "{failed:?}"
    );
    let second = &transport.requests()[1];
    assert_in_order(second, &["one", "two"]);
    assert!(!second.contains("lost"), "{second}");
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert_eq!(
        saved.context,
        [
            Block::user_text("one"),
            Block::user_text("two"),
            Block::assistant_text("three")
        ]
    );
}

#[tokio::test]
async fn the_input_of_a_failed_commit_joins_the_next_turn() {
    // The first commit of a turn saves its input, before any request.
    let store = FailingStore::new(1);
    let transport = ScriptedTransport::new([text_reply("two")]);
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &target, &NoWait)).run().await;
    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(failed.is_err(), "{failed:?}");
    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    assert_in_order(&requests[0], &["one"]);
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert_eq!(saved.context, [Block::user_text("one"), Block::assistant_text("two")]);
    assert_eq!(store.pending(session.id()).await.unwrap(), []);
}

#[tokio::test]
async fn after_a_failed_commit_the_next_turn_consumes_each_input_once() {
    // The first commit of a turn saves its input, before any request.
    let store = FailingStore::new(1);
    let transport = ScriptedTransport::new([text_reply("two")]);
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    let input = session.input().send(&[Block::user_text("one")]).await.unwrap();

    let failed = session.turn(Driver::new(&transport, &target, &NoWait)).run().await;
    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(failed.is_err(), "{failed:?}");
    let consumed: Vec<InputId> = store
        .events(session.id(), None)
        .await
        .unwrap()
        .into_iter()
        .flat_map(|stored| match stored.event {
            SessionEvent::Commit { consumed, .. } => consumed,
            SessionEvent::Settings(_) => Vec::new(),
        })
        .collect();
    assert_eq!(consumed, [input]);
}

#[tokio::test]
async fn a_dropped_turn_releases_the_lease_and_the_next_turn_opens_the_session_again() {
    let store = Arc::new(MemoryStore::new());
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();

    {
        let mut run = pin!(session.turn(Driver::new(&Stalled, &target, &NoWait)).run());
        // The turn saves its input, sends the request, and waits for the answer that never comes.
        let poll = run.as_mut().poll(&mut Context::from_waker(Waker::noop()));
        assert!(poll.is_pending());
    }
    let other_writer = store.open(session.id(), Access::Write).await.map(drop);
    let transport = ScriptedTransport::new([text_reply("two")]);
    session
        .turn(Driver::new(&transport, &target, &NoWait))
        .run()
        .await
        .unwrap();

    assert!(other_writer.is_ok(), "{other_writer:?}");
    assert_in_order(&transport.requests()[0], &["one"]);
    let saved = store.open(session.id(), Access::Read).await.unwrap();
    assert!(!saved.turn_open);
    assert_eq!(saved.context.last(), Some(&Block::assistant_text("two")));
}

#[tokio::test]
async fn new_settings_after_a_dropped_turn_get_owned_while_another_writer_holds_the_session() {
    let store = Arc::new(MemoryStore::new());
    let target = target();
    let mut session = Session::create(store.clone(), settings()).await.unwrap();
    session.input().send(&[Block::user_text("one")]).await.unwrap();
    {
        let mut run = pin!(session.turn(Driver::new(&Stalled, &target, &NoWait)).run());
        assert!(run.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
    }
    let _other_writer = store.open(session.id(), Access::Write).await.unwrap();
    let other_model = SessionSettings {
        model: ModelReference::new("test", "other-model"),
        ..settings()
    };

    let changed = session.set_settings(other_model).await;

    assert!(matches!(changed, Err(StoreError::Owned)), "{changed:?}");
    assert_eq!(
        store.open(session.id(), Access::Read).await.unwrap().settings,
        settings()
    );
}
