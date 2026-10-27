//! The input hook of a turn: it keeps, replaces, or removes each pending input before the turn takes it.

use std::pin::pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Waker};

use async_trait::async_trait;
use yuke_agent::{InputDecision, InputHook, MemoryStore, Session, SessionError, SessionObserver, Store};
use yuke_ai::Block;
use yuke_ai::scripted::{ScriptedTransport, Stalled, text_reply, tool_reply};
use yuke_engine::NoWait;
use yuke_engine::{CancellationToken, Driver, Outcome, Toolset, chain_text};
use yuke_protocol::{LiveUpdate, PendingInput, SessionId, SessionUpdate};
use yuke_testing::{assert_in_order, definition, model};

use crate::support::{SendsInput, consumed_inputs, prompt, settings, user_input};

/// Keeps each text that it sees, and answers each input by its text.
/// - "drop": remove. "/skill:pdf": the skill text. "fail": a failure. Other texts: keep.
#[derive(Default)]
struct ByText(Mutex<Vec<String>>);

#[async_trait]
impl InputHook for ByText {
    async fn before_input(
        &self,
        input: &PendingInput,
    ) -> Result<InputDecision, Box<dyn std::error::Error + Send + Sync>> {
        let text = match input.input.model_content() {
            [Block::UserText(text)] => text.clone(),
            other => format!("{other:?}"),
        };
        self.0.lock().unwrap().push(text.clone());
        match text.as_str() {
            "drop" => Ok(InputDecision::Remove),
            "/skill:pdf" => Ok(InputDecision::Replace(vec![Block::user_text("the skill text")])),
            "fail" => Err("the hook is down".into()),
            _ => Ok(InputDecision::Keep),
        }
    }
}

/// Keeps each update.
#[derive(Default)]
struct Capture(Mutex<Vec<SessionUpdate>>);

impl SessionObserver for Capture {
    fn update(&self, update: SessionUpdate) {
        self.0.lock().unwrap().push(update);
    }
}

#[tokio::test]
async fn a_removed_input_leaves_the_store_and_starts_no_turn() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    let input_id = store.accept_input(session.id(), user_input("drop")).await.unwrap();
    let observer = Capture::default();

    let ran = session
        .turn(Driver::new(&transport, &model, &NoWait))
        .input_hook(&ByText::default())
        .observer(&observer)
        .run()
        .await;

    assert!(matches!(ran, Err(SessionError::NoInput)), "{ran:?}");
    assert_eq!(store.pending(session.id()).await.unwrap(), Vec::new());
    assert_eq!(transport.requests(), Vec::<String>::new());
    assert_eq!(
        *observer.0.lock().unwrap(),
        [SessionUpdate::Live(LiveUpdate::InputRemoved { input_id })]
    );
}

#[tokio::test]
async fn a_replaced_input_gives_the_model_the_new_blocks_and_keeps_the_sent_content() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store
        .accept_input(session.id(), user_input("/skill:pdf"))
        .await
        .unwrap();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .input_hook(&ByText::default())
        .run()
        .await
        .unwrap();

    let request = &transport.requests()[0];
    assert!(
        request.contains("the skill text") && !request.contains("/skill:pdf"),
        "{request}"
    );
    assert_eq!(session.context()[0], Block::user_text("the skill text"));
    let consumed = consumed_inputs(&*store, session.id()).await;
    assert_eq!(consumed[0].display_content, Some(vec![Block::user_text("/skill:pdf")]));
    assert_eq!(consumed[0].block_count, 1);
}

#[tokio::test]
async fn an_input_during_a_turn_passes_the_hook_at_the_take_after_the_round() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "send", "{}")]), text_reply("done")]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("go")).await.unwrap();
    let mut toolset = Toolset::new();
    let send = SendsInput {
        store: store.clone(),
        session: session.id(),
        text: "/skill:pdf",
    };
    toolset.add(definition("send"), send).unwrap();
    let hook = ByText::default();

    session
        .turn(Driver::new(&transport, &model, &NoWait).toolset(&toolset))
        .input_hook(&hook)
        .run()
        .await
        .unwrap();

    assert_eq!(*hook.0.lock().unwrap(), ["go", "/skill:pdf"]);
    assert_in_order(&transport.requests()[1], &["go", "the skill text"]);
}

