//! The fixtures that only the engine tests use. The shared ones live in `yuke-testing`.

use std::collections::VecDeque;
use std::error::Error;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason};
use yuke_engine::{
    CancellationToken, Commit, Driver, Hooks, Inbox, Journal, RoundDecision, RoundError, RoundPlan, Timer, Tool,
    ToolContent, ToolContext, TurnEnd,
};
use yuke_testing::target;

/// The origin of the shared test target.
pub(crate) fn origin() -> yuke_ai::Origin {
    yuke_ai::Origin::from(yuke_ai::OriginRef::of(&target()))
}

/// A definition of `name` that takes any object.
pub(crate) fn definition(name: &str) -> yuke_ai::ToolDefinition {
    yuke_ai::ToolDefinition {
        name: name.into(),
        description: "A test tool.".to_owned(),
        input_schema: r#"{"type":"object"}"#.to_owned(),
        defer_loading: false,
    }
}

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
    async fn call(&self, arguments: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        let mut calls = self.calls.lock().unwrap();
        calls.push(arguments.to_owned());
        Ok(format!("result {}", calls.len()).into())
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

impl Inbox for Batches {
    fn take(&self) -> Vec<Block> {
        self.batches.lock().unwrap().pop_front().unwrap_or_default()
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

    /// Return one line for each `retry_round` and `after_round` call, in call order. A retry line holds "retry" and the
    /// failure. An `after_round` line holds the finish reason and the last text of the context.
    pub(crate) fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
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
    async fn before_round(&self, _: &[Block]) -> Result<RoundPlan, Box<dyn Error + Send + Sync>> {
        Ok(next(&self.plans, RoundPlan::default))
    }

    async fn retry_round(
        &self,
        _: &[Block],
        failure: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn Error + Send + Sync>> {
        self.calls.lock().unwrap().push(format!("retry {failure}"));
        Ok(next(&self.retries, || None))
    }

    async fn after_round(
        &self,
        context: &[Block],
        finish_reason: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn Error + Send + Sync>> {
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

/// Run one turn, and return the tool results of the context.
pub(crate) fn results_in_context(driver: Driver<'_>) -> Vec<yuke_ai::ToolResult> {
    let mut context = Vec::new();
    block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run()).unwrap();
    context
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) => Some(result.clone()),
            _ => None,
        })
        .collect()
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
