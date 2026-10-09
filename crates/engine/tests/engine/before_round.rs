use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use yuke_ai::{Block, Settings, Target};
use yuke_engine::{CancellationToken, Driver, Hooks, Outcome, RoundPlan, Toolset, TurnEvent};

use crate::support::{
    NoWait, Recorder, ScriptedTransport, block_on, definition, failed_reply, target, text_reply, tool_reply,
};

/// The test target under another model name.
fn other_target(model: &'static str) -> Target {
    Target {
        model: model.into(),
        ..target()
    }
}

/// Settings with the system prompt `system`.
fn system(system: &str) -> Settings {
    Settings::new().system(system)
}

#[test]
fn the_driver_settings_reach_each_request() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let settings = system("Be brief.");
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .settings(&settings);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    for request in &requests {
        assert!(request.contains("Be brief."), "{request}");
    }
}

/// Hooks that give the first round other settings and another model, and leave each later round alone.
#[derive(Default)]
struct FirstRoundOnly {
    rounds: AtomicUsize,
}

#[async_trait]
impl Hooks for FirstRoundOnly {
    async fn before_round(&self, _: &[Block], _: Option<&yuke_ai::Error>) -> RoundPlan {
        if self.rounds.fetch_add(1, Ordering::Relaxed) > 0 {
            return RoundPlan::default();
        }
        RoundPlan {
            target: Some(other_target("router-model")),
            settings: Some(system("First round.")),
            ..RoundPlan::default()
        }
    }
}

#[test]
fn a_plan_target_and_settings_apply_to_their_round_only() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = FirstRoundOnly::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert!(requests[0].contains(r#""model":"router-model""#), "{}", requests[0]);
    assert!(requests[0].contains("First round."), "{}", requests[0]);
    assert!(requests[1].contains(r#""model":"test-model""#), "{}", requests[1]);
    assert!(!requests[1].contains("First round."), "{}", requests[1]);
}

/// Hooks that replace the history with a summary before the second round.
#[derive(Default)]
struct SummarizeSecondRound {
    rounds: AtomicUsize,
}

#[async_trait]
impl Hooks for SummarizeSecondRound {
    async fn before_round(&self, _: &[Block], _: Option<&yuke_ai::Error>) -> RoundPlan {
        if self.rounds.fetch_add(1, Ordering::Relaxed) != 1 {
            return RoundPlan::default();
        }
        RoundPlan {
            history: Some(vec![Block::user_text("Summary of the work so far.")]),
            ..RoundPlan::default()
        }
    }
}

#[test]
fn a_plan_history_replaces_the_history_and_stays() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = SummarizeSecondRound::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);
    let mut history = Vec::new();

    block_on(driver.turn(&mut history, vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert!(requests[1].contains("Summary of the work so far."), "{}", requests[1]);
    assert!(!requests[1].contains(r#""go""#), "{}", requests[1]);
    assert_eq!(
        history,
        [
            Block::user_text("Summary of the work so far."),
            Block::assistant_text("done")
        ]
    );
}

/// Hooks that answer a failure with `fallback`, and keep the failures that they saw.
struct FallBack {
    fallback: RoundPlan,
    failures: Mutex<Vec<String>>,
}

impl FallBack {
    fn new(fallback: RoundPlan) -> Self {
        FallBack {
            fallback,
            failures: Mutex::new(Vec::new()),
        }
    }
}

#[async_trait]
impl Hooks for FallBack {
    async fn before_round(&self, _: &[Block], failure: Option<&yuke_ai::Error>) -> RoundPlan {
        let Some(failure) = failure else {
            return RoundPlan::default();
        };
        self.failures.lock().unwrap().push(failure.to_string());
        self.fallback.clone()
    }
}

#[test]
fn a_failed_round_runs_again_on_the_plan_target_in_the_same_turn() {
    // The failure comes after output, so the retry policy of `ai` sends it no second attempt.
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("done")]);
    let target = target();
    let hooks = FallBack::new(RoundPlan {
        target: Some(other_target("fallback-model")),
        ..RoundPlan::default()
    });
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);
    let mut history = Vec::new();
    let texts = Mutex::new(Vec::new());

    let outcome = block_on(
        driver
            .turn(&mut history, vec![Block::user_text("go")])
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
    assert_eq!(hooks.failures.lock().unwrap().len(), 1);
    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].contains(r#""model":"fallback-model""#), "{}", requests[1]);
    assert_eq!(history, [Block::user_text("go"), Block::assistant_text("done")]);
}

#[test]
fn a_failed_round_without_a_plan_target_ends_the_turn() {
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("unused")]);
    let target = target();
    let hooks = FallBack::new(RoundPlan {
        settings: Some(system("Try harder.")),
        ..RoundPlan::default()
    });
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(outcome.is_err(), "{outcome:?}");
    assert_eq!(hooks.failures.lock().unwrap().len(), 1);
    assert_eq!(transport.requests().len(), 1);
}

/// Hooks that cancel the turn in `before_round`, then wait forever.
struct CancelBeforeRound(CancellationToken);

#[async_trait]
impl Hooks for CancelBeforeRound {
    async fn before_round(&self, _: &[Block], _: Option<&yuke_ai::Error>) -> RoundPlan {
        self.0.cancel();
        std::future::pending().await
    }
}

#[test]
fn a_cancel_during_before_round_sends_no_request() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let hooks = CancelBeforeRound(cancellation_token.clone());
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);
    let mut history = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut history, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)), "{outcome:?}");
    assert_eq!(transport.requests().len(), 0);
    assert_eq!(history, [Block::user_text("go")]);
}
