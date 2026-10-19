//! Public session observations across model streams, tool execution, and durable writes.

use std::pin::pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Waker};

use async_trait::async_trait;
use yuke_agent::{MemoryStore, Session, SessionObserver, Store};
use yuke_ai::route::Credential;
use yuke_ai::{Block, ToolDefinition, Wire};
use yuke_engine::{CancellationToken, Concurrency, CredentialSource, Driver, Model, Tool, ToolContent, ToolContext};
use yuke_protocol::{
    BlockPosition, DraftDiscardReason, DraftId, EventNumber, LiveUpdate, ModelUpdate, SessionEvent, SessionUpdate,
    SessionUpdateParams,
};
use yuke_testing::{
    NoWait, ScriptedTransport, Stalled, failed_reply, model, model_of, sse, target, text_reply, tool_reply,
};

use super::support::{FailingStore, StoreBehavior, settings, user_input};

#[derive(Default)]
struct Capture(Mutex<Vec<SessionUpdateParams>>);

impl SessionObserver for Capture {
    fn update(&self, update: SessionUpdateParams) {
        self.0.lock().unwrap().push(update);
    }
}

impl Capture {
    fn live(&self) -> Vec<LiveUpdate> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|update| match &update.update {
                SessionUpdate::Live(live) => Some(live.clone()),
                SessionUpdate::Saved(_) => None,
            })
            .collect()
    }

    fn drafts(&self) -> Vec<DraftId> {
        self.live()
            .iter()
            .filter_map(|update| match update {
                LiveUpdate::DraftStarted { draft_id } => Some(*draft_id),
                _ => None,
            })
            .collect()
    }

    fn positions(&self) -> Vec<(u64, u32, usize)> {
        self.live()
            .iter()
            .flat_map(|update| match update {
                LiveUpdate::DraftCommitted {
                    event_number, blocks, ..
                } => blocks
                    .iter()
                    .enumerate()
                    .map(|(block_index, block)| (event_number.0, *block, block_index))
                    .collect(),
                _ => Vec::new(),
            })
            .collect()
    }
}

#[tokio::test]
async fn session_updates_preserve_interleaved_blocks_and_confirm_the_saved_answer() {
    let transport = ScriptedTransport::new([sse(&[
        r#"{"choices":[{"index":0,"delta":{"reasoning_content":"why"}}]}"#,
        r#"{"choices":[{"index":0,"delta":{"content":"Hello"}}]}"#,
        r#"{"choices":[{"index":0,"delta":{"reasoning_content":" now"}}]}"#,
        r#"{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}"#,
        "[DONE]",
    ])]);
    let model = model_of(yuke_ai::Target {
        wire: Wire::OpenaiChat(yuke_ai::ChatWire::default()),
        ..target()
    });
    let store = Arc::new(MemoryStore::new());
    let mut session = Session::create(store.clone(), &settings(), "the prompt").await.unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&capture)
        .run()
        .await
        .unwrap();

    let drafts = capture.drafts();
    assert_eq!(drafts.len(), 1);
    let live = capture.live();
    let events: Vec<ModelUpdate> = live
        .iter()
        .filter_map(|update| match update {
            LiveUpdate::Model { draft_id, event } => {
                assert_eq!(*draft_id, drafts[0]);
                Some(event.clone())
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        &events[..8],
        [
            ModelUpdate::BlockStarted {
                block: 0,
                block_kind: yuke_ai::BlockKind::Reasoning
            },
            ModelUpdate::ReasoningDelta {
                block: 0,
                text: "why".into()
            },
            ModelUpdate::BlockStarted {
                block: 1,
                block_kind: yuke_ai::BlockKind::Text
            },
            ModelUpdate::TextDelta {
                block: 1,
                text: "Hello".into()
            },
            ModelUpdate::ReasoningDelta {
                block: 0,
                text: " now".into()
            },
            ModelUpdate::TextDelta {
                block: 1,
                text: " world".into()
            },
            ModelUpdate::BlockStopped { block: 0, call: None },
            ModelUpdate::BlockStopped { block: 1, call: None },
        ]
    );
    assert!(matches!(
        &events[8],
        ModelUpdate::ResponseCompleted {
            finish_reason: yuke_ai::FinishReason::Stop,
            ..
        }
    ));
    assert_eq!(capture.positions(), [(3, 0, 0), (3, 1, 1)]);
    let updates = capture.0.lock().unwrap().clone();
    assert!(updates.iter().all(|update| update.session_id == session.id()));
    let saved: Vec<_> = updates
        .iter()
        .filter_map(|update| match &update.update {
            SessionUpdate::Saved(event) => Some(event.clone()),
            SessionUpdate::Live(_) => None,
        })
        .collect();
    assert_eq!(
        saved,
        store
            .load(session.id(), Some(EventNumber(1)))
            .await
            .map(|loaded| loaded.events)
            .unwrap()
    );
    let confirmed = updates
        .iter()
        .position(|update| matches!(update.update, SessionUpdate::Live(LiveUpdate::DraftCommitted { .. })))
        .unwrap();
    assert!(
        matches!(&updates[confirmed - 1].update, SessionUpdate::Saved(event) if event.event_number == EventNumber(3))
    );
    assert_eq!(session.context()[2], Block::assistant_text("Hello world"));
}

#[tokio::test]
async fn unfinished_blocks_do_not_shift_live_to_saved_positions() {
    let transport = ScriptedTransport::new([sse(&[
        r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"unfinished","name":"send"}}"#,
        r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","status":"incomplete","arguments":"{}"}}"#,
        r#"{"type":"response.output_item.added","output_index":1,"item":{"type":"message"}}"#,
        r#"{"type":"response.content_part.added","output_index":1,"content_index":0,"part":{"type":"output_text"}}"#,
        r#"{"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"answer"}"#,
        r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
    ])]);
    let model = model_of(yuke_ai::Target {
        wire: Wire::OpenaiResponses(yuke_ai::ResponsesWire::default()),
        ..target()
    });
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&capture)
        .run()
        .await
        .unwrap();
    assert_eq!(capture.positions(), [(3, 1, 0)]);
    assert_eq!(
        session.context(),
        [Block::user_text("go"), Block::assistant_text("answer")]
    );
    let starts: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::Model {
                event: ModelUpdate::BlockStarted { block, .. },
                ..
            } => Some(block),
            _ => None,
        })
        .collect();
    assert_eq!(starts, [0, 1]);
}

