use std::error::Error;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use async_trait::async_trait;
use yuke_ai::transport::{BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};
use yuke_ai::{Block, FinishReason, Target, ToolCall, ToolResult, Usage};
use yuke_engine::{
    Answer, CancellationToken, Commit, Driver, Hooks, Journal, Outcome, Replace, Replaced, RoundDecision, RoundPlan,
    Tool, ToolContent, ToolContext, Toolset, TurnEnd, TurnError, TurnEvent,
};

use crate::support::{
    Batches, NoWait, Recorder, ScriptedTransport, block_on, definition, failed_reply, origin, target, text_reply,
    tool_reply, yield_once,
};

/// One saved commit.
#[derive(Debug, Clone, PartialEq)]
struct Saved {
    replaced: Option<(Vec<Block>, usize)>,
    blocks: Vec<Block>,
    answer: Option<Answer>,
    end: Option<&'static str>,
}

/// A journal that replays each commit into one context and keeps each commit.
#[derive(Debug, Default)]
struct Replay {
    context: Mutex<Vec<Block>>,
    saved: Mutex<Vec<Saved>>,
}

impl Replay {
    fn context(&self) -> Vec<Block> {
        self.context.lock().unwrap().clone()
    }

    fn saved(&self) -> Vec<Saved> {
        self.saved.lock().unwrap().clone()
    }

    /// The blocks and the end of each commit, in order.
    fn shapes(&self) -> Vec<(Vec<Block>, Option<&'static str>)> {
        self.saved()
            .into_iter()
            .map(|saved| (saved.blocks, saved.end))
            .collect()
    }
}

#[async_trait]
impl Journal for Replay {
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn Error + Send + Sync>> {
        let mut context = self.context.lock().unwrap();
        commit.apply(&mut context);
        self.saved.lock().unwrap().push(Saved {
            replaced: commit
                .replaced
                .as_ref()
                .map(|Replaced { head, keep }| (head.to_vec(), *keep)),
            blocks: commit.blocks.to_vec(),
            answer: commit.answer.clone(),
            end: commit.end.as_ref().map(|end| match end {
                TurnEnd::Outcome(Outcome::Completed { .. }) => "completed",
                TurnEnd::Outcome(Outcome::Stopped) => "stopped",
                TurnEnd::Outcome(Outcome::Cancelled) => "cancelled",
                TurnEnd::Failed(_) => "failed",
            }),
        });
        Ok(())
    }
}

fn call(id: &str) -> Block {
    Block::ToolCall(ToolCall {
        call_id: id.into(),
        name: "echo".to_owned(),
        arguments: "{}".to_owned(),
    })
}

#[test]
fn the_commits_of_two_turns_replay_to_the_context_and_input_commits_before_its_request() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "echo", "{}")]),
        text_reply("done"),
        text_reply("second"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Batches::new([vec![Block::user_text("steer")]]);
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .inbox(&inbox)
        .journal(&journal);
    let mut context = Vec::new();

    block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run()).unwrap();
    block_on(driver.turn(&mut context, vec![Block::user_text("two")]).run()).unwrap();

    assert_eq!(journal.context(), context);
    assert_eq!(
        journal.shapes(),
        [
            (vec![Block::user_text("go")], None),
            (vec![call("c1")], None),
            (vec![Block::ToolResult(ToolResult::success("c1", "result 1"))], None),
            (vec![Block::user_text("steer")], None),
            (vec![Block::assistant_text("done")], None),
            (vec![], Some("completed")),
            (vec![Block::user_text("two")], None),
            (vec![Block::assistant_text("second")], None),
            (vec![], Some("completed")),
        ]
    );
}

/// Hooks that stop each turn after its first round.
struct StopAfterRound;

#[async_trait]
impl Hooks for StopAfterRound {
    async fn after_round(&self, _: &[Block], _: Option<FinishReason>) -> RoundDecision {
        RoundDecision::Stop
    }
}

#[test]
fn a_stopped_turn_ends_with_a_stopped_commit() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")])]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&StopAfterRound)
        .journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Stopped)));
    assert_eq!(journal.context(), context);
    assert_eq!(journal.shapes().last(), Some(&(vec![], Some("stopped"))));
}

#[test]
fn a_failed_request_commits_an_end_after_its_input() {
    let transport = ScriptedTransport::new([failed_reply("cut")]);
    let target = target();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait).journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Err(TurnError::Model(_))));
    assert_eq!(
        journal.shapes(),
        [(vec![Block::user_text("go")], None), (vec![], Some("failed"))]
    );
    assert_eq!(journal.context(), context);
}

