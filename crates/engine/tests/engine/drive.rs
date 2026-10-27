use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::scripted::{ScriptedTransport, cut_reply, failed_reply, overloaded_reply, text_reply, tool_reply};
use yuke_ai::{Block, FinishReason, ToolCall, ToolResult};
use yuke_engine::NoWait;
use yuke_engine::{
    CancellationToken, Driver, Outcome, RoundDecision, RoundError, Tool, ToolContent, ToolContext, Toolset, TurnError,
    TurnEvent,
};
use yuke_testing::{assert_in_order, definition, model};

use crate::support::{
    Batches, CancelOnSleep, Fixed, Labels, Queue, Recorder, Script, Waits, block_on, label, yield_once,
};

#[test]
fn driver_sends_the_context_and_keeps_each_answer() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let model = model();
    let driver = Driver::new(&transport, &model, &NoWait);
    let mut context = Vec::new();

    let first = block_on(driver.turn(&mut context, vec![Block::user_text("one")]).run());
    let second = block_on(driver.turn(&mut context, vec![Block::user_text("two")]).run());

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
    assert_eq!(context.last(), Some(&Block::assistant_text("second answer")));
}

#[test]
fn driver_runs_each_call_in_order_and_sends_the_results() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", r#"{"text":"a"}"#), ("c2", "echo", r#"{"text":"b"}"#)]),
        text_reply("done"),
    ]);
    let model = model();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

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
fn unknown_tool_returns_an_error_result_and_runs_nothing() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "missing", "{}")]), text_reply("done")]);
    let model = model();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

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

#[test]
fn tool_error_reaches_the_model_and_the_turn_continues() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "write", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset
        .add(definition("write"), Fixed(Err("disk full".to_owned())))
        .unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

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

#[test]
fn observer_receives_every_event_of_each_round_in_source_order() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", "{}"), ("c2", "echo", "{}")]),
        text_reply("done"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();
    let labels = Labels::default();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&labels)
            .run(),
    );

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(
        labels.labels(),
        [
            "response started",
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
            "response started",
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
    let model = model();
    let driver = Driver::new(&transport, &model, &NoWait);
    let mut context = Vec::new();
    let labels = Labels::default();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&labels)
            .run(),
    );

    assert_eq!(
        labels.labels(),
        [
            "response started",
            "start 0 Text",
            "text cut",
            "response failed",
            "round failed"
        ]
    );
    let Err(TurnError::Round(RoundError::Model(yuke_ai::Error::Attempt(error)))) = outcome else {
        panic!("expected a failed attempt, got {outcome:?}");
    };
    assert_eq!(error.partial, [yuke_ai::Partial::Text("cut".to_owned())]);
    assert_eq!(context, [Block::user_text("go")]);
}

#[test]
fn retry_sends_the_same_request_bytes_and_the_observer_sees_the_wait() {
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("done")]);
    let model = model();
    let waits = Waits::default();
    let driver = Driver::new(&transport, &model, &waits);
    let mut context = Vec::new();
    let retries = Mutex::new(Vec::new());
    let causes = Mutex::new(Vec::new());

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::RetryScheduled { after, error } = event {
                    retries.lock().unwrap().push(*after);
                    causes.lock().unwrap().push(error.cause);
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
    let retries = retries.into_inner().unwrap();
    assert_eq!(waits.waits(), retries);
    assert_eq!(
        *causes.lock().unwrap(),
        [yuke_ai::Failure::Provider(yuke_ai::ProviderKind::ServerError)]
    );
    // The first backoff keeps 75% to 100% of 500 ms.
    assert_eq!(retries.len(), 1);
    assert!((Duration::from_millis(375)..=Duration::from_millis(500)).contains(&retries[0]));
}

#[test]
fn a_new_driver_sends_each_request_with_the_default_retry_policy() {
    let attempts = yuke_ai::retry::Policy::default().max_attempts.get();
    let transport = ScriptedTransport::new((0..attempts).map(|_| overloaded_reply()));
    let model = model();
    let waits = Waits::default();
    let driver = Driver::new(&transport, &model, &waits);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(outcome.is_err());
    assert_eq!(transport.requests().len(), usize::try_from(attempts).unwrap());
}

#[test]
fn the_retry_policy_of_the_driver_bounds_the_attempts_and_the_wait() {
    let transport = ScriptedTransport::new([0; 5].map(|_| overloaded_reply()));
    let model = model();
    let waits = Waits::default();
    let retry_policy = yuke_ai::retry::Policy {
        max_attempts: std::num::NonZeroU32::new(2).unwrap(),
        base: Duration::from_secs(2),
        cap: Duration::from_secs(2),
        ..yuke_ai::retry::Policy::default()
    };
    let driver = Driver::new(&transport, &model, &waits).retry_policy(retry_policy);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(outcome.is_err());
    assert_eq!(transport.requests().len(), 2);
    let waits = waits.waits();
    assert_eq!(waits.len(), 1);
    // The first backoff keeps 75% to 100% of 2 s.
    assert!((Duration::from_millis(1_500)..=Duration::from_millis(2_000)).contains(&waits[0]));
}

#[test]
fn the_response_limits_of_the_driver_bound_each_response() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let response_limits = yuke_ai::ResponseLimits {
        max_blocks: 0,
        ..yuke_ai::ResponseLimits::default()
    };
    let driver = Driver::new(&transport, &model, &NoWait).response_limits(response_limits);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    let Err(TurnError::Round(RoundError::Model(yuke_ai::Error::Attempt(error)))) = outcome else {
        panic!("expected a failed attempt, got {outcome:?}");
    };
    assert_eq!(error.cause, yuke_ai::Failure::ResponseTooLarge);
    assert_eq!(transport.requests().len(), 1);
}

