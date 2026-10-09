use std::collections::VecDeque;
use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason};
use yuke_engine::{CancellationToken, Conversation, Driver, Hooks, Outcome, RoundDecision, Toolset, TurnDecision};

use crate::support::{
    NoWait, Recorder, ScriptedTransport, assert_in_order, block_on, definition, target, text_reply, tool_reply,
};

/// Hooks that record each `after_round` and `after_turn` call, and answer each `after_turn` with the next decision.
struct Script {
    decisions: Mutex<VecDeque<TurnDecision>>,
    calls: Mutex<Vec<String>>,
}

impl Script {
    fn new(decisions: impl IntoIterator<Item = TurnDecision>) -> Self {
        Script {
            decisions: Mutex::new(decisions.into_iter().collect()),
            calls: Mutex::default(),
        }
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl Hooks for Script {
    async fn after_round(&self, _: &[Block]) -> RoundDecision {
        self.calls.lock().unwrap().push("after_round".to_owned());
        RoundDecision::Proceed
    }

    async fn after_turn(&self, history: &[Block], finish_reason: FinishReason) -> TurnDecision {
        let last = match history.last() {
            Some(Block::AssistantText(text)) => text.as_str(),
            _ => "",
        };
        self.calls
            .lock()
            .unwrap()
            .push(format!("after_turn {} {last}", finish_reason.as_str()));
        self.decisions.lock().unwrap().pop_front().unwrap()
    }
}

#[test]
fn finish_after_the_final_answer_ends_the_turn_after_the_after_round_hook() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = target();
    let hooks = Script::new([TurnDecision::Finish]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(hooks.calls(), ["after_round", "after_turn stop done"]);
    assert_eq!(transport.requests().len(), 1);
}

#[test]
fn continue_adds_its_input_and_the_turn_runs_its_next_rounds() {
    let transport = ScriptedTransport::new([
        text_reply("first answer"),
        tool_reply(&[("c1", "echo", "{}")]),
        text_reply("second answer"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = Script::new([
        TurnDecision::Continue(vec![Block::user_text("the tests fail")]),
        TurnDecision::Finish,
    ]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert_in_order(&requests[1], &["go", "first answer", "the tests fail"]);
    assert_in_order(&requests[2], &["the tests fail", "c1", "result 1"]);
    assert_eq!(
        conversation.history().last(),
        Some(&Block::assistant_text("second answer"))
    );
}

#[test]
fn input_during_the_final_answer_continues_the_turn_without_the_after_turn_hook() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let target = target();
    let hooks = Script::new([TurnDecision::Finish]);
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks).inbox(&inbox);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(
        hooks.calls(),
        ["after_round", "after_round", "after_turn stop second answer"]
    );
}

#[test]
fn empty_continue_sends_another_request() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let target = target();
    let hooks = Script::new([TurnDecision::Continue(Vec::new()), TurnDecision::Finish]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(transport.requests().len(), 2);
}

/// Hooks that stop after each round, and fail the test when `after_turn` runs.
struct StopEachRound;

#[async_trait]
impl Hooks for StopEachRound {
    async fn after_round(&self, _: &[Block]) -> RoundDecision {
        RoundDecision::Stop
    }

    async fn after_turn(&self, _: &[Block], _: FinishReason) -> TurnDecision {
        panic!("after_turn ran after a stop");
    }
}

#[test]
fn stop_after_the_final_answer_skips_the_after_turn_hook() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = target();
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&StopEachRound);
    let mut conversation = Conversation::new();

    let outcome = block_on(driver.turn(&mut conversation, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
}

/// Hooks that cancel the turn when the model ends it, then wait forever.
struct CancelAfterTurn(CancellationToken);

#[async_trait]
impl Hooks for CancelAfterTurn {
    async fn after_turn(&self, _: &[Block], _: FinishReason) -> TurnDecision {
        self.0.cancel();
        std::future::pending().await
    }
}

#[test]
fn cancel_while_the_after_turn_hook_waits_keeps_the_answer() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let hooks = CancelAfterTurn(cancellation_token.clone());
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);
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
    assert_eq!(transport.requests().len(), 1);
}