struct Echo;

#[async_trait]
impl Tool for Echo {
    fn concurrency(&self) -> Concurrency {
        Concurrency::Parallel
    }
    async fn call(&self, arguments: &str, context: &ToolContext<'_>) -> Result<ToolContent, String> {
        if arguments == r#"{"wait":true}"# {
            tokio::task::yield_now().await;
        }
        context.output(arguments);
        Ok(arguments.to_owned().into())
    }
}

fn tools() -> yuke_engine::Toolset {
    let mut tools = yuke_engine::Toolset::new();
    tools
        .add(
            ToolDefinition {
                name: "send".into(),
                description: "Echo arguments.".into(),
                input_schema: r#"{"type":"object"}"#.into(),
                defer_loading: false,
            },
            Echo,
        )
        .unwrap();
    tools
}

#[tokio::test]
async fn repeated_provider_ids_use_distinct_saved_execution_positions() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "send", "{}")]),
        tool_reply(&[("c1", "send", "{}")]),
        text_reply("done"),
    ]);
    let model = model();
    let tools = tools();
    let store = Arc::new(MemoryStore::new());
    let mut session = Session::create(store.clone(), &settings(), "the prompt").await.unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait).toolset(&tools))
        .observer(&capture)
        .run()
        .await
        .unwrap();
    let facts: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::ToolStarted { execution, call } => Some(("start", execution, call.call_id)),
            LiveUpdate::ToolOutput { execution, text } => Some(("output", execution, text)),
            LiveUpdate::ToolFinished { execution, result } => Some(("finish", execution, result.call_id)),
            _ => None,
        })
        .collect();
    let first = BlockPosition {
        event_number: EventNumber(3),
        block_index: 0,
    };
    let second = BlockPosition {
        event_number: EventNumber(5),
        block_index: 0,
    };
    assert_eq!(
        facts,
        [
            ("start", first, "c1".into()),
            ("output", first, "{}".into()),
            ("finish", first, "c1".into()),
            ("start", second, "c1".into()),
            ("output", second, "{}".into()),
            ("finish", second, "c1".into()),
        ]
    );
    assert_eq!(capture.positions(), [(3, 0, 0), (5, 0, 0), (7, 0, 0)]);
    let id = session.id();
    drop(session);
    let reopened = Session::open(store.clone(), id).await.unwrap();
    let calls: Vec<_> = store
        .load(id, None)
        .await
        .map(|loaded| loaded.events)
        .unwrap()
        .into_iter()
        .flat_map(|stored| match stored.event {
            SessionEvent::Commit { commit, .. } => commit
                .blocks
                .iter()
                .enumerate()
                .filter_map(|(index, block)| match block {
                    Block::ToolCall(call) => Some((stored.event_number.0, index, call.call_id.clone())),
                    _ => None,
                })
                .collect(),
            SessionEvent::Settings(_) => Vec::new(),
        })
        .collect();
    assert_eq!(calls, [(3, 0, "c1".into()), (5, 0, "c1".into())]);
    assert_eq!(reopened.context().last(), Some(&Block::assistant_text("done")));
}

