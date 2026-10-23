//! The standard driver. It carries out each [`Action`] of a [`TurnState`] over a caller's transport.

use std::borrow::Cow;
use std::fmt;
use std::future::poll_fn;
use std::num::NonZeroU32;
use std::pin::pin;
use std::sync::{Mutex, PoisonError};
use std::task::Poll;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::future::join_all;
use tokio_util::sync::CancellationToken;
use yuke_ai::retry;
use yuke_ai::transport::Transport;
use yuke_ai::{
    AttemptError, BlobStore, Block, Encoder, Options, Origin, OriginRef, Partial, Reply, Request, Response,
    ResponseLimits, SEARCH_TOOL_NAME, Settings, Target, ToolCall, ToolResult,
};

use crate::hooks::{Hooks, NoHooks, RoundDecision, RoundStart, ToolDecision};
use crate::model::{Model, RoundError};
use crate::search::{self, Declared, SearchMode};
use crate::tool::{Concurrency, TOOL_CALL_NAME, ToolContext, Toolset};
use crate::turn_state::{Action, CANCELLED_REASON, Commit, Outcome, TurnState, not_executed};

/// One fact of a turn, for an observer. It borrows turn data until the observer returns, so an observer copies the
/// data that it keeps.
#[derive(Debug)]
pub enum TurnEvent<'a> {
    /// A provider attempt starts. Its block ids start at zero.
    ResponseStarted,

    /// A provider attempt failed. None of its blocks enter the context.
    ResponseFailed(&'a AttemptError),

    /// A cancel ends the provider attempt. The event carries the partial blocks that enter the context.
    ResponseCancelled {
        /// The partial blocks that enter the context, with their original block ids, in start order. Reasoning blocks
        /// do not enter the context.
        blocks: &'a [yuke_ai::PartialBlock],
    },

    /// One event of a model reply, in source order.
    Model(yuke_ai::Event<'a>),

    /// The driver handles this call. This event comes before [`Hooks::before_tool`], so a blocked call also has it.
    ToolStarted {
        /// The zero-based block index of the call in its answer commit.
        block_index: usize,
        /// The resolved call, after the deferred-tool bridge.
        call: &'a ToolCall,
    },

    /// A running call showed live output through [`ToolContext::output`]. The model never sees it.
    ToolOutput {
        /// The zero-based block index of the call in its answer commit.
        block_index: usize,

        /// The output text.
        text: &'a str,
    },

    /// A call finished with this result. The approved calls of one parallel group finish in any order.
    ToolFinished {
        /// The zero-based block index of the call in its answer commit.
        block_index: usize,
        /// The result of the call.
        result: &'a ToolResult,
    },

    /// A round failed after its retries. The model events of the round came before it, and the context keeps none of
    /// them. The driver then asks [`Hooks::retry_round`] whether the round runs again.
    RoundFailed(&'a RoundError),

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
#[async_trait]
pub trait Inbox: Send + Sync {
    /// Remove and return the input that arrived since the last call, or an empty `Vec` when none arrived. Do not wait
    /// for input.
    ///
    /// # Errors
    ///
    /// Returns why the inbox cannot give its input. The turn then ends with [`RoundError::Inbox`].
    async fn take(&self) -> Result<Vec<Block>, Box<dyn std::error::Error + Send + Sync>>;
}

// A locked `Vec` is the simplest inbox: one task pushes, and the driver takes.
#[async_trait]
impl Inbox for Mutex<Vec<Block>> {
    async fn take(&self) -> Result<Vec<Block>, Box<dyn std::error::Error + Send + Sync>> {
        // A panic of another holder leaves a valid `Vec`, so its input stays usable.
        Ok(std::mem::take(
            &mut *self.lock().unwrap_or_else(PoisonError::into_inner),
        ))
    }
}

/// Saves the commits of each turn. The driver awaits each commit before the turn goes on, and a cancel does not
/// stop a commit. A caller that saves nothing sets no journal.
#[async_trait]
pub trait Journal: Send + Sync {
    /// Save `commit`. The driver sends the commits of a turn in order. The context that a turn starts with
    /// counts as saved.
    ///
    /// # Errors
    ///
    /// Returns the error of the save. The turn then ends with [`TurnError::Commit`].
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn std::error::Error + Send + Sync>>;
}

/// The inbox of a driver without an inbox. It never holds input.
struct NoInput;

#[async_trait]
impl Inbox for NoInput {
    async fn take(&self) -> Result<Vec<Block>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(Vec::new())
    }
}

/// The settings of the turns against one target. A driver borrows each value and keeps no state. Make a new driver
/// when a setting changes.
#[derive(Clone, Copy)]
pub struct Driver<'a> {
    transport: &'a dyn Transport,
    model: &'a Model,
    timer: &'a dyn Timer,
    toolset: &'a Toolset,
    hooks: &'a dyn Hooks,
    inbox: &'a dyn Inbox,
    journal: Option<&'a dyn Journal>,
    system: &'a str,
    settings: &'a Settings,
    session_id: Option<&'a str>,
    blob_store: Option<&'a dyn BlobStore>,
    retry_policy: retry::Policy,
    response_limits: ResponseLimits,
}

/// The toolset of a driver without tools.
static NO_TOOLS: Toolset = Toolset::new();

/// The settings of a driver without settings. Each value stays at its endpoint default.
static NO_SETTINGS: Settings = Settings::new();

impl fmt::Debug for Driver<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Driver")
            .field("model", &self.model)
            .field("toolset", &self.toolset)
            .finish_non_exhaustive()
    }
}

