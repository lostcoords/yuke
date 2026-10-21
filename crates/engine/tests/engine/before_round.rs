use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::{Block, Settings, Target};
use yuke_engine::{CancellationToken, Driver, Hooks, Outcome, Replaced, RoundPlan, Toolset, TurnEvent};
use yuke_testing::{NoWait, ScriptedTransport, failed_reply, model, model_of, target, text_reply, tool_reply};

use crate::support::{Recorder, Script, block_on, definition};

/// The test target under another model name.
fn other_target(model: &'static str) -> Target {
    Target {
        model: model.into(),
        ..target()
    }
}

/// Settings with the sampling temperature `value`.
fn temperature(value: f64) -> Settings {
    Settings::new().temperature(value)
}

#[test]
fn the_driver_system_prompt_and_settings_reach_each_request() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let settings = temperature(0.25);
    let driver = Driver::new(&transport, &model, &NoWait)
        .toolset(&toolset)
        .system("Be brief.")
        .settings(&settings);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    for request in &requests {
        assert!(request.contains("Be brief."), "{request}");
        assert!(request.contains(r#""temperature":0.25"#), "{request}");
    }
}

#[test]
fn a_plan_target_and_settings_apply_to_their_round_only() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = Script::default().plans([
        RoundPlan {
            model: Some(model_of(other_target("router-model"))),
            settings: Some(temperature(0.25)),
            ..RoundPlan::default()
        },
        RoundPlan::default(),
    ]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert!(requests[0].contains(r#""model":"router-model""#), "{}", requests[0]);
    assert!(requests[0].contains(r#""temperature":0.25"#), "{}", requests[0]);
    assert!(requests[1].contains(r#""model":"test-model""#), "{}", requests[1]);
    assert!(!requests[1].contains("temperature"), "{}", requests[1]);
}

#[test]
fn a_plan_replacement_replaces_the_context_and_stays() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = Script::default().plans([
        RoundPlan::default(),
        RoundPlan {
            replace: Some(Replaced {
                head: vec![Block::user_text("Summary of the work so far.")].into(),
                keep: 0,
            }),
            ..RoundPlan::default()
        },
    ]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
    let mut context = Vec::new();

    block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert!(requests[1].contains("Summary of the work so far."), "{}", requests[1]);
    assert!(!requests[1].contains(r#""go""#), "{}", requests[1]);
    assert_eq!(
        context,
        [
            Block::user_text("Summary of the work so far."),
            Block::assistant_text("done")
        ]
    );
}

#[test]
fn a_failed_round_runs_again_on_the_plan_model_in_the_same_turn() {
    // The failure comes after output, so the retry policy of `ai` sends it no second attempt.
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("done")]);
    let model = model();
    let hooks = Script::default().retries([Some(RoundPlan {
        model: Some(model_of(other_target("fallback-model"))),
        ..RoundPlan::default()
    })]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();
    let texts = Mutex::new(Vec::new());

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| match event {
                TurnEvent::Model(yuke_ai::Event::TextDelta(delta)) => {
                    texts.lock().unwrap().push(delta.text.to_string());
                }
                TurnEvent::RoundFailed(_) => texts.lock().unwrap().push("[failed]".to_owned()),
                _ => {}
            })
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })), "{outcome:?}");
    // The observer can tell the text of the failed round from the text of the fallback.
    assert_eq!(*texts.lock().unwrap(), ["cut", "[failed]", "done"]);
    assert_eq!(
        hooks.calls(),
        [
            "retry the provider returned a server error: overloaded_error: Overloaded",
            "stop done"
        ]
    );
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].contains(r#""model":"fallback-model""#), "{}", requests[1]);
    assert_eq!(context, [Block::user_text("go"), Block::assistant_text("done")]);
}

// A retry plan without a model keeps the driver's model.
#[test]
fn a_retry_plan_without_a_model_runs_again_on_the_driver_model() {
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("done")]);
    let model = model();
    let hooks = Script::default().retries([Some(RoundPlan {
        settings: Some(temperature(0.75)),
        ..RoundPlan::default()
    })]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })), "{outcome:?}");
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].contains(r#""model":"test-model""#), "{}", requests[1]);
    assert!(requests[1].contains(r#""temperature":0.75"#), "{}", requests[1]);
}

#[test]
fn a_failed_round_that_no_hook_retries_ends_the_turn() {
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("unused")]);
    let model = model();
    let hooks = Script::default().retries([None]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(outcome.is_err(), "{outcome:?}");
    assert_eq!(
        hooks.calls(),
        ["retry the provider returned a server error: overloaded_error: Overloaded"]
    );
    assert_eq!(transport.requests().len(), 1);
}

/// Hooks that cancel the turn in `before_round`, then wait forever.
struct CancelBeforeRound(CancellationToken);

#[async_trait]
impl Hooks for CancelBeforeRound {
    async fn before_round(&self, _: &[Block]) -> Result<RoundPlan, Box<dyn std::error::Error + Send + Sync>> {
        self.0.cancel();
        std::future::pending().await
    }
}

#[test]
fn a_cancel_during_before_round_sends_no_request() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let model = model();
    let cancellation_token = CancellationToken::new();
    let hooks = CancelBeforeRound(cancellation_token.clone());
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)), "{outcome:?}");
    assert_eq!(transport.requests().len(), 0);
    assert_eq!(context, [Block::user_text("go")]);
}