#[tokio::test]
async fn failed_attempts_discard_their_drafts_and_retry_uses_a_new_identity() {
    let overloaded = sse(&[r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]);
    let transport = ScriptedTransport::new([overloaded, text_reply("done")]);
    let model = model();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&capture)
        .run()
        .await
        .unwrap();
    let drafts = capture.drafts();
    assert_eq!(drafts.len(), 2);
    assert_ne!(drafts[0], drafts[1]);
    let lifecycle: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::DraftStarted { draft_id } => Some((draft_id, "start")),
            LiveUpdate::DraftDiscarded {
                draft_id,
                reason: DraftDiscardReason::Failed,
            } => Some((draft_id, "failed")),
            LiveUpdate::DraftCommitted { draft_id, .. } => Some((draft_id, "saved")),
            _ => None,
        })
        .collect();
    assert_eq!(
        lifecycle,
        [
            (drafts[0], "start"),
            (drafts[0], "failed"),
            (drafts[1], "start"),
            (drafts[1], "saved")
        ]
    );
    assert_eq!(
        session.context(),
        [Block::user_text("go"), Block::assistant_text("done")]
    );
    assert_eq!(capture.positions(), [(3, 0, 0)]);
}

#[tokio::test]
async fn a_failed_stream_discards_visible_text_without_a_saved_answer() {
    let transport = ScriptedTransport::new([failed_reply("cut")]);
    let model = model();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    assert!(
        session
            .turn(Driver::new(&transport, &model, &NoWait))
            .observer(&capture)
            .run()
            .await
            .is_err()
    );
    let live = capture.live();
    assert!(live.iter().any(
        |update| matches!(update, LiveUpdate::Model { event: ModelUpdate::TextDelta { text, .. }, .. } if text == "cut")
    ));
    assert!(live.iter().any(|update| matches!(
        update,
        LiveUpdate::DraftDiscarded {
            reason: DraftDiscardReason::Failed,
            ..
        }
    )));
    assert_eq!(capture.positions(), []);
    assert_eq!(session.context(), [Block::user_text("go")]);
    assert!(!live.contains(&LiveUpdate::TurnUnconfirmed));
    let updates = capture.0.lock().unwrap();
    assert!(matches!(updates.last().map(|update| &update.update),
        Some(SessionUpdate::Saved(event)) if event.event_number == EventNumber(3)
            && matches!(&event.event, SessionEvent::Commit { commit, .. } if matches!(commit.end, Some(yuke_engine::TurnEnd::Failed(_))))));
}

/// A refused login. Its text names no cause, so only `source` gives the cause.
#[derive(Debug)]
struct Refused(std::io::Error);

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the login refresh failed")
    }
}

impl std::error::Error for Refused {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.0)
    }
}

/// A credential source that fails with an error that has a cause.
struct RefusedLogin;

#[async_trait]
impl CredentialSource for RefusedLogin {
    async fn credential(&self) -> Result<Credential, Box<dyn std::error::Error + Send + Sync>> {
        Err(Box::new(Refused(std::io::Error::other("the grant was revoked"))))
    }
}