#[tokio::test]
async fn a_failed_hook_fails_the_turn_and_the_input_stays_pending() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("fail")).await.unwrap();

    let ran = session
        .turn(Driver::new(&transport, &model, &NoWait))
        .input_hook(&ByText::default())
        .run()
        .await;

    let Err(error @ SessionError::InputHook(_)) = ran else {
        panic!("{ran:?}")
    };
    assert_eq!(chain_text(&error), "the input hook failed: the hook is down");
    assert_eq!(store.pending(session.id()).await.unwrap().len(), 1);
    assert_eq!(transport.requests(), Vec::<String>::new());
}

#[tokio::test]
async fn the_note_of_the_session_passes_without_the_hook() {
    let store = Arc::new(MemoryStore::new());
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("one")).await.unwrap();
    let token = CancellationToken::new();
    {
        let mut run = pin!(
            session
                .turn(Driver::new(&Stalled, &model, &NoWait))
                .cancellation_token(token.clone())
                .run()
        );
        assert!(run.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
        token.cancel();
        assert!(matches!(run.await, Ok(Outcome::Cancelled)));
    }
    let transport = ScriptedTransport::new([text_reply("three")]);
    store.accept_input(session.id(), user_input("two")).await.unwrap();
    let hook = ByText::default();

    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .input_hook(&hook)
        .run()
        .await
        .unwrap();

    // The cancelled turn consumed "one", so this turn takes "two" and the note.
    assert_eq!(*hook.0.lock().unwrap(), ["two"]);
    assert!(transport.requests()[0].contains("The user cancelled the previous turn"));
}

/// Removes the input from the store while it decides, as a client can, and then answers its decision.
struct RemovedMeanwhile(Arc<MemoryStore>, SessionId, InputDecision);

#[async_trait]
impl InputHook for RemovedMeanwhile {
    async fn before_input(
        &self,
        input: &PendingInput,
    ) -> Result<InputDecision, Box<dyn std::error::Error + Send + Sync>> {
        self.0.remove_input(self.1, input.id).await?;
        Ok(self.2.clone())
    }
}

#[tokio::test]
async fn an_input_that_a_client_removes_during_the_hook_starts_no_turn() {
    let store = Arc::new(MemoryStore::new());
    let transport = ScriptedTransport::new([]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("hi")).await.unwrap();
    let hook = RemovedMeanwhile(store.clone(), session.id(), InputDecision::Keep);

    let ran = session
        .turn(Driver::new(&transport, &model, &NoWait))
        .input_hook(&hook)
        .run()
        .await;

    assert!(matches!(ran, Err(SessionError::NoInput)), "{ran:?}");
    assert!(!session.is_stale());
    assert_eq!(transport.requests(), Vec::<String>::new());
}

// The removal of the client sent its update, so the removal of the hook sends none.
#[tokio::test]
async fn a_removal_of_the_hook_after_a_removal_of_the_client_sends_no_second_update() {
    let store = Arc::new(MemoryStore::new());
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), &prompt()).await.unwrap();
    store.accept_input(session.id(), user_input("hi")).await.unwrap();
    let hook = RemovedMeanwhile(store.clone(), session.id(), InputDecision::Remove);
    let observer = Capture::default();

    let ran = session
        .turn(Driver::new(&ScriptedTransport::new([]), &model, &NoWait))
        .input_hook(&hook)
        .observer(&observer)
        .run()
        .await;

    assert!(matches!(ran, Err(SessionError::NoInput)), "{ran:?}");
    assert_eq!(*observer.0.lock().unwrap(), Vec::new());
}