#[test]
fn inbox_input_before_a_failed_request_commits_before_the_request() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), failed_reply("cut")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let inbox = Batches::new([vec![Block::user_text("steer")]]);
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .inbox(&inbox)
        .journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Err(TurnError::Model(_))));
    assert_eq!(
        journal.shapes()[3..],
        [(vec![Block::user_text("steer")], None), (vec![], Some("failed"))]
    );
    assert_eq!(journal.context(), context);
}

#[test]
fn a_cancel_during_the_stream_commits_the_partial_output_with_the_end() {
    let partial = [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"cut"}}"#,
    ]
    .map(|json| format!("data: {json}\n\n"))
    .concat();
    let transport = ScriptedTransport::new([]).then_stall(partial);
    let target = target();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait).journal(&journal);
    let mut context = Vec::new();
    let cancellation_token = CancellationToken::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if matches!(event, TurnEvent::Model(yuke_ai::Event::TextDelta(_))) {
                    cancellation_token.cancel();
                }
            })
            .cancellation_token(cancellation_token.clone())
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(
        journal.saved()[1],
        Saved {
            replaced: None,
            blocks: vec![Block::assistant_text("cut")],
            answer: None,
            end: Some("cancelled"),
        }
    );
    assert_eq!(journal.context(), context);
}

/// A tool that cancels the turn before it returns its result.
struct CancelTurn(CancellationToken);

#[async_trait]
impl Tool for CancelTurn {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        self.0.cancel();
        Ok("partly done".into())
    }
}

#[test]
fn a_cancel_during_a_tool_commits_the_results_with_the_end() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "build", "{}"), ("c2", "echo", "{}")])]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let mut toolset = Toolset::new();
    toolset
        .add(definition("build"), CancelTurn(cancellation_token.clone()))
        .unwrap();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    let shapes = journal.shapes();
    assert_eq!(shapes.len(), 3, "{shapes:?}");
    assert_eq!(shapes[2].0.len(), 2, "both calls get a result: {shapes:?}");
    assert_eq!(shapes[2].1, Some("cancelled"));
    assert_eq!(journal.context(), context);
}

/// A tool that checks whether the journal saved its call before the tool ran.
struct SeesItsCall {
    journal: Arc<Replay>,
    saw: Arc<Mutex<Option<bool>>>,
}

#[async_trait]
impl Tool for SeesItsCall {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        let saved = self.journal.context().contains(&call("c1"));
        *self.saw.lock().unwrap() = Some(saved);
        Ok("ran".into())
    }
}

#[test]
fn the_answer_is_saved_before_its_tool_runs() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let target = target();
    let journal = Arc::new(Replay::default());
    let saw = Arc::new(Mutex::new(None));
    let tool = SeesItsCall {
        journal: Arc::clone(&journal),
        saw: Arc::clone(&saw),
    };
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), tool).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .journal(journal.as_ref());

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    assert_eq!(*saw.lock().unwrap(), Some(true));
}

/// Hooks that send the second round of each turn to `target`.
struct SecondRoundTo {
    target: Target,
    rounds: AtomicUsize,
}

#[async_trait]
impl Hooks for SecondRoundTo {
    async fn before_round(&self, _: &[Block], _: Option<&yuke_ai::Error>) -> RoundPlan {
        if self.rounds.fetch_add(1, Ordering::Relaxed) != 1 {
            return RoundPlan::default();
        }
        RoundPlan {
            target: Some(self.target.clone()),
            ..RoundPlan::default()
        }
    }
}

#[test]
fn each_answer_commit_names_the_target_of_its_round_with_usage_and_finish_reason() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let target = target();
    let other = Target {
        model: "other-model".into(),
        ..target.clone()
    };
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let hooks = SecondRoundTo {
        target: other.clone(),
        rounds: AtomicUsize::new(0),
    };
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks)
        .journal(&journal);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    // The reply reports `input_tokens: 0` and leaves out the other counts.
    let usage = Usage {
        input: Some(0),
        output: Some(1),
        ..Usage::default()
    };
    let answers: Vec<Option<Answer>> = journal.saved().into_iter().map(|saved| saved.answer).collect();
    assert_eq!(
        answers,
        [
            None,
            Some(Answer {
                origin: origin(),
                usage,
                finish_reason: FinishReason::ToolCalls,
            }),
            None,
            Some(Answer {
                origin: yuke_ai::Origin::from(yuke_ai::OriginRef::of(&other)),
                usage,
                finish_reason: FinishReason::Stop,
            }),
            None,
        ]
    );
}

/// A journal that saves its first commits, then fails each later save.
struct FailsAfter {
    saves: usize,
    count: AtomicUsize,
}