#[tokio::test]
async fn a_round_failure_reaches_clients_with_each_cause() {
    let transport = ScriptedTransport::new([]);
    let model = Model {
        target: target(),
        source: Arc::new(RefusedLogin),
    };
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();

    let ran = session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&capture)
        .run()
        .await;

    assert!(ran.is_err(), "{ran:?}");
    let failures: Vec<LiveUpdate> = capture
        .live()
        .into_iter()
        .filter(|update| matches!(update, LiveUpdate::RoundFailed { .. }))
        .collect();
    assert_eq!(
        failures,
        [LiveUpdate::RoundFailed {
            error: "the login refresh failed: the grant was revoked".to_owned()
        }]
    );
}

#[tokio::test]
async fn an_unconfirmed_answer_save_discards_the_draft_and_starts_no_tool() {
    let store = FailingStore::new(StoreBehavior::FailCommit(2));
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "send", "{}")])]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), "the prompt").await.unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    assert!(
        session
            .turn(Driver::new(&transport, &model, &NoWait))
            .observer(&capture)
            .run()
            .await
            .is_err()
    );
    assert!(matches!(
        capture.live().iter().rev().nth(1),
        Some(LiveUpdate::DraftDiscarded {
            reason: DraftDiscardReason::Unconfirmed,
            ..
        })
    ));
    assert_eq!(capture.positions(), []);
    assert_eq!(
        capture
            .live()
            .iter()
            .filter(|update| matches!(update, LiveUpdate::ToolStarted { .. }))
            .count(),
        0
    );
    assert_eq!(
        store
            .load(session.id(), None)
            .await
            .map(|loaded| loaded.events)
            .unwrap()
            .len(),
        2
    );
}

#[tokio::test]
async fn a_failed_load_of_the_pending_inputs_starts_no_turn_and_sends_no_update() {
    let store = FailingStore::new(StoreBehavior::FailPending);
    let transport = ScriptedTransport::new([]);
    let model = model();
    let mut session = Session::create(store, &settings(), "the prompt").await.unwrap();
    let capture = Capture::default();

    let failed = session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&capture)
        .run()
        .await;

    assert!(failed.is_err(), "{failed:?}");
    assert!(capture.0.lock().unwrap().is_empty());
    assert_eq!(transport.requests(), Vec::<String>::new());
}

#[tokio::test]
async fn a_dropped_turn_discards_its_draft() {
    let model = model();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    {
        let mut future = pin!(
            session
                .turn(Driver::new(&Stalled, &model, &NoWait))
                .observer(&capture)
                .run()
        );
        assert!(
            future
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop()))
                .is_pending()
        );
    }
    let drafts = capture.drafts();
    assert_eq!(drafts.len(), 1);
    assert_eq!(
        capture.live(),
        [
            LiveUpdate::DraftStarted { draft_id: drafts[0] },
            LiveUpdate::DraftDiscarded {
                draft_id: drafts[0],
                reason: DraftDiscardReason::Unconfirmed
            },
            LiveUpdate::TurnUnconfirmed,
        ]
    );
}

#[tokio::test]
async fn cancelled_text_reconciles_to_the_terminal_commit() {
    let transport = ScriptedTransport::new([text_reply("partial")]);
    let model = model();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    let cancellation = CancellationToken::new();
    let observer = |update: SessionUpdateParams| {
        if matches!(
            &update.update,
            SessionUpdate::Live(LiveUpdate::Model {
                event: ModelUpdate::TextDelta { .. },
                ..
            })
        ) {
            cancellation.cancel();
        }
        capture.update(update);
    };
    let outcome = session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&observer)
        .cancellation_token(cancellation.clone())
        .run()
        .await
        .unwrap();
    assert_eq!(outcome, yuke_engine::Outcome::Cancelled);
    assert_eq!(capture.positions(), [(3, 0, 0)]);
    assert_eq!(
        session.context(),
        [Block::user_text("go"), Block::assistant_text("partial")]
    );
    assert!(matches!(capture.live().last(), Some(LiveUpdate::DraftCommitted { .. })));
}