#[test]
fn input_taken_between_rounds_follows_the_tool_results_and_a_retry_keeps_its_bytes() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", "{}")]),
        overloaded_reply(),
        text_reply("done"),
        text_reply("late answer"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Batches::new([vec![Block::user_text("steer")], vec![Block::user_text("late")]]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    );

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
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Queue::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    );

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
    assert_eq!(inbox.held(), Vec::<Block>::new());
}

#[test]
fn input_follows_the_error_results_of_a_cut_answer() {
    let transport = ScriptedTransport::new([
        cut_reply(&[("c1", "write", "{}"), ("c2", "write", "{}")]),
        text_reply("done"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    let write = Recorder::default();
    toolset.add(definition("write"), write.clone()).unwrap();
    let inbox = Queue::new(vec![Block::user_text("steer")]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    );

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

#[test]
fn blocked_call_runs_no_tool_and_its_reason_reaches_the_model() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "write", "{}"), ("c2", "echo", "{}")]),
        text_reply("done"),
    ]);
    let model = model();
    let write = Recorder::default();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("write"), write.clone()).unwrap();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let hooks = Script::default().blocks("write");
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

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

#[test]
fn stop_after_a_round_ends_the_turn_with_its_tool_results_and_leaves_the_input() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")])]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = Script::default().decisions([RoundDecision::Stop]);
    let inbox = Queue::new(vec![Block::user_text("steer")]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Stopped)));
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(
        context.last(),
        Some(&Block::ToolResult(ToolResult::success("c1", "result 1")))
    );
    assert_eq!(inbox.held(), [Block::user_text("steer")]);
}

#[test]
fn stop_after_a_cut_answer_ends_the_turn_as_stopped() {
    let cut = || cut_reply(&[("c1", "write", "{}")]);
    let transport = ScriptedTransport::new([cut(), cut()]);
    let model = model();
    let hooks = Script::default().decisions([RoundDecision::Proceed, RoundDecision::Stop]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Stopped)));
    assert_eq!(transport.requests().len(), 2);
}

#[test]
fn cancel_during_the_retry_wait_sends_no_other_attempt() {
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("unused")]);
    let model = model();
    let cancellation_token = CancellationToken::new();
    let timer = CancelOnSleep(cancellation_token.clone());
    let driver = Driver::new(&transport, &model, &timer);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(context, [Block::user_text("go")]);
}

/// A tool that cancels the turn during its call, waits once as a process kill does, and returns its own result.
struct CancelDuringCall(CancellationToken);

#[async_trait]
impl Tool for CancelDuringCall {
    async fn call(&self, _: &str, context: &ToolContext<'_>) -> Result<ToolContent, String> {
        self.0.cancel();
        assert!(context.cancellation_token().is_cancelled());
        yield_once().await;
        Err("step 1 done\nCommand aborted".to_owned())
    }
}

#[test]
fn cancel_during_a_tool_keeps_its_own_result_and_runs_no_later_call() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "build", "{}"), ("c2", "echo", "{}")])]);
    let model = model();
    let cancellation_token = CancellationToken::new();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset
        .add(definition("build"), CancelDuringCall(cancellation_token.clone()))
        .unwrap();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let inbox = Queue::new(vec![Block::user_text("steer")]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(echo.calls(), Vec::<String>::new());
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(
        context,
        [
            Block::user_text("go"),
            Block::ToolCall(ToolCall {
                call_id: "c1".to_owned(),
                name: "build".to_owned(),
                arguments: "{}".to_owned()
            }),
            Block::ToolCall(ToolCall {
                call_id: "c2".to_owned(),
                name: "echo".to_owned(),
                arguments: "{}".to_owned()
            }),
            Block::ToolResult(ToolResult::error("c1", "step 1 done\nCommand aborted")),
            Block::ToolResult(ToolResult::error(
                "c2",
                "Tool call \"echo\" was not executed: the user cancelled the turn."
            )),
        ]
    );
    assert_eq!(inbox.held(), [Block::user_text("steer")]);
}

#[test]
fn cancel_during_the_stream_keeps_the_partial_text_without_reasoning_and_delivers_every_event() {
    let partial = [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"private"}}"#,
        r#"{"type":"content_block_stop","index":0}"#,
        r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"cut"}}"#,
    ]
    .map(|json| format!("data: {json}\n\n"))
    .concat();
    let transport = ScriptedTransport::new([]).then_stall(partial);
    let model = model();
    let driver = Driver::new(&transport, &model, &NoWait);
    let mut context = Vec::new();
    let cancellation_token = CancellationToken::new();
    let seen = Mutex::new(Vec::new());

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                seen.lock().unwrap().push(label(event));
                if matches!(event, TurnEvent::Model(yuke_ai::Event::TextDelta(_))) {
                    cancellation_token.cancel();
                }
            })
            .cancellation_token(cancellation_token.clone())
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(
        *seen.lock().unwrap(),
        [
            "response started",
            "start 0 Reasoning",
            "reasoning private",
            "stop 0",
            "start 1 Text",
            "text cut",
            "response cancelled 1"
        ]
    );
    assert_eq!(context, [Block::user_text("go"), Block::assistant_text("cut")]);
}

#[test]
fn cancel_while_the_after_round_hook_waits_keeps_the_answer_and_the_input() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let cancellation_token = CancellationToken::new();
    let hooks = Script::default().cancel_at("after_round", cancellation_token.clone());
    let inbox = Queue::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(context, [Block::user_text("go"), Block::assistant_text("done")]);
    assert_eq!(inbox.held(), [Block::user_text("later")]);
}
