use std::collections::VecDeque;
use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason};
use yuke_engine::{Driver, Hooks, Outcome, RoundDecision, Toolset};

use crate::support::{
    Batches, NoWait, Recorder, ScriptedTransport, assert_in_order, block_on, definition, target, text_reply, tool_reply,
};

/// Hooks that record each `after_round` call and return the next decision.
struct Script {
    decisions: Mutex<VecDeque<RoundDecision>>,
    calls: Mutex<Vec<String>>,
}

impl Script {
    fn new(decisions: impl IntoIterator<Item = RoundDecision>) -> Self {
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
    async fn after_round(&self, context: &[Block], finish_reason: Option<FinishReason>) -> RoundDecision {
        let last = match context.last() {
            Some(Block::AssistantText(text)) => text.as_str(),
            Some(Block::ToolResult(result)) => result.content.as_str(),
            _ => "",
        };
        let finish_reason = finish_reason.map_or("none", FinishReason::as_str);
        self.calls.lock().unwrap().push(format!("{finish_reason} {last}"));
        self.decisions.lock().unwrap().pop_front().unwrap()
    }
}

#[test]
fn a_final_answer_gives_its_finish_reason_and_proceed_without_input_completes_the_turn() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = target();
    let hooks = Script::new([RoundDecision::Proceed]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(
        outcome,
        Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        })
    ));
    assert_eq!(hooks.calls(), ["stop done"]);
    assert_eq!(transport.requests().len(), 1);
}

#[test]
fn continue_adds_its_input_and_a_tool_round_gives_no_finish_reason() {
    let transport = ScriptedTransport::new([
        text_reply("first answer"),
        tool_reply(&[("c1", "echo", "{}")]),
        text_reply("second answer"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = Script::new([
        RoundDecision::Continue(vec![Block::user_text("the tests fail")]),
        RoundDecision::Proceed,
        RoundDecision::Proceed,
    ]);
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(
        hooks.calls(),
        ["stop first answer", "none result 1", "stop second answer"]
    );
    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert_in_order(&requests[1], &["go", "first answer", "the tests fail"]);
    assert_in_order(&requests[2], &["the tests fail", "c1", "result 1"]);
    assert_eq!(context.last(), Some(&Block::assistant_text("second answer")));
}

#[test]
fn inbox_input_after_a_final_answer_continues_the_turn() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let target = target();
    let hooks = Script::new([RoundDecision::Proceed, RoundDecision::Proceed]);
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks).inbox(&inbox);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(hooks.calls(), ["stop first answer", "stop second answer"]);
    assert_in_order(&transport.requests()[1], &["first answer", "later"]);
}

#[test]
fn inbox_input_goes_before_continue_input_and_the_hook_is_asked_again() {
    let transport = ScriptedTransport::new([
        text_reply("first answer"),
        text_reply("second answer"),
        text_reply("third answer"),
    ]);
    let target = target();
    let continue_with = || RoundDecision::Continue(vec![Block::user_text("from the hook")]);
    let hooks = Script::new([continue_with(), continue_with(), RoundDecision::Proceed]);
    let inbox = Batches::new([vec![Block::user_text("from the user")]]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks).inbox(&inbox);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert_in_order(&requests[1], &["first answer", "from the user"]);
    assert!(!requests[1].contains("from the hook"), "{}", requests[1]);
    assert_in_order(&requests[2], &["second answer", "from the hook"]);
}

#[test]
fn empty_continue_sends_another_request() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let target = target();
    let hooks = Script::new([RoundDecision::Continue(Vec::new()), RoundDecision::Proceed]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(transport.requests().len(), 2);
}

#[test]
fn stop_after_the_final_answer_completes_the_turn() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = target();
    let hooks = Script::new([RoundDecision::Stop]);
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &target, &NoWait).hooks(&hooks).inbox(&inbox);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(*inbox.lock().unwrap(), [Block::user_text("later")]);
}