#[tokio::test]
async fn parallel_results_keep_call_positions_when_completion_order_differs() {
    let transport = ScriptedTransport::new([
        sse(&[
            r#"{"choices":[{"index":0,"delta":{"content":"Check"}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"same","function":{"name":"send","arguments":"{\"wait\":true}"}},{"index":1,"id":"same","function":{"name":"send","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ]),
        sse(&[
            r#"{"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ]),
    ]);
    let model = model_of(yuke_ai::Target {
        wire: Wire::OpenaiChat(yuke_ai::ChatWire::default()),
        ..target()
    });
    let tools = tools();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait).toolset(&tools))
        .observer(&capture)
        .run()
        .await
        .unwrap();
    let finished: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::ToolFinished { execution, result } => {
                Some((execution.event_number.0, execution.block_index, result.content))
            }
            _ => None,
        })
        .collect();
    assert_eq!(finished, [(3, 2, "{}".into()), (3, 1, r#"{"wait":true}"#.into())]);
    let output: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::ToolOutput { execution, text } => Some((execution.block_index, text)),
            _ => None,
        })
        .collect();
    assert_eq!(output, [(2, "{}".into()), (1, r#"{"wait":true}"#.into())]);
    let saved_results: Vec<_> = session
        .context()
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) => Some(result.content.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(saved_results, [r#"{"wait":true}"#, "{}"]);
    assert_eq!(capture.positions(), [(3, 0, 0), (3, 1, 1), (3, 2, 2), (5, 0, 0)]);
}

#[tokio::test]
async fn reasoning_sections_reach_clients_without_provider_replay_state() {
    let transport = ScriptedTransport::new([sse(&[
        r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}"#,
        r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"One"}"#,
        r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":1,"delta":"Two"}"#,
        r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"private-replay"}}"#,
        r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
    ])]);
    let model = model_of(yuke_ai::Target {
        wire: Wire::OpenaiResponses(yuke_ai::ResponsesWire::default()),
        ..target()
    });
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait))
        .observer(&capture)
        .run()
        .await
        .unwrap();
    let model: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::Model { event, .. } => Some(event),
            _ => None,
        })
        .collect();
    assert_eq!(
        &model[..7],
        [
            ModelUpdate::BlockStarted {
                block: 0,
                block_kind: yuke_ai::BlockKind::Reasoning
            },
            ModelUpdate::ReasoningSectionStarted { block: 0 },
            ModelUpdate::ReasoningDelta {
                block: 0,
                text: "One".into()
            },
            ModelUpdate::ReasoningDelta {
                block: 0,
                text: "\n\n".into()
            },
            ModelUpdate::ReasoningSectionStarted { block: 0 },
            ModelUpdate::ReasoningDelta {
                block: 0,
                text: "Two".into()
            },
            ModelUpdate::BlockStopped { block: 0, call: None },
        ]
    );
    let Block::Reasoning(reasoning) = &session.context()[1] else {
        panic!("expected saved reasoning")
    };
    assert_eq!(reasoning.text, "One\n\nTwo");
    assert!(reasoning.replay.is_some());
    assert_eq!(capture.positions(), [(3, 0, 0)]);
}

#[tokio::test]
async fn cancellation_omits_reasoning_but_retains_complete_calls_and_open_text() {
    let transport = ScriptedTransport::new([sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"private"}}"#,
        r#"{"type":"content_block_stop","index":0}"#,
        r#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c1","name":"send","input":{}}}"#,
        r#"{"type":"content_block_stop","index":1}"#,
        r#"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":"partial"}}"#,
    ])]);
    let model = model();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    let cancellation = CancellationToken::new();
    let observer = |update: SessionUpdateParams| {
        if matches!(
            &update.update,
            SessionUpdate::Live(LiveUpdate::Model {
                event: ModelUpdate::TextDelta { .. },
                ..
            })
        ) {
            cancellation.cancel();
        }
        capture.update(update);
    };
    assert_eq!(
        session
            .turn(Driver::new(&transport, &model, &NoWait))
            .observer(&observer)
            .cancellation_token(cancellation.clone())
            .run()
            .await
            .unwrap(),
        yuke_engine::Outcome::Cancelled
    );
    assert_eq!(capture.positions(), [(3, 1, 0), (3, 2, 1)]);
    assert_eq!(session.context().len(), 4);
    assert!(matches!(&session.context()[1], Block::ToolCall(call) if call.call_id == "c1"));
    assert_eq!(session.context()[2], Block::assistant_text("partial"));
    assert!(matches!(&session.context()[3], Block::ToolResult(result) if result.call_id == "c1" && result.is_error));
}

