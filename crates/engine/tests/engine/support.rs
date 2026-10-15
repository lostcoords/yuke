//! The fixtures that only the engine tests use. The shared ones live in `yuke-testing`.

use std::collections::VecDeque;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use async_trait::async_trait;
use yuke_engine::{CancellationToken, Driver, Inbox, Timer, Tool, ToolContent, ToolContext};
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
    batches: Mutex<VecDeque<Vec<yuke_ai::Block>>>,
}

impl Batches {
    pub(crate) fn new(batches: impl IntoIterator<Item = Vec<yuke_ai::Block>>) -> Self {
        Batches {
            batches: Mutex::new(batches.into_iter().collect()),
        }
    }
}

impl Inbox for Batches {
    fn take(&self) -> Vec<yuke_ai::Block> {
        self.batches.lock().unwrap().pop_front().unwrap_or_default()
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
    block_on(driver.turn(&mut context, vec![yuke_ai::Block::user_text("go")]).run()).unwrap();
    context
        .iter()
        .filter_map(|block| match block {
            yuke_ai::Block::ToolResult(result) => Some(result.clone()),
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
