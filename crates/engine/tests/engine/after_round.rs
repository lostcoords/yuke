use std::sync::Mutex;

use yuke_ai::{Block, FinishReason};
use yuke_engine::{Driver, Outcome, RoundDecision, Toolset};
use yuke_testing::{NoWait, ScriptedTransport, assert_in_order, model, text_reply, tool_reply};

use crate::support::{Batches, Recorder, Script, block_on, definition};

#[test]
fn a_final_answer_gives_its_finish_reason_and_proceed_without_input_completes_the_turn() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let hooks = Script::default().decisions([RoundDecision::Proceed]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);

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
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = Script::default().decisions([
        RoundDecision::Continue(vec![Block::user_text("the tests fail")]),
        RoundDecision::Proceed,
        RoundDecision::Proceed,
    ]);
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
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
    let model = model();
    let hooks = Script::default().decisions([RoundDecision::Proceed, RoundDecision::Proceed]);
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks).inbox(&inbox);

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
    let model = model();
    let continue_with = || RoundDecision::Continue(vec![Block::user_text("from the hook")]);
    let hooks = Script::default().decisions([continue_with(), continue_with(), RoundDecision::Proceed]);
    let inbox = Batches::new([vec![Block::user_text("from the user")]]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks).inbox(&inbox);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    let requests = transport.requests();
    assert_in_order(&requests[1], &["first answer", "from the user"]);
    assert!(!requests[1].contains("from the hook"), "{}", requests[1]);
    assert_in_order(&requests[2], &["second answer", "from the hook"]);
}

#[test]
fn empty_continue_sends_another_request() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let model = model();
    let hooks = Script::default().decisions([RoundDecision::Continue(Vec::new()), RoundDecision::Proceed]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(transport.requests().len(), 2);
}

#[test]
fn stop_after_the_final_answer_completes_the_turn() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let hooks = Script::default().decisions([RoundDecision::Stop]);
    let inbox = Mutex::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks).inbox(&inbox);

    let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(*inbox.lock().unwrap(), [Block::user_text("later")]);
}