#[tokio::test]
async fn an_uncertain_write_needs_journal_reload_not_a_predicted_receipt() {
    let store = FailingStore::new(StoreBehavior::FailAfterCommit(2));
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "send", "{}")])]);
    let model = model();
    let mut session = Session::create(store.clone(), &settings(), "the prompt").await.unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    assert!(
        session
            .turn(Driver::new(&transport, &model, &NoWait))
            .observer(&capture)
            .run()
            .await
            .is_err()
    );
    assert!(matches!(
        capture.live().iter().rev().nth(1),
        Some(LiveUpdate::DraftDiscarded {
            reason: DraftDiscardReason::Unconfirmed,
            ..
        })
    ));
    assert_eq!(capture.positions(), []);
    let published: Vec<_> = capture
        .0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|update| match &update.update {
            SessionUpdate::Saved(event) => Some(event.event_number.0),
            SessionUpdate::Live(_) => None,
        })
        .collect();
    assert_eq!(published, [2]);
    let id = session.id();
    drop(session);
    let repaired = Session::open(store.clone(), id).await.unwrap();
    let events = store.load(id, None).await.map(|loaded| loaded.events).unwrap();
    assert_eq!(
        events.iter().map(|event| event.event_number.0).collect::<Vec<_>>(),
        [1, 2, 3, 4]
    );
    let SessionEvent::Commit { commit, .. } = &events[2].event else {
        panic!("expected a saved answer")
    };
    assert!(matches!(&commit.blocks[0], Block::ToolCall(call) if call.call_id == "c1"));
    assert!(matches!(repaired.context().last(), Some(Block::ToolResult(result)) if result.is_error));
}

#[tokio::test]
async fn tool_argument_fragments_and_authoritative_arguments_both_reach_clients() {
    let transport = ScriptedTransport::new([
        sse(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c1","name":"send"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"old\":"}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"true}"}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"final\":true}"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ]),
        sse(&[r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#]),
    ]);
    let model = model_of(yuke_ai::Target {
        wire: Wire::OpenaiResponses(yuke_ai::ResponsesWire::default()),
        ..target()
    });
    let tools = tools();
    let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
        .await
        .unwrap();
    session.input().send(user_input("go")).await.unwrap();
    let capture = Capture::default();
    session
        .turn(Driver::new(&transport, &model, &NoWait).toolset(&tools))
        .observer(&capture)
        .run()
        .await
        .unwrap();
    let facts: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::Model {
                event: ModelUpdate::ToolInputDelta { block, text },
                ..
            } => Some(("fragment", block, text)),
            LiveUpdate::Model {
                event:
                    ModelUpdate::BlockStopped {
                        block,
                        call: Some(call),
                    },
                ..
            } => Some(("final", block, call.arguments)),
            _ => None,
        })
        .collect();
    assert_eq!(
        facts,
        [
            ("fragment", 0, r#"{"old":"#.into()),
            ("fragment", 0, "true}".into()),
            ("final", 0, r#"{"final":true}"#.into())
        ]
    );
    let outputs: Vec<_> = capture
        .live()
        .into_iter()
        .filter_map(|update| match update {
            LiveUpdate::ToolOutput { execution, text } => Some((execution.event_number.0, execution.block_index, text)),
            _ => None,
        })
        .collect();
    assert_eq!(outputs, [(3, 0, r#"{"final":true}"#.into())]);
}

#[tokio::test]
async fn cancellation_before_or_after_completion_omits_empty_blocks_from_saved_positions() {
    for cancel_at in ["text", "completion"] {
        let transport = ScriptedTransport::new([sse(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"kept"}}"#,
            r#"{"type":"content_block_stop","index":1}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
            r#"{"type":"message_stop"}"#,
        ])]);
        let model = model();
        let mut session = Session::create(Arc::new(MemoryStore::new()), &settings(), "the prompt")
            .await
            .unwrap();
        session.input().send(user_input("go")).await.unwrap();
        let capture = Capture::default();
        let cancellation = CancellationToken::new();
        let observer = |update: SessionUpdateParams| {
            match &update.update {
                SessionUpdate::Live(LiveUpdate::Model {
                    event: ModelUpdate::TextDelta { .. },
                    ..
                }) if cancel_at == "text" => cancellation.cancel(),
                SessionUpdate::Live(LiveUpdate::Model {
                    event: ModelUpdate::ResponseCompleted { .. },
                    ..
                }) if cancel_at == "completion" => cancellation.cancel(),
                _ => {}
            }
            capture.update(update);
        };
        assert_eq!(
            session
                .turn(Driver::new(&transport, &model, &NoWait))
                .observer(&observer)
                .cancellation_token(cancellation.clone())
                .run()
                .await
                .unwrap(),
            yuke_engine::Outcome::Cancelled
        );
        assert_eq!(
            session.context(),
            [Block::user_text("go"), Block::assistant_text("kept")]
        );
        assert_eq!(capture.positions(), [(3, 1, 0)]);
        let updates = capture.0.lock().unwrap();
        assert!(
            matches!(&updates[updates.len() - 2].update, SessionUpdate::Saved(event) if event.event_number == EventNumber(3))
        );
        assert!(matches!(
            &updates[updates.len() - 1].update,
            SessionUpdate::Live(LiveUpdate::DraftCommitted { .. })
        ));
    }
}

#[tokio::test]
async fn result_and_terminal_write_failures_invalidate_provisional_tool_state() {
    for (behavior, published, unknown) in [
        (StoreBehavior::FailCommit(3), vec![2, 3], true),
        (StoreBehavior::FailAfterCommit(3), vec![2, 3], false),
        (StoreBehavior::FailCommit(5), vec![2, 3, 4, 5], false),
    ] {
        let store = FailingStore::new(behavior);
        let transport = ScriptedTransport::new([tool_reply(&[("c1", "send", "{}")]), text_reply("done")]);
        let model = model();
        let tools = tools();
        let mut session = Session::create(store.clone(), &settings(), "the prompt").await.unwrap();
        session.input().send(user_input("go")).await.unwrap();
        let capture = Capture::default();
        assert!(
            session
                .turn(Driver::new(&transport, &model, &NoWait).toolset(&tools))
                .observer(&capture)
                .run()
                .await
                .is_err()
        );
        let live = capture.live();
        let finished: Vec<_> = live
            .iter()
            .filter_map(|event| match event {
                LiveUpdate::ToolFinished { execution, result } => {
                    Some((execution.event_number.0, execution.block_index, result.content.as_str()))
                }
                _ => None,
            })
            .collect();
        assert_eq!(finished, [(3, 0, "{}")]);
        assert_eq!(live.last(), Some(&LiveUpdate::TurnUnconfirmed));
        let saved: Vec<_> = capture
            .0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|update| match &update.update {
                SessionUpdate::Saved(event) => Some(event.event_number.0),
                SessionUpdate::Live(_) => None,
            })
            .collect();
        assert_eq!(saved, published);
        let id = session.id();
        drop(session);
        let repaired = Session::open(store, id).await.unwrap();
        let results: Vec<_> = repaired
            .context()
            .iter()
            .filter_map(|block| match block {
                Block::ToolResult(result) => Some(result),
                _ => None,
            })
            .collect();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].is_error, unknown);
        if unknown {
            assert!(results[0].content.contains("The call can have run."));
        } else {
            assert_eq!(results[0].content, "{}");
        }
    }
}

