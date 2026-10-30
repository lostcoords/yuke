//! The fixtures that only the engine tests use. The shared ones live in `yuke-testing`.

use std::collections::VecDeque;
use std::error::Error;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason, ToolCall, ToolResult};
use yuke_engine::{
    CancellationToken, Commit, Driver, Hooks, Inbox, Journal, Observer, RoundDecision, RoundError, RoundPlan,
    RoundStart, Timer, Tool, ToolContent, ToolContext, ToolDecision, ToolOutcome, TurnEnd, TurnEvent,
};

/// A tool that records the arguments of each call, and answers the call with "result N", counted from 1.
#[derive(Debug, Default, Clone)]
pub(crate) struct Recorder {
    calls: Arc<Mutex<Vec<String>>>,
}

impl Recorder {
    /// The arguments of each call, in call order.
    pub(crate) fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl Tool for Recorder {
    async fn call(&self, arguments: &str, _: &ToolContext<'_>) -> Result<ToolContent, Box<dyn Error + Send + Sync>> {
        let mut calls = self.calls.lock().unwrap();
        calls.push(arguments.to_owned());
        Ok(format!("result {}", calls.len()).into())
    }
}

/// A tool that answers each call with the same result.
pub(crate) struct Fixed(pub(crate) Result<ToolContent, String>);

#[async_trait]
impl Tool for Fixed {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, Box<dyn Error + Send + Sync>> {
        self.0.clone().map_err(Into::into)
    }
}

/// An inbox that hands out one scripted batch for each take, then nothing.
#[derive(Debug, Default)]
pub(crate) struct Batches {
    batches: Mutex<VecDeque<Vec<Block>>>,
}

impl Batches {
    pub(crate) fn new(batches: impl IntoIterator<Item = Vec<Block>>) -> Self {
        Batches {
            batches: Mutex::new(batches.into_iter().collect()),
        }
    }
}

#[async_trait]
impl Inbox for Batches {
    async fn take(&self) -> Result<Vec<Block>, Box<dyn Error + Send + Sync>> {
        Ok(self.batches.lock().unwrap().pop_front().unwrap_or_default())
    }
}

/// An inbox of blocks that a test or a hook adds, and that the driver takes all at once.
pub(crate) struct Queue(Mutex<Vec<Block>>);

impl Queue {
    pub(crate) fn new(blocks: Vec<Block>) -> Self {
        Queue(Mutex::new(blocks))
    }

    /// Append `blocks` after the blocks that the queue holds.
    pub(crate) fn extend(&self, blocks: Vec<Block>) {
        self.0.lock().unwrap().extend(blocks);
    }

    /// A copy of the blocks that the driver did not take.
    pub(crate) fn held(&self) -> Vec<Block> {
        self.0.lock().unwrap().clone()
    }
}

#[async_trait]
impl Inbox for Queue {
    async fn take(&self) -> Result<Vec<Block>, Box<dyn Error + Send + Sync>> {
        Ok(std::mem::take(&mut *self.0.lock().unwrap()))
    }
}

/// Hooks that give scripted answers in order. A hook without a script gives its default answer. A hook that runs
/// out of answers fails the test, so an extra call shows.
#[derive(Default)]
pub(crate) struct Script {
    plans: Mutex<Option<VecDeque<RoundPlan>>>,
    retries: Mutex<Option<VecDeque<Option<RoundPlan>>>>,
    decisions: Mutex<Option<VecDeque<RoundDecision>>>,
    calls: Mutex<Vec<String>>,
    /// The name of the tool whose calls `before_tool` blocks.
    blocked: Option<&'static str>,
    tools: Mutex<Vec<String>>,
    rounds: Mutex<Vec<String>>,
    /// The hook that cancels the turn and then waits forever.
    cancel: Option<(&'static str, CancellationToken)>,
}

impl Script {
    /// Answer each `before_round` call with the next plan of `plans`.
    pub(crate) fn plans(self, plans: impl IntoIterator<Item = RoundPlan>) -> Self {
        Script {
            plans: Mutex::new(Some(plans.into_iter().collect())),
            ..self
        }
    }

    /// Answer each `retry_round` call with the next answer of `retries`.
    pub(crate) fn retries(self, retries: impl IntoIterator<Item = Option<RoundPlan>>) -> Self {
        Script {
            retries: Mutex::new(Some(retries.into_iter().collect())),
            ..self
        }
    }

    /// Answer each `after_round` call with the next decision of `decisions`.
    pub(crate) fn decisions(self, decisions: impl IntoIterator<Item = RoundDecision>) -> Self {
        Script {
            decisions: Mutex::new(Some(decisions.into_iter().collect())),
            ..self
        }
    }

    /// Block each call of the tool `name`.
    pub(crate) fn blocks(self, name: &'static str) -> Self {
        Script {
            blocked: Some(name),
            ..self
        }
    }

