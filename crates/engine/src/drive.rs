//! The standard driver. It carries out each [`Action`] of a [`Conversation`] over a caller's transport.

use std::borrow::Cow;
use std::future::poll_fn;
use std::pin::{Pin, pin};
use std::sync::{Mutex, PoisonError};
use std::task::Poll;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::future::join_all;
use tokio_util::sync::CancellationToken;
use yuke_ai::retry::{self, Attempt};
use yuke_ai::transport::Transport;
use yuke_ai::{
    AttemptError, BlobStore, Block, Encoder, Options, Partial, Reply, Request, Response, SEARCH_TOOL_NAME, Settings,
    Target, ToolCall, ToolDefinition, ToolResult,
};

use crate::conversation::{Action, CANCELLED_REASON, Conversation, Outcome, not_executed};
use crate::hooks::{Hooks, NoHooks, RoundDecision, RoundPlan, ToolDecision};
use crate::search::{self, Bm25, Declared, ToolSearch};
use crate::tool::{Concurrency, TOOL_CALL_NAME, ToolContext, Toolset};

/// One fact of a turn, for an observer. It borrows turn data until the observer returns, so an observer copies the
/// data that it keeps.
#[derive(Debug)]
#[non_exhaustive]
pub enum TurnEvent<'a> {
    /// One event of a model reply, in source order.
    Model(yuke_ai::Event<'a>),

    /// The driver handles this call. This event comes before [`Hooks::before_tool`], so a blocked call also has it.
    ToolStarted(&'a ToolCall),

    /// A running call showed live output through [`ToolContext::output`]. The model never sees it.
    ToolOutput {
        /// The id of the call.
        call_id: &'a str,

        /// The output text.
        text: &'a str,
    },

    /// A call finished with this result. The approved calls of one parallel group finish in any order.
    ToolFinished(&'a ToolResult),

    /// A round failed after its retries. The model events of the round came before it, and the history keeps none of
    /// them. The driver then asks [`Hooks::before_round`] whether the round runs again.
    RoundFailed(&'a yuke_ai::Error),

    /// An attempt failed, and the driver plans to send the same request again after `after`.
    RetryScheduled {
        /// The wait before the next attempt.
        after: Duration,

        /// The failed attempt.
        error: &'a AttemptError,
    },
}

/// Receives the events of a turn, one at a time, and returns without a wait. Two turns can share one observer, so an
/// observer with state keeps that state behind a lock or an atomic.
pub trait Observer: Send + Sync {
    /// Receive one event.
    fn event(&self, event: &TurnEvent<'_>);
}

// A closure or a function is an observer, so a quick observer needs no struct.
impl<F: Fn(&TurnEvent<'_>) + Send + Sync> Observer for F {
    fn event(&self, event: &TurnEvent<'_>) {
        self(event);
    }
}

/// Makes waits. The caller supplies it, so the engine needs no async runtime of its own.
#[async_trait]
pub trait Timer: Send + Sync {
    /// Return after `duration`.
    async fn sleep(&self, duration: Duration);
}

/// Holds the input that arrives during a turn. The driver takes it after a round only when the turn continues, so
/// input never changes a request in flight. An inbox is `Sync`, so another task can add input while a turn runs.
pub trait Inbox: Send + Sync {
    /// Remove and return the input that arrived since the last call. Return at once, with an empty `Vec` when none
    /// arrived.
    fn take(&self) -> Vec<Block>;
}

// A locked `Vec` is the simplest inbox: one task pushes, and the driver takes.
impl Inbox for Mutex<Vec<Block>> {
    fn take(&self) -> Vec<Block> {
        // A panic of another holder leaves a valid `Vec`, so its input stays usable.
        std::mem::take(&mut *self.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

/// The inbox of a driver without an inbox. It never holds input.
struct NoInput;

impl Inbox for NoInput {
    fn take(&self) -> Vec<Block> {
        Vec::new()
    }
}

/// The settings of the turns against one target. A driver borrows each value and keeps no state. Make a new driver
/// when a setting changes.
#[derive(Clone, Copy)]
pub struct Driver<'a> {
    transport: &'a dyn Transport,
    target: &'a Target,
    timer: &'a dyn Timer,
    toolset: &'a Toolset,
    hooks: &'a dyn Hooks,
    inbox: &'a dyn Inbox,
    settings: &'a Settings,
    blob_store: Option<&'a dyn BlobStore>,
    tool_search: &'a dyn ToolSearch,
}

/// The toolset of a driver without tools.
static NO_TOOLS: Toolset = Toolset::new();

/// The settings of a driver without settings. Each value stays at its endpoint default.
static NO_SETTINGS: Settings = Settings::new();

impl std::fmt::Debug for Driver<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Driver")
            .field("target", &self.target)
            .field("toolset", &self.toolset)
            .finish_non_exhaustive()
    }
}

impl<'a> Driver<'a> {
    /// A driver that sends to `target` through `transport`, and waits with `timer` before a retry. It offers no tools,
    /// and it takes no input during a turn. Its hooks run each call and continue each round. They end each turn when
    /// the model ends it.
    pub fn new(transport: &'a dyn Transport, target: &'a Target, timer: &'a dyn Timer) -> Self {
        Driver {
            transport,
            target,
            timer,
            toolset: &NO_TOOLS,
            hooks: &NoHooks,
            inbox: &NoInput,
            settings: &NO_SETTINGS,
            blob_store: None,
            tool_search: &Bm25,
        }
    }

    /// Offer the tools of `toolset` to the model.
    #[must_use]
    pub fn toolset(self, toolset: &'a Toolset) -> Self {
        Driver { toolset, ..self }
    }

    /// Ask `hooks` for each decision of a turn, as [`Hooks`] lists them.
    #[must_use]
    pub fn hooks(self, hooks: &'a dyn Hooks) -> Self {
        Driver { hooks, ..self }
    }

    /// Take new input from `inbox` after a round when the turn continues.
    #[must_use]
    pub fn inbox(self, inbox: &'a dyn Inbox) -> Self {
        Driver { inbox, ..self }
    }

    /// The call that `call` runs, and its result when it runs nothing. The model calls a deferred tool through the
    /// bridge, but the hooks and the observer see the real call.
    fn resolve<'c>(&self, call: &'c ToolCall) -> Resolved<'c> {
        let call = if call.name == TOOL_CALL_NAME && self.toolset.deferred().next().is_some() {
            match search::unwrap_call(self.toolset, call) {
                Ok(real) => Cow::Owned(real),
                Err(refused) => {
                    return Resolved {
                        call: Cow::Borrowed(call),
                        result: Some(refused),
                    };
                }
            }
        } else {
            Cow::Borrowed(call)
        };
        // The parse error goes to the model before a hook or the tool receives the call. The model can send it again.
        let result = serde_json::from_str::<serde::de::IgnoredAny>(&call.arguments)
            .err()
            .map(|error| not_executed(&call, &format!("its arguments are not valid JSON: {error}.")));
        Resolved { call, result }
    }

    /// Whether `call` runs the built-in search of the deferred tools.
    fn is_search(&self, call: &ToolCall) -> bool {
        call.name == SEARCH_TOOL_NAME && self.toolset.deferred().next().is_some()
    }

    /// The concurrency of a resolved call. A call that runs nothing, and the search that only reads the toolset, do
    /// not wait for other calls.
    fn concurrency(&self, resolved: &Resolved<'_>) -> Concurrency {
        if resolved.result.is_some() || self.is_search(&resolved.call) {
            Concurrency::Parallel
        } else {
            self.toolset.concurrency(&resolved.call.name)
        }
    }

    /// Run the calls of one group, and return their results in call order. The driver asks [`Hooks::before_tool`] for
    /// each call in call order first. Then the approved calls run together.
    async fn call_group(
        &self,
        mut group: Vec<Resolved<'_>>,
        native: bool,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> Vec<ToolResult> {
        // After this loop, a call without a result is a call that the hooks let run.
        for Resolved { call, result } in &mut group {
            observer.event(&TurnEvent::ToolStarted(call));
            if result.is_none() {
                *result = match race(self.hooks.before_tool(call), pin!(cancellation_token.cancelled())).await {
                    Raced::Done(ToolDecision::Run) => None,
                    Raced::Done(ToolDecision::Block(reason)) => Some(ToolResult::error(&call.call_id, reason)),
                    Raced::Cancelled => Some(not_executed(call, CANCELLED_REASON)),
                };
            }
            if let Some(result) = result {
                observer.event(&TurnEvent::ToolFinished(result));
            }
        }

        let calls = group.into_iter().map(|Resolved { call, result }| async move {
            match result {
                Some(result) => result,
                None => self.run_call(&call, native, observer, cancellation_token).await,
            }
        });
        join_all(calls).await
    }

    /// Run an approved `call`, then ask [`Hooks::after_tool`], and return its result. A cancel before the start runs
    /// nothing.
    async fn run_call(
        &self,
        call: &ToolCall,
        native: bool,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> ToolResult {
        // A cancel during the hooks of the group comes before this call starts, so the call does not start.
        let result = if cancellation_token.is_cancelled() {
            not_executed(call, CANCELLED_REASON)
        } else if self.is_search(call) {
            let searched = search::search(self.tool_search, self.toolset, call, native);
            match race(searched, pin!(cancellation_token.cancelled())).await {
                Raced::Done(result) => self.after_tool(call, result, cancellation_token).await,
                Raced::Cancelled => not_executed(call, CANCELLED_REASON),
            }
        } else {
            let context = ToolContext::new(call, cancellation_token, observer);
            let result = self.toolset.call(call, &context).await;
            self.after_tool(call, result, cancellation_token).await
        };
        observer.event(&TurnEvent::ToolFinished(&result));
        result
    }

    /// Ask [`Hooks::after_tool`] for a replacement of `result`. A cancel keeps `result`.
    async fn after_tool(
        &self,
        call: &ToolCall,
        result: ToolResult,
        cancellation_token: &CancellationToken,
    ) -> ToolResult {
        match race(
            self.hooks.after_tool(call, &result),
            pin!(cancellation_token.cancelled()),
        )
        .await
        {
            // The result answers this call, so a replacement keeps its call id.
            Raced::Done(Some(replacement)) => ToolResult {
                call_id: result.call_id,
                ..replacement
            },
            Raced::Done(None) | Raced::Cancelled => result,
        }
    }

    /// Send each request with `settings`, unless a [`RoundPlan`] gives other settings for its round.
    #[must_use]
    pub fn settings(self, settings: &'a Settings) -> Self {
        Driver { settings, ..self }
    }

    /// Read the media of each request from `blob_store`. Without a store, a request with media fails to encode.
    #[must_use]
    pub fn blobs(self, blob_store: &'a dyn BlobStore) -> Self {
        Driver {
            blob_store: Some(blob_store),
            ..self
        }
    }

    /// Set the ranker of the deferred tools for each search. The default ranker is [`Bm25`].
    #[must_use]
    pub fn tool_search(self, tool_search: &'a dyn ToolSearch) -> Self {
        Driver { tool_search, ..self }
    }

    /// The turn of `input` on `history`. [`Turn::run`] runs it and adds the blocks of the turn to `history`.
    pub fn turn<'t>(&self, history: &'t mut Vec<Block>, input: Vec<Block>) -> Turn<'t>
    where
        'a: 't,
    {
        Turn {
            driver: *self,
            history,
            input,
            observer: None,
            cancellation_token: CancellationToken::new(),
        }
    }

    /// Send the request of one round. Ask [`Hooks::before_round`] for the plan first. After a failure, ask again, and
    /// send the round again when the plan names a target.
    async fn send_round(
        &self,
        conversation: &mut Conversation<'_>,
        encoder: &mut Encoder,
        declared: &Declared<'_>,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> (Sent, bool) {
        let mut failure: Option<yuke_ai::Error> = None;
        loop {
            let Raced::Done(mut plan) = race(
                self.hooks.before_round(conversation.history(), failure.as_ref()),
                pin!(cancellation_token.cancelled()),
            )
            .await
            else {
                return (Sent::Cancelled(Vec::new()), false);
            };
            if let Some(error) = failure
                && plan.target.is_none()
            {
                return (Sent::Finished(Err(error)), false);
            }
            if let Some(history) = plan.history.take() {
                conversation.replace_history(history);
            }
            let native = plan.target.as_ref().unwrap_or(self.target).tool_search;
            let tools = declared.tools(native);
            match self
                .send(
                    encoder,
                    conversation.history(),
                    tools,
                    &plan,
                    observer,
                    cancellation_token,
                )
                .await
            {
                Sent::Finished(Err(error)) => {
                    observer.event(&TurnEvent::RoundFailed(&error));
                    failure = Some(error);
                }
                sent => return (sent, native),
            }
        }
    }

    /// Send one request of `blocks`, and give each event of the reply to `observer`. If [`retry::decide`] permits a
    /// retry, the driver waits with the caller's timer, then sends the same encoded bytes.
    async fn send(
        &self,
        encoder: &mut Encoder,
        blocks: &[Block],
        tools: &[ToolDefinition],
        plan: &RoundPlan,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> Sent {
        let target = plan.target.as_ref().unwrap_or(self.target);
        let settings = plan.settings.as_ref().unwrap_or(self.settings);
        let mut request = Request::new(blocks).tools(tools).settings(settings);
        if let Some(blob_store) = self.blob_store {
            request = request.blobs(blob_store);
        }
        let encoded = match encoder.encode(target, request) {
            Ok(encoded) => encoded,
            Err(error) => return Sent::Finished(Err(error.into())),
        };
        // One waiter serves the whole request, so a stream event costs no new registration.
        let mut cancelled = pin!(cancellation_token.cancelled());
        let mut number = 1;
        loop {
            let opened = race(
                Reply::open(self.transport, &encoded, Options::default()),
                cancelled.as_mut(),
            );
            let Raced::Done(mut reply) = opened.await else {
                return Sent::Cancelled(Vec::new());
            };

            // No await comes between an event and its delivery, so a cancel cannot lose an event.
            loop {
                match race(reply.next(), cancelled.as_mut()).await {
                    Raced::Done(Some(Ok(event))) => observer.event(&TurnEvent::Model(event)),
                    Raced::Done(_) => break,
                    Raced::Cancelled => return Sent::Cancelled(reply.cancel()),
                }
            }

            let error = match reply.finish().await {
                Ok(response) => return Sent::Finished(Ok(response)),
                Err(error) => error,
            };
            // The reply sets `output_seen` when it yields a showable event, and the observer gets that event at once.
            let attempt = Attempt {
                failure: error.cause,
                info: &error.info,
                output_shown: error.info.output_seen,
                number,
            };

            let Some(delay) = retry::decide(retry::Policy::default(), &attempt, fastrand::f64()) else {
                return Sent::Finished(Err(error.into()));
            };

            let after = Duration::from_millis(delay);
            observer.event(&TurnEvent::RetryScheduled { after, error: &error });
            if let Raced::Cancelled = race(self.timer.sleep(after), cancelled.as_mut()).await {
                return Sent::Cancelled(Vec::new());
            }
            number += 1;
        }
    }
}

/// One assistant turn. It does nothing until [`Turn::run`].
#[must_use = "a turn does nothing until the caller runs it"]
pub struct Turn<'a> {
    driver: Driver<'a>,
    history: &'a mut Vec<Block>,
    input: Vec<Block>,
    observer: Option<&'a dyn Observer>,
    cancellation_token: CancellationToken,
}

impl std::fmt::Debug for Turn<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Turn")
            .field("driver", &self.driver)
            .field("input", &self.input)
            .finish_non_exhaustive()
    }
}

impl<'a> Turn<'a> {
    /// Give each event of the turn to `observer`. A turn without an observer drops its events.
    pub fn observer(self, observer: &'a dyn Observer) -> Self {
        Turn {
            observer: Some(observer),
            ..self
        }
    }

    /// Stop the turn when `cancellation_token` is cancelled. A cancelled token cannot be reset, so use a new token for
    /// each turn. A turn without a token runs until it ends.
    pub fn cancellation_token(self, cancellation_token: CancellationToken) -> Self {
        Turn {
            cancellation_token,
            ..self
        }
    }

    /// Run the turn until it ends. A cancel interrupts each wait that the driver owns. A tool that runs gets the token,
    /// and the driver waits for its return. A tool call that did not start does not run.
    ///
    /// # Errors
    ///
    /// Returns an [`yuke_ai::Error`] when a request cannot be encoded, or when its last attempt fails. The history keeps the
    /// input and no answer.
    pub async fn run(self) -> Result<Outcome, yuke_ai::Error> {
        let Turn {
            driver,
            history,
            input,
            observer,
            cancellation_token,
        } = self;
        let mut conversation = Conversation::new(history);
        let ignore = |_: &TurnEvent<'_>| {};
        let observer: &dyn Observer = match observer {
            Some(observer) => observer,
            None => &ignore,
        };
        let declared = Declared::new(driver.toolset);
        // The calls of a round use the kind of search of the target of that round.
        let mut native = false;
        // The encoder lives for one turn. Its first request encodes the whole history, and each later request of the
        // turn encodes only the changed elements.
        let mut encoder = Encoder::new();

        let mut action = conversation.start(input);
        loop {
            match action {
                Action::Send => {
                    let sent;
                    (sent, native) = driver
                        .send_round(
                            &mut conversation,
                            &mut encoder,
                            &declared,
                            observer,
                            &cancellation_token,
                        )
                        .await;
                    action = match sent {
                        Sent::Finished(result) => conversation.model_finished(result),
                        Sent::Cancelled(partial) => conversation.model_cancelled(partial),
                    };
                }

                Action::CallTools(calls) => {
                    // A closure kept across an await makes the turn future lose `Send`, so the calls resolve first.
                    let resolved: Vec<Resolved<'_>> = calls.into_iter().map(|call| driver.resolve(call)).collect();
                    let mut resolved = resolved.into_iter().peekable();
                    let mut results = Vec::new();
                    // Consecutive parallel calls form one group. A serial call forms a group of its own.
                    while let Some(first) = resolved.next() {
                        let parallel = driver.concurrency(&first) == Concurrency::Parallel;
                        let mut group = vec![first];
                        while parallel
                            && let Some(next) =
                                resolved.next_if(|next| driver.concurrency(next) == Concurrency::Parallel)
                        {
                            group.push(next);
                        }
                        results.extend(driver.call_group(group, native, observer, &cancellation_token).await);
                    }

                    action = if cancellation_token.is_cancelled() {
                        conversation.tools_cancelled(results)
                    } else {
                        conversation.tools_finished(results)
                    };
                }

                Action::AfterRound { history, finish_reason } => {
                    let decided = driver.hooks.after_round(history, finish_reason);
                    action = match race(decided, pin!(cancellation_token.cancelled())).await {
                        // The driver takes the input only when the turn goes on, so a stop or a cancel leaves it.
                        Raced::Done(RoundDecision::Proceed) => conversation.proceed(driver.inbox.take()),
                        Raced::Done(RoundDecision::Continue(more)) => {
                            // Input of the user comes first. The hook gets another call after the next round.
                            let input = driver.inbox.take();
                            conversation.continue_turn(if input.is_empty() { more } else { input })
                        }
                        Raced::Done(RoundDecision::Stop) => conversation.stop(),
                        Raced::Cancelled => conversation.cancel(),
                    };
                }

                Action::Done(result) => return result,
            }
        }
    }
}

/// A tool call after the bridge and the JSON check.
struct Resolved<'c> {
    /// The call that the hooks and the observer see.
    call: Cow<'c, ToolCall>,

    /// The result of a call that the bridge refuses or that has invalid JSON. After [`Hooks::before_tool`], also the
    /// result of a call that the hooks block or that a cancel stops.
    result: Option<ToolResult>,
}

/// How a request ended.
enum Sent {
    /// The request finished with this result.
    Finished(Result<Response, yuke_ai::Error>),
    /// A cancel stopped the request. The output that the reply kept is here.
    Cancelled(Vec<Partial>),
}

/// How a wait ended.
enum Raced<T> {
    /// The work finished first.
    Done(T),
    /// The cancel came first.
    Cancelled,
}

/// Wait for `work`, unless `cancelled` ends first. Each poll checks `cancelled` before `work`, and the drop of `work`
/// stops it.
async fn race<T>(work: impl Future<Output = T>, mut cancelled: Pin<&mut impl Future<Output = ()>>) -> Raced<T> {
    let mut work = pin!(work);
    poll_fn(|context| {
        if cancelled.as_mut().poll(context).is_ready() {
            return Poll::Ready(Raced::Cancelled);
        }
        work.as_mut().poll(context).map(Raced::Done)
    })
    .await
}