#[tokio::test]
async fn a_dropped_result_or_terminal_save_reports_an_unconfirmed_turn() {
    for (stall_at, saved_positions) in [(3, vec![(3, 0, 0)]), (5, vec![(3, 0, 0), (5, 0, 0)])] {
        let store = FailingStore::new(StoreBehavior::StallCommit(stall_at));
        let transport = ScriptedTransport::new([tool_reply(&[("c1", "send", "{}")]), text_reply("done")]);
        let model = model();
        let tools = tools();
        let mut session = Session::create(store, &settings(), "the prompt").await.unwrap();
        session.input().send(user_input("go")).await.unwrap();
        let capture = Capture::default();
        {
            let mut future = pin!(
                session
                    .turn(Driver::new(&transport, &model, &NoWait).toolset(&tools))
                    .observer(&capture)
                    .run()
            );
            assert!(
                future
                    .as_mut()
                    .poll(&mut Context::from_waker(Waker::noop()))
                    .is_pending()
            );
            assert!(capture.live().iter().any(|event| matches!(event,
                LiveUpdate::ToolFinished { execution, result } if execution.event_number == EventNumber(3) && result.content == "{}")));
            assert!(!capture.live().contains(&LiveUpdate::TurnUnconfirmed));
        }
        assert_eq!(capture.live().last(), Some(&LiveUpdate::TurnUnconfirmed));
        assert_eq!(capture.positions(), saved_positions);
    }
}