#[async_trait]
impl Journal for FailsAfter {
    async fn commit(&self, _: &Commit<'_>) -> Result<(), Box<dyn Error + Send + Sync>> {
        if self.count.fetch_add(1, Ordering::Relaxed) < self.saves {
            return Ok(());
        }
        Err("disk full".into())
    }
}

#[test]
fn a_failed_commit_ends_the_turn_before_the_next_step() {
    // The first save is the input, before the request. The second save is the answer, before the tool.
    for (saves, requests) in [(0, 0), (1, 1)] {
        let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("unused")]);
        let target = target();
        let echo = Recorder::default();
        let mut toolset = Toolset::new();
        toolset.add(definition("echo"), echo.clone()).unwrap();
        let journal = FailsAfter {
            saves,
            count: AtomicUsize::new(0),
        };
        let driver = Driver::new(&transport, &target, &NoWait)
            .toolset(&toolset)
            .journal(&journal);

        let outcome = block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run());

        let Err(TurnError::Commit(error)) = outcome else {
            panic!("expected a failed commit, got {outcome:?}");
        };
        assert_eq!(error.to_string(), "disk full");
        assert_eq!(transport.requests().len(), requests, "saves {saves}");
        assert_eq!(echo.calls(), Vec::<String>::new(), "saves {saves}");
    }
}

/// A journal that cancels the turn during each save, yields once, then saves.
struct CancelDuringSave {
    cancellation_token: CancellationToken,
    replay: Replay,
}

#[async_trait]
impl Journal for CancelDuringSave {
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn Error + Send + Sync>> {
        self.cancellation_token.cancel();
        yield_once().await;
        self.replay.commit(commit).await
    }
}

#[test]
fn a_cancel_during_a_commit_lets_the_commit_finish() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let target = target();
    let cancellation_token = CancellationToken::new();
    let journal = CancelDuringSave {
        cancellation_token: cancellation_token.clone(),
        replay: Replay::default(),
    };
    let driver = Driver::new(&transport, &target, &NoWait).journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(
        journal.replay.shapes(),
        [(vec![Block::user_text("go")], None), (vec![], Some("cancelled"))]
    );
    assert_eq!(transport.requests().len(), 0);
    assert_eq!(journal.replay.context(), context);
}

/// Hooks that replace the context before the second round with `head` and the last `keep` blocks.
struct Summarize {
    head: Vec<Block>,
    keep: usize,
    rounds: AtomicUsize,
}

impl Summarize {
    fn new(head: &[&str], keep: usize) -> Self {
        Summarize {
            head: head.iter().map(|text| Block::user_text(*text)).collect(),
            keep,
            rounds: AtomicUsize::new(0),
        }
    }
}

#[async_trait]
impl Hooks for Summarize {
    async fn before_round(&self, _: &[Block], _: Option<&yuke_ai::Error>) -> RoundPlan {
        if self.rounds.fetch_add(1, Ordering::Relaxed) != 1 {
            return RoundPlan::default();
        }
        RoundPlan {
            replace: Some(Replace {
                head: self.head.clone(),
                keep: self.keep,
            }),
            ..RoundPlan::default()
        }
    }
}

#[test]
fn a_replacement_commits_before_its_request_and_replays_to_the_new_context() {
    // The cases keep no block, the input, a saved answer and the input, and more blocks than the context holds. The
    // last case has no head.
    for (head, keep, saved_keep, expected) in [
        (&["summary"][..], 0, 0, vec!["summary", "second"]),
        (&["summary"], 1, 1, vec!["summary", "two", "second"]),
        (&["summary"], 2, 2, vec!["summary", "first", "two", "second"]),
        (&["summary"], 9, 3, vec!["summary", "one", "first", "two", "second"]),
        (&[], 1, 1, vec!["two", "second"]),
    ] {
        let transport = ScriptedTransport::new([text_reply("first"), text_reply("second")]);
        let target = target();
        let hooks = Summarize::new(head, keep);
        let journal = Replay::default();
        let driver = Driver::new(&transport, &target, &NoWait)
            .hooks(&hooks)
            .journal(&journal);
        let mut context = Vec::new();

        block_on(driver.turn(&mut context, vec![Block::user_text("one")]).run()).unwrap();
        block_on(driver.turn(&mut context, vec![Block::user_text("two")]).run()).unwrap();

        let texts: Vec<&str> = context
            .iter()
            .map(|block| match block {
                Block::UserText(text) | Block::AssistantText(text) => text.as_str(),
                other => panic!("unexpected block {other:?}"),
            })
            .collect();
        assert_eq!(texts, expected, "keep {keep}");
        assert_eq!(journal.context(), context, "keep {keep}");
        // The journal receives the replacement after the input of the turn and before its answer.
        let saved = journal.saved();
        assert_eq!(saved[3].blocks, [Block::user_text("two")], "keep {keep}");
        assert_eq!(saved[4].replaced, Some((hooks.head.clone(), saved_keep)), "keep {keep}");
        assert_eq!(saved[4].blocks, [], "keep {keep}");
    }
}

