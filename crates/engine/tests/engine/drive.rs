use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason, ToolCall, ToolResult};
use yuke_engine::{
    CancellationToken, Conversation, Driver, DuplicateToolName, Hooks, Outcome, RoundDecision, Tool, ToolContent,
    ToolContext, ToolDecision, Toolset, TurnEvent,
};

use crate::support::{
    Batches, CancelOnSleep, NoWait, Recorder, ScriptedTransport, Waits, assert_in_order, block_on, cut_reply,
    definition, failed_reply, overloaded_reply, target, text_reply, tool_reply, yield_once,
};

#[test]
fn driver_sends_the_history_and_keeps_each_answer() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let target = target();
    let driver = Driver::new(&transport, &target, &NoWait);
    let mut conversation = Conversation::new();

    let first = block_on(driver.turn(&mut conversation, vec![Block::user_text("one")]).run());
    let second = block_on(driver.turn(&mut conversation, vec![Block::user_text("two")]).run());

    for outcome in [first, second] {
        assert!(matches!(
            outcome,
            Ok(Outcome::Completed {
                finish_reason: FinishReason::Stop
            })
        ));
    }
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_in_order(&requests[1], &["one", "first answer", "two"]);
    assert_eq!(
        conversation.history().last(),
        Some(&Block::assistant_text("second answer"))
    );
}

#[test]
fn driver_runs_each_call_in_order_and_sends_the_results() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", r#"{"text":"a"}"#), ("c2", "echo", r#"{"text":"b"}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(echo.calls(), [r#"{"text":"a"}"#, r#"{"text":"b"}"#]);
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_in_order(&requests[0], &["echo", "A test tool.", "go"]);
    assert_in_order(&requests[1], &["c1", "c2", "result 1", "result 2"]);
}

#[test]
fn a_second_tool_of_a_taken_name_is_refused_and_the_first_tool_runs() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let target = target();
    let first = Recorder::default();
    let second = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), first.clone()).unwrap();

    let refused = toolset.add(definition("echo"), second.clone());

    assert_eq!(
        refused,
        Err(DuplicateToolName {
            name: "echo".to_owned()
        })
    );
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let mut conversation = Conversation::new();
    block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run()).unwrap();
    assert_eq!(first.calls(), ["{}"]);
    assert_eq!(second.calls(), Vec::<String>::new());
    assert_eq!(transport.requests()[0].matches(r#""name":"echo""#).count(), 1);
}

#[test]
fn unknown_tool_returns_an_error_result_and_runs_nothing() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "missing", "{}")]), text_reply("done")]);
    let target = target();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(echo.calls(), Vec::<String>::new());
    let requests = transport.requests();
    assert_in_order(&requests[1], &["c1", "Unknown tool: missing"]);
    assert!(requests[1].contains(r#""is_error":true"#), "{}", requests[1]);
}

/// A tool whose every call fails.
struct Fails;

#[async_trait]
impl Tool for Fails {
    async fn call(&self, _: &str, _: &mut ToolContext<'_>) -> Result<ToolContent, String> {
        Err("disk full".to_owned())
    }
}

#[test]
fn tool_error_reaches_the_model_and_the_turn_continues() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "write", "{}")]), text_reply("done")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("write"), Fails).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    let requests = transport.requests();
    assert_in_order(&requests[1], &["c1", "disk full"]);
    assert!(requests[1].contains(r#""is_error":true"#), "{}", requests[1]);
}

/// A short label for `event`, so a test can compare whole event lists.
fn label(event: &TurnEvent<'_>) -> String {
    match event {
        TurnEvent::Model(yuke_ai::Event::BlockStarted(started)) => {
            format!("start {} {:?}", started.block, started.kind)
        }
        TurnEvent::Model(yuke_ai::Event::TextDelta(delta)) => format!("text {}", delta.text),
        TurnEvent::Model(yuke_ai::Event::ToolInputDelta(delta)) => format!("arguments {} {}", delta.block, delta.text),
        TurnEvent::Model(yuke_ai::Event::BlockStopped(stopped)) => format!("stop {}", stopped.block),
        TurnEvent::Model(yuke_ai::Event::Done(done)) => format!("done {:?}", done.finish_reason),
        TurnEvent::ToolStarted(call) => format!("tool {}", call.call_id),
        TurnEvent::ToolFinished(result) => format!("result {} {}", result.call_id, result.content),
        TurnEvent::RoundFailed(_) => "round failed".to_owned(),
        other => format!("other {other:?}"),
    }
}

#[test]
fn observer_receives_every_event_of_each_round_in_source_order() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", "{}"), ("c2", "echo", "{}")]),
        text_reply("done"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let mut conversation = Conversation::new();
    let mut seen = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .observer(&mut |event: &TurnEvent<'_>| {
                seen.push(label(event));
            })
            .run(),
    );

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(
        seen,
        [
            "start 0 ToolCall",
            "arguments 0 {}",
            "stop 0",
            "start 1 ToolCall",
            "arguments 1 {}",
            "stop 1",
            "done ToolCalls",
            "tool c1",
            "result c1 result 1",
            "tool c2",
            "result c2 result 2",
            "start 0 Text",
            "text done",
            "stop 0",
            "done Stop",
        ]
    );
}

