use std::collections::VecDeque;
use std::error::Error;
use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::scripted::{ScriptedTransport, text_reply, tool_reply};
use yuke_ai::{Block, FinishReason};
use yuke_engine::NoWait;
use yuke_engine::{Driver, Hooks, Inbox, Outcome, RoundDecision, RoundError, Toolset, TurnEnd, TurnError};
use yuke_testing::{assert_in_order, definition, model};

use crate::support::{Queue, Recorder, Replay, Script, block_on};

/// Hooks that put the next input of `inputs` in `inbox`, and then answer as `script`.
struct Feeding<'a> {
    script: Script,
    inbox: &'a Queue,
    inputs: Mutex<VecDeque<Vec<Block>>>,
}

#[async_trait]
impl Hooks for Feeding<'_> {
    async fn after_round(
        &self,
        context: &[Block],
        finish_reason: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn Error + Send + Sync>> {
        let input = self.inputs.lock().unwrap().pop_front().unwrap_or_default();
        self.inbox.extend(input);
        self.script.after_round(context, finish_reason).await
    }
}

#[test]
fn input_of_the_hook_continues_the_turn_and_a_tool_round_gives_no_finish_reason() {
    let transport = ScriptedTransport::new([
        text_reply("first answer"),
        tool_reply(&[("c1", "echo", "{}")]),
        text_reply("second answer"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Queue::new(Vec::new());
    let hooks = Feeding {
        script: Script::default(),
        inbox: &inbox,
        inputs: Mutex::new(VecDeque::from([vec![Block::user_text("the tests fail")]])),
    };
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(
        hooks.script.calls(),
        ["stop first answer", "none result 1", "stop second answer"]
    );
    let requests = transport.requests();
    assert_eq!(requests.len(), 3);
    assert_in_order(&requests[1], &["go", "first answer", "the tests fail"]);
    assert_in_order(&requests[2], &["the tests fail", "c1", "result 1"]);
    assert_eq!(context.last(), Some(&Block::assistant_text("second answer")));
}

#[test]
fn input_of_the_user_and_of_the_hook_reach_the_same_request_and_the_hook_is_asked_again() {
    let transport = ScriptedTransport::new([text_reply("first answer"), text_reply("second answer")]);
    let model = model();
    let inbox = Queue::new(vec![Block::user_text("from the user")]);
    let hooks = Feeding {
        script: Script::default(),
        inbox: &inbox,
        inputs: Mutex::new(VecDeque::from([vec![Block::user_text("from the hook")]])),
    };
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);

    block_on(
        driver
            .turn(&mut Vec::new(), vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    )
    .unwrap();

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    assert_in_order(&requests[1], &["first answer", "from the user", "from the hook"]);
    assert_eq!(hooks.script.calls(), ["stop first answer", "stop second answer"]);
}

/// An inbox that fails each take.
struct Broken;

#[async_trait]
impl Inbox for Broken {
    async fn take(&self) -> Result<Vec<Block>, Box<dyn Error + Send + Sync>> {
        Err("the store is gone".into())
    }
}

#[test]
fn a_failed_take_of_the_inbox_ends_the_turn_and_saves_the_failure() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &model, &NoWait);

    let outcome = block_on(
        driver
            .turn(&mut Vec::new(), vec![Block::user_text("go")])
            .inbox(&Broken)
            .journal(&journal)
            .run(),
    );

    assert!(
        matches!(&outcome, Err(TurnError::Round(RoundError::Inbox(error))) if error.to_string() == "the store is gone"),
        "{outcome:?}"
    );
    assert_eq!(
        journal.saved().last().and_then(|commit| commit.end.clone()),
        Some(TurnEnd::Failed("the store is gone".to_owned()))
    );
}

#[test]
fn stop_after_the_final_answer_completes_the_turn() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let hooks = Script::default().decisions([RoundDecision::Stop]);
    let inbox = Queue::new(vec![Block::user_text("later")]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);

    let outcome = block_on(
        driver
            .turn(&mut Vec::new(), vec![Block::user_text("go")])
            .inbox(&inbox)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })));
    assert_eq!(inbox.held(), [Block::user_text("later")]);
}