    /// Cancel the turn with `cancellation_token` in the hook `point`, such as `after_round`, and wait there forever.
    pub(crate) fn cancel_at(self, point: &'static str, cancellation_token: CancellationToken) -> Self {
        Script {
            cancel: Some((point, cancellation_token)),
            ..self
        }
    }

    /// Return one line for each `retry_round` and `after_round` call, in call order. A retry line holds "retry" and the
    /// failure. An `after_round` line holds the finish reason and the last text of the context.
    pub(crate) fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    /// Return one line for each `before_tool` call ("before", the name, the arguments) and each `after_tool` call
    /// ("after" and the call id), in hook order.
    pub(crate) fn tools(&self) -> Vec<String> {
        self.tools.lock().unwrap().clone()
    }

    /// Return one line for each `before_round` and `retry_round` call: the hook, the number of context blocks, the
    /// window, the input tokens, and the temperature.
    pub(crate) fn rounds(&self) -> Vec<String> {
        self.rounds.lock().unwrap().clone()
    }

    /// Keep the facts of `round` for `hook`.
    fn round(&self, hook: &str, round: &RoundStart<'_>) {
        let line = format!(
            "{hook} {} {:?} {:?} {:?}",
            round.context.len(),
            round.model.context_window,
            round.input_tokens,
            round.settings.temperature
        );
        self.rounds.lock().unwrap().push(line);
    }

    /// Cancel the turn and wait forever when `point` is the cancel point.
    async fn stop_at(&self, point: &str) {
        if let Some((at, cancellation_token)) = &self.cancel
            && *at == point
        {
            cancellation_token.cancel();
            std::future::pending::<()>().await;
        }
    }
}

/// Take the next answer of `script`. A missing script gives `default`, and an empty script fails the test.
fn next<T>(script: &Mutex<Option<VecDeque<T>>>, default: impl FnOnce() -> T) -> T {
    match script.lock().unwrap().as_mut() {
        Some(answers) => answers
            .pop_front()
            .expect("the script has no answer for this hook call"),
        None => default(),
    }
}

#[async_trait]
impl Hooks for Script {
    async fn before_round(&self, round: &RoundStart<'_>) -> Result<RoundPlan, Box<dyn Error + Send + Sync>> {
        self.stop_at("before_round").await;
        self.round("before", round);
        Ok(next(&self.plans, RoundPlan::default))
    }

    async fn retry_round(
        &self,
        round: &RoundStart<'_>,
        failure: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn Error + Send + Sync>> {
        self.stop_at("retry_round").await;
        self.round("retry", round);
        self.calls.lock().unwrap().push(format!("retry {failure}"));
        Ok(next(&self.retries, || None))
    }

    async fn before_tool(&self, call: &ToolCall) -> ToolDecision {
        self.stop_at("before_tool").await;
        let line = format!("before {} {}", call.name, call.arguments);
        self.tools.lock().unwrap().push(line);
        if self.blocked == Some(call.name.as_str()) {
            return ToolDecision::Block("The user blocked this call.".to_owned());
        }
        ToolDecision::Run
    }

    async fn after_tool(&self, call: &ToolCall, _: &ToolOutcome) -> Option<ToolOutcome> {
        self.stop_at("after_tool").await;
        self.tools.lock().unwrap().push(format!("after {}", call.call_id));
        None
    }

    async fn after_round(
        &self,
        context: &[Block],
        finish_reason: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn Error + Send + Sync>> {
        self.stop_at("after_round").await;
        let last = match context.last() {
            Some(Block::AssistantText(text)) => text.as_str(),
            Some(Block::ToolResult(result)) => result.content.as_str(),
            _ => "",
        };
        let finish_reason = finish_reason.map_or("none", FinishReason::as_str);
        self.calls.lock().unwrap().push(format!("{finish_reason} {last}"));
        Ok(next(&self.decisions, || RoundDecision::Proceed))
    }
}

/// A journal that replays each commit into one context and keeps each commit.
#[derive(Debug, Default)]
pub(crate) struct Replay {
    context: Mutex<Vec<Block>>,
    saved: Mutex<Vec<Commit<'static>>>,
}

impl Replay {
    /// Return the context that the commits replay to.
    pub(crate) fn context(&self) -> Vec<Block> {
        self.context.lock().unwrap().clone()
    }

    /// Return each saved commit, in order.
    pub(crate) fn saved(&self) -> Vec<Commit<'static>> {
        self.saved.lock().unwrap().clone()
    }

    /// Return the blocks and the end of each commit, in order.
    pub(crate) fn shapes(&self) -> Vec<(Vec<Block>, Option<TurnEnd>)> {
        self.saved()
            .into_iter()
            .map(|saved| (saved.blocks.into_owned(), saved.end))
            .collect()
    }
}

#[async_trait]
impl Journal for Replay {
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn Error + Send + Sync>> {
        let mut context = self.context.lock().unwrap();
        commit.apply(&mut context);
        self.saved.lock().unwrap().push(commit.clone().into_owned());
        Ok(())
    }
}

/// A timer that records each wait and ends it at once.
#[derive(Debug, Default)]
pub(crate) struct Waits {
    waits: Mutex<Vec<Duration>>,
}

impl Waits {
    /// The waits, in order.
    pub(crate) fn waits(&self) -> Vec<Duration> {
        self.waits.lock().unwrap().clone()
    }
}

#[async_trait]
impl Timer for Waits {
    async fn sleep(&self, duration: Duration) {
        self.waits.lock().unwrap().push(duration);
    }
}

/// A timer that cancels the turn when its wait starts. The wait never ends by itself.
pub(crate) struct CancelOnSleep(pub(crate) CancellationToken);

#[async_trait]
impl Timer for CancelOnSleep {
    async fn sleep(&self, _: Duration) {
        self.0.cancel();
        std::future::pending::<()>().await;
    }
}

/// Run a future to its end. It polls again only after a wake, and a future that waits with no wake fails the test.
pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    let woken = Arc::new(Woken::default());
    let waker = Waker::from(Arc::clone(&woken));
    let mut context = Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    loop {
        if let Poll::Ready(output) = future.as_mut().poll(&mut context) {
            return output;
        }
        assert!(
            woken.0.swap(false, Ordering::SeqCst),
            "the future waits for something that no test ends"
        );
    }
}

/// Run one turn, and return the tool results of the context. The test fails unless the observer received the same
/// results. A parallel group finishes in any order, so the check sorts both lists by call id.
pub(crate) fn results_in_context(driver: Driver<'_>) -> Vec<ToolResult> {
    let mut context = Vec::new();
    let finished = Mutex::new(Vec::new());
    block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::ToolFinished { result, .. } = event {
                    finished.lock().unwrap().push((*result).clone());
                }
            })
            .run(),
    )
    .unwrap();
    let results = tool_results(&context);
    let mut finished = finished.into_inner().unwrap();
    let mut sorted = results.clone();
    finished.sort_by(|left, right| left.call_id.cmp(&right.call_id));
    sorted.sort_by(|left, right| left.call_id.cmp(&right.call_id));
    assert_eq!(
        finished, sorted,
        "the observer receives the results that the model receives"
    );
    results
}