#[test]
fn failed_reply_delivers_its_events_then_fails_with_the_partial_output() {
    let transport = ScriptedTransport::new([failed_reply("cut")]);
    let target = target();
    let driver = Driver::new(&transport, &target, &NoWait);
    let mut conversation = Conversation::new();
    let mut seen = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .observer(&mut |event: &TurnEvent<'_>| {
                seen.push(label(event));
            })
            .run(),
    );

    assert_eq!(seen, ["start 0 Text", "text cut", "round failed"]);
    let Err(yuke_ai::Error::Attempt(error)) = outcome else {
        panic!("expected a failed attempt, got {outcome:?}");
    };
    assert_eq!(error.partial, [yuke_ai::Partial::Text("cut".to_owned())]);
    assert_eq!(conversation.history(), [Block::user_text("go")]);
}

#[test]
fn retry_sends_the_same_request_bytes_and_the_observer_sees_the_wait() {
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("done")]);
    let target = target();
    let waits = Waits::default();
    let driver = Driver::new(&transport, &target, &waits);
    let mut conversation = Conversation::new();
    let mut retries = Vec::new();
    let mut causes = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .observer(&mut |event: &TurnEvent<'_>| {
                if let TurnEvent::RetryScheduled { after, error } = event {
                    retries.push(*after);
                    causes.push(error.cause);
                }
            })
            .run(),
    );

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0], requests[1]);
    assert_eq!(waits.waits(), retries);
    assert_eq!(causes, [yuke_ai::Failure::Provider(yuke_ai::ProviderKind::ServerError)]);
    // The first backoff keeps 75% to 100% of 500 ms.
    assert_eq!(retries.len(), 1);
    assert!((Duration::from_millis(375)..=Duration::from_millis(500)).contains(&retries[0]));
}

#[test]
fn no_retry_after_output_reached_the_observer() {
    let transport = ScriptedTransport::new([failed_reply("cut")]);
    let target = target();
    let waits = Waits::default();
    let driver = Driver::new(&transport, &target, &waits);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(outcome.is_err());
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(waits.waits(), Vec::<Duration>::new());
}

#[test]
fn request_stops_after_five_attempts() {
    let transport = ScriptedTransport::new([0; 5].map(|_| overloaded_reply()));
    let target = target();
    let waits = Waits::default();
    let driver = Driver::new(&transport, &target, &waits);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(outcome.is_err());
    assert_eq!(transport.requests().len(), 5);
    assert_eq!(waits.waits().len(), 4);
}