impl<'a> Driver<'a> {
    /// A driver that sends to `model` through `transport`, and waits with `timer` before it sends an attempt again. It
    /// offers no tools, and it takes no input during a turn. Its hooks run each call and continue each round. They end
    /// each turn when the model ends it.
    pub fn new(transport: &'a dyn Transport, model: &'a Model, timer: &'a dyn Timer) -> Self {
        Driver {
            transport,
            model,
            timer,
            toolset: &NO_TOOLS,
            hooks: &NoHooks,
            inbox: &NoInput,
            journal: None,
            system: "",
            settings: &NO_SETTINGS,
            session_id: None,
            blob_store: None,
            retry_policy: retry::Policy::default(),
            response_limits: ResponseLimits::default(),
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

    /// Give each commit of a turn to `journal`, and await the result of each save.
    #[must_use]
    pub fn journal(self, journal: &'a dyn Journal) -> Self {
        Driver {
            journal: Some(journal),
            ..self
        }
    }

    /// Send each request with the system prompt `system`. With an empty prompt, a request carries no system prompt.
    #[must_use]
    pub fn system(self, system: &'a str) -> Self {
        Driver { system, ..self }
    }

    /// Send each request with `settings`, unless a [`RoundPlan`](crate::RoundPlan) gives other settings for its round.
    #[must_use]
    pub fn settings(self, settings: &'a Settings) -> Self {
        Driver { settings, ..self }
    }

    /// Send the session id `session_id` with each request, for routing and the Responses cache key. See
    /// [`Request::session_id`].
    #[must_use]
    pub fn session_id(self, session_id: &'a str) -> Self {
        Driver {
            session_id: Some(session_id),
            ..self
        }
    }

    /// Read the media of each request from `blob_store`. Without a store, a request with media fails to encode.
    #[must_use]
    pub fn blobs(self, blob_store: &'a dyn BlobStore) -> Self {
        Driver {
            blob_store: Some(blob_store),
            ..self
        }
    }

    /// Set the attempt and delay bounds of each request. The default is [`retry::Policy::default`].
    #[must_use]
    pub fn retry_policy(self, retry_policy: retry::Policy) -> Self {
        Driver { retry_policy, ..self }
    }

    /// Set the size bounds of each response: body bytes, event bytes, tool arguments, blocks, and error body. The
    /// default is [`ResponseLimits::default`].
    #[must_use]
    pub fn response_limits(self, response_limits: ResponseLimits) -> Self {
        Driver {
            response_limits,
            ..self
        }
    }

    /// Save `commit` in the journal. The save does not race the cancel. A failed save ends the turn.
    async fn save(&self, commit: &Commit<'_>) -> Result<(), TurnError> {
        match self.journal {
            Some(journal) => journal.commit(commit).await.map_err(TurnError::Commit),
            None => Ok(()),
        }
    }

    /// The call that `call` runs, and its result when it runs nothing. The model calls a deferred tool through the
    /// bridge, but the hooks and the observer see the real call.
    fn resolve<'c>(&self, block_index: usize, call: &'c ToolCall) -> Resolved<'c> {
        let call = if call.name == TOOL_CALL_NAME && self.toolset.deferred().next().is_some() {
            match search::unwrap_call(call) {
                Ok(real) => Cow::Owned(real),
                Err(refused) => {
                    return Resolved {
                        block_index,
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
        Resolved {
            block_index,
            call,
            result,
        }
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
        search_mode: SearchMode,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> Vec<ToolResult> {
        // After this loop, a call without a result is a call that the hooks let run.
        for Resolved {
            block_index,
            call,
            result,
        } in &mut group
        {
            observer.event(&TurnEvent::ToolStarted {
                block_index: *block_index,
                call,
            });
            if result.is_none() {
                *result = match race(self.hooks.before_tool(call), cancellation_token.cancelled()).await {
                    Raced::Done(ToolDecision::Run) => None,
                    Raced::Done(ToolDecision::Block(reason)) => Some(ToolResult::error(&call.call_id, reason)),
                    Raced::Cancelled => Some(not_executed(call, CANCELLED_REASON)),
                };
            }
            if let Some(result) = result {
                observer.event(&TurnEvent::ToolFinished {
                    block_index: *block_index,
                    result,
                });
            }
        }

        let calls = group.into_iter().map(
            |Resolved {
                 block_index,
                 call,
                 result,
             }| async move {
                match result {
                    Some(result) => result,
                    None => {
                        self.run_call(block_index, &call, search_mode, observer, cancellation_token)
                            .await
                    }
                }
            },
        );
        join_all(calls).await
    }

    /// Run an approved `call`, then ask [`Hooks::after_tool`], and return its result. A cancel before the start runs
    /// nothing.
    async fn run_call(
        &self,
        block_index: usize,
        call: &ToolCall,
        search_mode: SearchMode,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> ToolResult {
        // A cancel during the hooks of the group comes before this call starts, so the call does not start.
        let result = if cancellation_token.is_cancelled() {
            not_executed(call, CANCELLED_REASON)
        } else if self.is_search(call) {
            let result = search::search(self.toolset, call, search_mode);
            self.after_tool(call, result, cancellation_token).await
        } else {
            let context = ToolContext::new(block_index, call, cancellation_token, observer);
            let result = self.toolset.call(call, &context).await;
            self.after_tool(call, result, cancellation_token).await
        };
        observer.event(&TurnEvent::ToolFinished {
            block_index,
            result: &result,
        });
        result
    }

    /// Ask [`Hooks::after_tool`] for a replacement of `result`. A cancel keeps `result`.
    async fn after_tool(
        &self,
        call: &ToolCall,
        result: ToolResult,
        cancellation_token: &CancellationToken,
    ) -> ToolResult {
        match race(self.hooks.after_tool(call, &result), cancellation_token.cancelled()).await {
            // The result answers this call, so a replacement keeps its call id.
            Raced::Done(Some(replacement)) => ToolResult {
                call_id: result.call_id,
                ..replacement
            },
            Raced::Done(None) | Raced::Cancelled => result,
        }
    }

    /// The turn of `input` on `context`. [`Turn::run`] runs it and adds the blocks of the turn to `context`.
    pub fn turn<'t>(&self, context: &'t mut Vec<Block>, input: Vec<Block>) -> Turn<'t>
    where
        'a: 't,
    {
        Turn {
            driver: *self,
            context,
            input,
            observer: None,
            cancellation_token: CancellationToken::new(),
            input_tokens: None,
        }
    }

    /// Send the request of one round with the plan of [`Hooks::before_round`]. After a failure, [`Hooks::retry_round`]
    /// decides whether the round runs again.
    async fn send_round(
        &self,
        turn_state: &mut TurnState<'_>,
        encoder: &mut Encoder,
        declared: &Declared<'_>,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> Result<Round, TurnError> {
        let cancelled = || Ok(Round::new(Sent::Cancelled(Vec::new()), &self.model.target));
        let failed = |error| Ok(Round::new(Sent::Finished(Err(error)), &self.model.target));
        let round = RoundStart {
            context: turn_state.context(),
            settings: self.settings,
            window: self.model.context_window,
            input_tokens: turn_state.input_tokens(),
        };
        let mut plan = match race(self.hooks.before_round(&round), cancellation_token.cancelled()).await {
            Raced::Done(Ok(plan)) => plan,
            Raced::Done(Err(error)) => return failed(RoundError::Hook { error, after: None }),
            Raced::Cancelled => return cancelled(),
        };
        loop {
            if let Some(replace) = plan.replace.take() {
                self.save(&turn_state.replace(replace)).await?;
            }
            let model = plan.model.as_ref().unwrap_or(self.model);
            let settings = plan.settings.as_ref().unwrap_or(self.settings);
            let tools = declared.tools(SearchMode::for_target(&model.target));
            let mut request = Request::new(turn_state.context())
                .system(self.system)
                .tools(tools)
                .settings(settings);
            if let Some(session_id) = self.session_id {
                request = request.session_id(session_id);
            }
            let error = match self.send(encoder, request, model, observer, cancellation_token).await {
                Sent::Finished(Err(error)) => error,
                sent => return Ok(Round::new(sent, &model.target)),
            };
            observer.event(&TurnEvent::RoundFailed(&error));
            let failed_round = RoundStart {
                context: turn_state.context(),
                settings,
                window: model.context_window,
                input_tokens: turn_state.input_tokens(),
            };
            let retry = race(
                self.hooks.retry_round(&failed_round, &error),
                cancellation_token.cancelled(),
            )
            .await;
            plan = match retry {
                Raced::Done(Ok(Some(plan))) => plan,
                Raced::Done(Ok(None)) => return Ok(Round::new(Sent::Finished(Err(error)), &model.target)),
                Raced::Done(Err(hook)) => {
                    return failed(RoundError::Hook {
                        error: hook,
                        after: Some(Box::new(error)),
                    });
                }
                Raced::Cancelled => return cancelled(),
            };
        }
    }

    /// Send `request` to `model`, and give each event of the reply to `observer`. If [`retry::decide`] permits a retry,
    /// wait with the caller's timer. Then send the request again with the credential of that moment.
    async fn send(
        &self,
        encoder: &mut Encoder,
        mut request: Request<'_>,
        model: &Model,
        observer: &dyn Observer,
        cancellation_token: &CancellationToken,
    ) -> Sent {
        if let Some(blob_store) = self.blob_store {
            request = request.blobs(blob_store);
        }
        // One waiter serves the whole request, so a stream event costs no new registration.
        let mut cancelled = pin!(cancellation_token.cancelled());
        let mut number = NonZeroU32::MIN;
        loop {
            let credential = match race(model.source.credential(), cancelled.as_mut()).await {
                Raced::Done(Ok(credential)) => credential,
                Raced::Done(Err(error)) => return Sent::Finished(Err(RoundError::Credential(error))),
                Raced::Cancelled => return Sent::Cancelled(Vec::new()),
            };
            // A retry encodes again with its own credential. The context is unchanged, so no element encodes again.
            let encoded = match encoder.encode(&model.target, &credential, request) {
                Ok(encoded) => encoded,
                Err(error) => return Sent::Finished(Err(yuke_ai::Error::from(error).into())),
            };
            observer.event(&TurnEvent::ResponseStarted);
            let opened = race(
                Reply::open(
                    self.transport,
                    &encoded,
                    Options {
                        limits: self.response_limits,
                        deadline: None,
                    },
                ),
                cancelled.as_mut(),
            );
            let Raced::Done(mut reply) = opened.await else {
                observer.event(&TurnEvent::ResponseCancelled { blocks: &[] });
                return Sent::Cancelled(Vec::new());
            };

            // No await comes between an event and its delivery, so a cancel cannot lose an event.
            loop {
                match race(reply.next(), cancelled.as_mut()).await {
                    Raced::Done(Some(Ok(event))) => observer.event(&TurnEvent::Model(event)),
                    Raced::Done(_) => break,
                    Raced::Cancelled => {
                        let mut blocks = reply.cancel();
                        // Cancelled reasoning has no provider replay state, so the context omits it.
                        blocks.retain(|block| !matches!(block.content, Partial::Reasoning(_)));
                        observer.event(&TurnEvent::ResponseCancelled { blocks: &blocks });
                        return Sent::Cancelled(blocks.into_iter().map(|block| block.content).collect());
                    }
                }
            }

            let error = match reply.finish().await {
                Ok(response) => return Sent::Finished(Ok(response)),
                Err(error) => error,
            };
            observer.event(&TurnEvent::ResponseFailed(&error));
            // The reply sets `output_seen` when it yields a showable event, and the observer gets that event at once.
            let Some(delay) = retry::decide(self.retry_policy, &error, number, fastrand::f64()) else {
                return Sent::Finished(Err(yuke_ai::Error::from(error).into()));
            };

            observer.event(&TurnEvent::RetryScheduled {
                after: delay,
                error: &error,
            });
            if let Raced::Cancelled = race(self.timer.sleep(delay), cancelled.as_mut()).await {
                return Sent::Cancelled(Vec::new());
            }
            number = number.saturating_add(1);
        }
    }
}

/// One assistant turn. It does nothing until [`Turn::run`].
#[must_use = "a turn does nothing until the caller runs it"]
pub struct Turn<'a> {
    driver: Driver<'a>,
    context: &'a mut Vec<Block>,
    input: Vec<Block>,
    observer: Option<&'a dyn Observer>,
    cancellation_token: CancellationToken,
    input_tokens: Option<u64>,
}

impl fmt::Debug for Turn<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
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

    /// Start the turn with `input_tokens`, the input tokens of the newest answer before it. The first round gives it to
    /// [`Hooks::before_round`].
    pub fn input_tokens(self, input_tokens: Option<u64>) -> Self {
        Turn { input_tokens, ..self }
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
    /// Returns [`TurnError::Round`] when a round fails and no hook sends it again, or when a round hook fails. The
    /// context keeps each block from before the failure, such as the answer before a failed `after_round`. Returns
    /// [`TurnError::Commit`] when the journal fails to save a commit.
    pub async fn run(self) -> Result<Outcome, TurnError> {
        let Turn {
            driver,
            context,
            input,
            observer,
            cancellation_token,
            input_tokens,
        } = self;
        let mut turn_state = TurnState::new(context, input_tokens);
        let ignore = |_: &TurnEvent<'_>| {};
        let observer: &dyn Observer = match observer {
            Some(observer) => observer,
            None => &ignore,
        };
        let declared = Declared::new(driver.toolset);
        // The calls of a round use the kind of search of the target of that round.
        let mut search_mode = SearchMode::Bridge;
        // The encoder lives for one turn. Its first request encodes the whole context, and each later request of the
        // turn encodes only the changed elements.
        let mut encoder = Encoder::new();

        let mut action = turn_state.send(input);
        loop {
            match action {
                Action::Send(commit) => {
                    if let Some(commit) = commit {
                        driver.save(&commit).await?;
                    }
                    let round = driver
                        .send_round(&mut turn_state, &mut encoder, &declared, observer, &cancellation_token)
                        .await?;
                    search_mode = round.search_mode;
                    action = match round.sent {
                        Sent::Finished(Ok(response)) => turn_state.model_finished(response.completion, round.origin),
                        Sent::Finished(Err(error)) => turn_state.fail(error),
                        Sent::Cancelled(partial) => turn_state.model_cancelled(partial),
                    };
                }

                Action::CallTools(commit) => {
                    driver.save(&commit).await?;
                    // A closure kept across an await makes the turn future lose `Send`, so the calls resolve first.
                    let resolved: Vec<Resolved<'_>> = commit
                        .blocks
                        .iter()
                        .enumerate()
                        .filter_map(|(block_index, block)| match block {
                            Block::ToolCall(call) => Some(driver.resolve(block_index, call)),
                            _ => None,
                        })
                        .collect();
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
                        results.extend(
                            driver
                                .call_group(group, search_mode, observer, &cancellation_token)
                                .await,
                        );
                    }

                    action = if cancellation_token.is_cancelled() {
                        turn_state.tools_cancelled(results)
                    } else {
                        turn_state.tools_finished(results)
                    };
                }

                Action::AfterRound {
                    context,
                    finish_reason,
                    commit,
                } => {
                    driver.save(&commit).await?;
                    let decided = driver.hooks.after_round(context, finish_reason);
                    action = match race(decided, cancellation_token.cancelled()).await {
                        // The driver takes the input only when the turn goes on, so a stop or a cancel leaves it.
                        Raced::Done(Ok(RoundDecision::Proceed)) => match driver.inbox.take().await {
                            Ok(input) => turn_state.proceed(input),
                            Err(error) => turn_state.fail(RoundError::Inbox(error)),
                        },
                        Raced::Done(Ok(RoundDecision::Stop)) => turn_state.stop(),
                        Raced::Done(Err(error)) => turn_state.fail(RoundError::Hook { error, after: None }),
                        Raced::Cancelled => turn_state.cancel(),
                    };
                }

                Action::Done { tail, result } => {
                    driver.save(&Commit::end(tail, result.as_ref())).await?;
                    return result.map_err(TurnError::Round);
                }
            }
        }
    }
}

/// A tool call after the bridge and the JSON check.
struct Resolved<'c> {
    /// The call's block index in the answer commit.
    block_index: usize,

    /// The call that the hooks and the observer see.
    call: Cow<'c, ToolCall>,

    /// The result of a call that the bridge refuses or that has invalid JSON. After [`Hooks::before_tool`], also the
    /// result of a call that the hooks block or that a cancel stops.
    result: Option<ToolResult>,
}

/// Why a turn failed.
#[derive(Debug)]
pub enum TurnError {
    /// A round failed, and no hook sent it again. The context keeps the blocks from before the failure.
    Round(RoundError),

    /// The journal did not confirm a commit. It can still have saved the commit. The context can hold blocks after the
    /// last confirmed commit, so the caller loads the context again from its store.
    Commit(Box<dyn std::error::Error + Send + Sync>),
}

impl fmt::Display for TurnError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Round(error) => fmt::Display::fmt(error, f),
            // The text names no cause, because `source` returns it.
            Self::Commit(_) => f.write_str("the journal failed to save the turn"),
        }
    }
}

impl std::error::Error for TurnError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            // The text is the text of the inner error, so the source is the source of the inner error.
            Self::Round(error) => error.source(),
            Self::Commit(error) => Some(error.as_ref()),
        }
    }
}

/// The request of one round, and its target.
struct Round {
    /// How the request ended.
    sent: Sent,
    /// The search mode for deferred tools.
    search_mode: SearchMode,
    /// The model and host of the target.
    origin: Origin,
}

impl Round {
    fn new(sent: Sent, target: &Target) -> Self {
        Round {
            sent,
            search_mode: SearchMode::for_target(target),
            origin: Origin::from(OriginRef::of(target)),
        }
    }
}

/// How a request ended.
enum Sent {
    /// The request finished with this result.
    Finished(Result<Response, RoundError>),
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
async fn race<T>(work: impl Future<Output = T>, cancelled: impl Future<Output = ()>) -> Raced<T> {
    let mut work = pin!(work);
    let mut cancelled = pin!(cancelled);
    poll_fn(|context| {
        if cancelled.as_mut().poll(context).is_ready() {
            return Poll::Ready(Raced::Cancelled);
        }
        work.as_mut().poll(context).map(Raced::Done)
    })
    .await
}