/// Hooks that replace the context before the first attempt of the second round and again after its failure.
#[derive(Default)]
struct SummarizeTwice {
    rounds: AtomicUsize,
}

#[async_trait]
impl Hooks for SummarizeTwice {
    async fn before_round(&self, _: &[Block], failure: Option<&yuke_ai::Error>) -> RoundPlan {
        if self.rounds.fetch_add(1, Ordering::Relaxed) == 0 {
            return RoundPlan::default();
        }
        // The retry keeps the first summary, the saved answer, and the input.
        let (head, keep, target) = match failure {
            None => ("s1", 2, None),
            Some(_) => ("s2", 3, Some(target())),
        };
        RoundPlan {
            replace: Some(Replace {
                head: vec![Block::user_text(head)],
                keep,
            }),
            target,
            ..RoundPlan::default()
        }
    }
}

#[test]
fn a_replacement_before_a_retried_round_replays_to_the_new_context() {
    let transport = ScriptedTransport::new([text_reply("first"), failed_reply("cut"), text_reply("second")]);
    let target = target();
    let hooks = SummarizeTwice::default();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .hooks(&hooks)
        .journal(&journal);
    let mut context = Vec::new();

    block_on(driver.turn(&mut context, vec![Block::user_text("one")]).run()).unwrap();
    block_on(driver.turn(&mut context, vec![Block::user_text("two")]).run()).unwrap();

    assert_eq!(
        context,
        [
            Block::user_text("s2"),
            Block::user_text("s1"),
            Block::assistant_text("first"),
            Block::user_text("two"),
            Block::assistant_text("second"),
        ]
    );
    assert_eq!(journal.context(), context);
}

/// A transport that records the context of the journal when each request opens.
struct Watching {
    transport: ScriptedTransport,
    journal: Arc<Replay>,
    seen: Mutex<Vec<Vec<Block>>>,
}

impl Transport for Watching {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        self.seen.lock().unwrap().push(self.journal.context());
        self.transport.open(request, deadline)
    }
}

#[test]
fn each_request_opens_after_the_journal_saved_its_input_and_replacement() {
    let journal = Arc::new(Replay::default());
    let transport = Watching {
        transport: ScriptedTransport::new([text_reply("first"), text_reply("second")]),
        journal: Arc::clone(&journal),
        seen: Mutex::default(),
    };
    let target = target();
    let hooks = Summarize::new(&["summary"], 1);
    let driver = Driver::new(&transport, &target, &NoWait)
        .hooks(&hooks)
        .journal(journal.as_ref());
    let mut context = Vec::new();

    block_on(driver.turn(&mut context, vec![Block::user_text("one")]).run()).unwrap();
    block_on(driver.turn(&mut context, vec![Block::user_text("two")]).run()).unwrap();

    assert_eq!(
        *transport.seen.lock().unwrap(),
        [
            vec![Block::user_text("one")],
            vec![Block::user_text("summary"), Block::user_text("two")],
        ]
    );
}

/// Hooks that continue the turn once with input, then proceed.
#[derive(Default)]
struct ContinueOnce {
    rounds: AtomicUsize,
}

#[async_trait]
impl Hooks for ContinueOnce {
    async fn after_round(&self, _: &[Block], _: Option<FinishReason>) -> RoundDecision {
        if self.rounds.fetch_add(1, Ordering::Relaxed) == 0 {
            return RoundDecision::Continue(vec![Block::user_text("the tests fail")]);
        }
        RoundDecision::Proceed
    }
}

#[test]
fn continue_input_commits_before_its_request() {
    let transport = ScriptedTransport::new([text_reply("first"), text_reply("second")]);
    let target = target();
    let hooks = ContinueOnce::default();
    let journal = Replay::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .hooks(&hooks)
        .journal(&journal);
    let mut context = Vec::new();

    block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run()).unwrap();

    assert_eq!(
        journal.shapes(),
        [
            (vec![Block::user_text("go")], None),
            (vec![Block::assistant_text("first")], None),
            (vec![Block::user_text("the tests fail")], None),
            (vec![Block::assistant_text("second")], None),
            (vec![], Some("completed")),
        ]
    );
    assert_eq!(journal.context(), context);
}