#[test]
fn input_taken_between_rounds_follows_the_tool_results_and_a_retry_keeps_its_bytes() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", "{}")]),
        overloaded_reply(),
        text_reply("done"),
        text_reply("late answer"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Batches::new([vec![Block::user_text("steer")], vec![Block::user_text("late")]]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    let requests = transport.requests();
    assert_eq!(requests.len(), 4);
    assert_in_order(&requests[1], &["go", "c1", "result 1", "steer"]);
    assert_eq!(requests[1], requests[2]);
    assert!(!requests[2].contains(r#""late""#), "{}", requests[2]);
    assert_in_order(&requests[3], &["steer", "done", "late"]);
}

#[test]
fn input_during_the_final_answer_continues_the_turn_until_its_next_final_answer() {
    let transport = ScriptedTransport::new([
        text_reply("first answer"),
        tool_reply(&[("c1", "echo", "{}")]),
        text_reply("second answer"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert!(!requests[0].contains("later"), "{}", requests[0]);
    assert_in_order(&requests[1], &["go", "first answer", "later"]);
    assert_in_order(&requests[2], &["later", "c1", "result 1"]);
    assert_eq!(*inbox.lock().unwrap(), Vec::<Block>::new());
}

#[test]
fn input_follows_the_error_results_of_a_cut_answer() {
    let transport = ScriptedTransport::new([
        cut_reply(&[("c1", "write", "{}"), ("c2", "write", "{}")]),
        text_reply("done"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    let write = Recorder::default();
    toolset.add(definition("write"), write.clone()).unwrap();
    let inbox = Mutex::new(vec![Block::user_text("steer")]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(write.calls(), Vec::<String>::new());
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].matches("was not executed").count(), 2, "{}", requests[1]);
    assert_in_order(&requests[1], &["c1", "c2", "steer"]);
    assert!(
        requests[1].rfind("was not executed") < requests[1].find(r#""steer""#),
        "{}",
        requests[1]
    );
}

/// Hooks that block each call of the tool `write`.
struct BlockWrite;

#[async_trait]
impl Hooks for BlockWrite {
    async fn before_tool(&self, call: &ToolCall) -> ToolDecision {
        if call.name == "write" {
            ToolDecision::Block("The user blocked this call.".to_owned())
        } else {
            ToolDecision::Run
        }
    }
}

#[test]
fn blocked_call_runs_no_tool_and_its_reason_reaches_the_model() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "write", "{}"), ("c2", "echo", "{}")]),
        text_reply("done"),
    ]);
    let target = target();
    let write = Recorder::default();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("write"), write.clone()).unwrap();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&BlockWrite);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(write.calls(), Vec::<String>::new());
    assert_eq!(echo.calls(), ["{}"]);
    let requests = transport.requests();
    assert_in_order(&requests[1], &["c1", "c2", "The user blocked this call.", "result 1"]);
    assert_eq!(requests[1].matches(r#""is_error":true"#).count(), 1, "{}", requests[1]);
}

/// Hooks that stop the turn after `limit` rounds.
struct RoundLimit {
    limit: usize,
    rounds: AtomicUsize,
}

impl RoundLimit {
    fn new(limit: usize) -> Self {
        RoundLimit {
            limit,
            rounds: AtomicUsize::new(0),
        }
    }
}

#[async_trait]
impl Hooks for RoundLimit {
    async fn after_round(&self, _: &[Block]) -> RoundDecision {
        if self.rounds.fetch_add(1, Ordering::Relaxed) + 1 >= self.limit {
            RoundDecision::Stop
        } else {
            RoundDecision::Proceed
        }
    }
}

#[test]
fn stop_after_a_round_ends_the_turn_with_its_tool_results_and_leaves_the_input() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")])]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = RoundLimit::new(1);
    let inbox = Mutex::new(vec![Block::user_text("steer")]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks)
        .inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Stopped)));
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(
        conversation.history().last(),
        Some(&Block::ToolResult(ToolResult::success("c1", "result 1")))
    );
    assert_eq!(*inbox.lock().unwrap(), [Block::user_text("steer")]);
}