/// The tool results in `context`, in context order.
pub(crate) fn tool_results(context: &[Block]) -> Vec<ToolResult> {
    context
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) => Some(result.clone()),
            _ => None,
        })
        .collect()
}

/// A short label for `event`, so a test can compare whole event lists.
pub(crate) fn label(event: &TurnEvent<'_>) -> String {
    match event {
        TurnEvent::ResponseStarted => "response started".to_owned(),
        TurnEvent::ResponseFailed(_) => "response failed".to_owned(),
        TurnEvent::ResponseCancelled { blocks } => {
            blocks.iter().fold("response cancelled".to_owned(), |label, block| {
                format!("{label} {}", block.block)
            })
        }
        TurnEvent::Model(yuke_ai::Event::BlockStarted(started)) => {
            format!("start {} {:?}", started.block, started.kind)
        }
        TurnEvent::Model(yuke_ai::Event::TextDelta(delta)) => format!("text {}", delta.text),
        TurnEvent::Model(yuke_ai::Event::ReasoningDelta(delta)) => format!("reasoning {}", delta.text),
        TurnEvent::Model(yuke_ai::Event::ToolInputDelta(delta)) => format!("arguments {} {}", delta.block, delta.text),
        TurnEvent::Model(yuke_ai::Event::BlockStopped(stopped)) => format!("stop {}", stopped.block),
        TurnEvent::Model(yuke_ai::Event::Done(done)) => format!("done {:?}", done.finish_reason),
        TurnEvent::ToolStarted { call, .. } => format!("tool {}", call.call_id),
        TurnEvent::ToolFinished { result, .. } => format!("result {} {}", result.call_id, result.content),
        TurnEvent::RoundFailed(_) => "round failed".to_owned(),
        TurnEvent::RetryScheduled { .. } => "retry".to_owned(),
        other => format!("other {other:?}"),
    }
}

/// An observer that keeps the [`label`] of each event.
#[derive(Default)]
pub(crate) struct Labels(Mutex<Vec<String>>);

impl Labels {
    /// The labels, in event order.
    pub(crate) fn labels(&self) -> Vec<String> {
        self.0.lock().unwrap().clone()
    }
}

impl Observer for Labels {
    fn event(&self, event: &TurnEvent<'_>) {
        self.0.lock().unwrap().push(label(event));
    }
}

/// A waker that records a wake.
#[derive(Default)]
struct Woken(AtomicBool);

impl std::task::Wake for Woken {
    fn wake(self: Arc<Self>) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// Wait once, and wake at once, as a short wait for the operating system does.
pub(crate) async fn yield_once() {
    let mut yielded = false;
    std::future::poll_fn(|context| {
        if yielded {
            return Poll::Ready(());
        }
        yielded = true;
        context.waker().wake_by_ref();
        Poll::Pending
    })
    .await;
}