#[test]
fn round_limit_stops_a_turn_of_cut_answers() {
    let cut = || cut_reply(&[("c1", "write", "{}")]);
    let transport = ScriptedTransport::new([cut(), cut()]);
    let target = target();
    let hooks = RoundLimit::new(2);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Stopped)));
    assert_eq!(transport.requests().len(), 2);
}

#[test]
fn cancel_during_the_retry_wait_sends_no_other_attempt() {
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("unused")]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let timer = CancelOnSleep(cancellation_token.clone());
    let driver = Driver::new(&transport, &target, &timer);
    let mut conversation = Conversation::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(conversation.history(), [Block::user_text("go")]);
}

/// A tool that cancels the turn during its call, waits once as a process kill does, and returns its own result.
struct CancelDuringCall(CancellationToken);

#[async_trait]
impl Tool for CancelDuringCall {
    async fn call(&self, _: &str, context: &mut ToolContext<'_>) -> Result<ToolContent, String> {
        self.0.cancel();
        assert!(context.cancellation_token().is_cancelled());
        yield_once().await;
        Err("step 1 done\nCommand aborted".to_owned())
    }
}

#[test]
fn cancel_during_a_tool_keeps_its_own_result_and_runs_no_later_call() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "build", "{}"), ("c2", "echo", "{}")])]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset
        .add(definition("build"), CancelDuringCall(cancellation_token.clone()))
        .unwrap();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let inbox = Mutex::new(vec![Block::user_text("steer")]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(echo.calls(), Vec::<String>::new());
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(
        conversation.history(),
        [
            Block::user_text("go"),
            Block::ToolCall(ToolCall::new("c1", "build", "{}")),
            Block::ToolCall(ToolCall::new("c2", "echo", "{}")),
            Block::ToolResult(ToolResult::error("c1", "step 1 done\nCommand aborted")),
            Block::ToolResult(ToolResult::error(
                "c2",
                "Tool call \"echo\" was not executed: the user cancelled the turn."
            )),
        ]
    );
    assert_eq!(*inbox.lock().unwrap(), [Block::user_text("steer")]);
}

#[test]
fn cancel_during_the_stream_keeps_the_partial_text_and_delivers_every_event() {
    let partial = [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"cut"}}"#,
    ]
    .map(|json| format!("data: {json}\n\n"))
    .concat();
    let transport = ScriptedTransport::new([]).then_stall(partial);
    let target = target();
    let driver = Driver::new(&transport, &target, &NoWait);
    let mut conversation = Conversation::new();
    let cancellation_token = CancellationToken::new();
    let mut seen = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .observer(&mut |event: &TurnEvent<'_>| {
                seen.push(label(event));
                if matches!(event, TurnEvent::Model(yuke_ai::Event::TextDelta(_))) {
                    cancellation_token.cancel();
                }
            })
            .cancellation_token(cancellation_token.clone())
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(seen, ["start 0 Text", "text cut"]);
    assert_eq!(
        conversation.history(),
        [Block::user_text("go"), Block::assistant_text("cut")]
    );
}

/// Hooks that cancel the turn after each round, then wait forever.
struct CancelAfterRound(CancellationToken);

#[async_trait]
impl Hooks for CancelAfterRound {
    async fn after_round(&self, _: &[Block]) -> RoundDecision {
        self.0.cancel();
        std::future::pending().await
    }
}

#[test]
fn cancel_while_the_after_round_hook_waits_keeps_the_answer_and_the_input() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let hooks = CancelAfterRound(cancellation_token.clone());
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks).inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(
        conversation.history(),
        [Block::user_text("go"), Block::assistant_text("done")]
    );
    assert_eq!(*inbox.lock().unwrap(), [Block::user_text("later")]);
}

#[test]
fn turn_with_a_cancelled_token_sends_no_request() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let target = target();
    let driver = Driver::new(&transport, &target, &NoWait);
    let mut conversation = Conversation::new();
    let cancellation_token = CancellationToken::new();
    cancellation_token.cancel();

    let outcome = block_on(
        driver
            .turn(&mut conversation, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(transport.requests(), Vec::<String>::new());
}
