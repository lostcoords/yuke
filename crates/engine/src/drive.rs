//! The standard driver. It carries out each [`Action`] of a [`Conversation`] over a caller's transport.

use std::time::Duration;

use ai::retry::{self, Attempt};
use ai::transport::Transport;
use ai::{AttemptError, Block, Encoder, Options, Reply, Request, Response, Target, ToolCall, ToolResult};
use async_trait::async_trait;

use crate::conversation::{Action, Conversation, Inbox, Outcome};
use crate::hooks::{Hooks, NoHooks, RoundDecision, ToolDecision};
use crate::tool::Toolset;

/// One fact of a turn, for an observer. It borrows turn data until the observer returns, so an observer copies the
/// data that it keeps.
#[derive(Debug)]
#[non_exhaustive]
pub enum TurnEvent<'a> {
    /// One event of a model reply, in source order.
    Model(ai::Event<'a>),

    /// The driver handles this call. This event comes before [`Hooks::before_tool`], so a blocked call also has it.
    ToolStarted(&'a ToolCall),

    /// A call finished with this result.
    ToolFinished(&'a ToolResult),

    /// An attempt failed, and the driver plans to send the same request again after `after`.
    RetryScheduled {
        /// The wait before the next attempt.
        after: Duration,
        /// The failed attempt.
        error: &'a AttemptError,
    },
}

/// Receives the events of a turn. The driver calls it on the turn's task, so it copies or records the data that it
/// needs, and it returns without a wait. A closure that takes a `&TurnEvent` is an observer.
pub trait Observer: Send {
    /// Receive one event.
    fn event(&mut self, event: &TurnEvent<'_>);
}

// A closure or a function is an observer, so a quick observer needs no struct.
impl<F: FnMut(&TurnEvent<'_>) + Send> Observer for F {
    fn event(&mut self, event: &TurnEvent<'_>) {
        self(event);
    }
}

/// Makes waits. The caller supplies it, so the engine needs no async runtime of its own.
#[async_trait]
pub trait Timer: Send + Sync {
    /// Return after `duration`.
    async fn sleep(&self, duration: Duration);
}

/// Run conversations against one target. The driver keeps one encoder, so a later request re-encodes only the
/// changed elements. Use one driver for each conversation.
pub struct Driver<'a> {
    transport: &'a dyn Transport,
    target: &'a Target,
    timer: &'a dyn Timer,
    toolset: &'a Toolset,
    hooks: &'a dyn Hooks,
    encoder: Encoder,
}

/// The toolset of a driver without tools.
static NO_TOOLS: Toolset = Toolset::new();

impl std::fmt::Debug for Driver<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Driver")
            .field("target", &self.target)
            .field("toolset", &self.toolset)
            .finish_non_exhaustive()
    }
}

impl<'a> Driver<'a> {
    /// A driver that sends to `target` through `transport`, and waits with `timer` before a retry. It offers no tools.
    /// Its hooks run each call and continue each turn.
    pub fn new(transport: &'a dyn Transport, target: &'a Target, timer: &'a dyn Timer) -> Self {
        Driver {
            transport,
            target,
            timer,
            toolset: &NO_TOOLS,
            hooks: &NoHooks,
            encoder: Encoder::new(),
        }
    }

    /// Offer the tools of `toolset` to the model.
    #[must_use]
    pub fn toolset(self, toolset: &'a Toolset) -> Self {
        Driver { toolset, ..self }
    }

    /// Ask `hooks` before each tool call and after each round.
    #[must_use]
    pub fn hooks(self, hooks: &'a dyn Hooks) -> Self {
        Driver { hooks, ..self }
    }

    /// Run the turn of `input` on `conversation` until it ends. Give each event to `observer`, and take new input
    /// from `inbox` between rounds.
    pub async fn run(
        &mut self,
        conversation: &mut Conversation,
        input: Vec<Block>,
        observer: &mut dyn Observer,
        inbox: &mut dyn Inbox,
    ) -> Outcome {
        let mut action = conversation.start(input);
        loop {
            match action {
                Action::Send(blocks) => {
                    let result = self.send(blocks, observer).await;
                    action = conversation.model_finished(result);
                }

                Action::CallTools(calls) => {
                    let mut results = Vec::new();
                    for call in calls.iter() {
                        observer.event(&TurnEvent::ToolStarted(call));
                        let result = match self.hooks.before_tool(call).await {
                            ToolDecision::Run => self.toolset.call(call).await,
                            ToolDecision::Block(reason) => ToolResult::error(&call.call_id, reason),
                        };
                        observer.event(&TurnEvent::ToolFinished(&result));
                        results.push(result);
                    }
                    action = conversation.tools_finished(results);
                }

                Action::AfterRound(history) => {
                    action = match self.hooks.after_round(history).await {
                        RoundDecision::Proceed => conversation.proceed(inbox),
                        RoundDecision::Stop => conversation.stop(),
                    };
                }

                Action::Done(outcome) => return outcome,
            }
        }
    }

    /// Send one request of `blocks`, and give each event of the reply to `observer`. If [`retry::decide`] permits a
    /// retry, the driver waits with the caller's timer, then sends the same encoded bytes.
    async fn send(&mut self, blocks: &[Block], observer: &mut dyn Observer) -> Result<Response, ai::Error> {
        let request = Request::new(blocks).tools(self.toolset.definitions());
        let encoded = self.encoder.encode(self.target, request)?;
        let mut number = 1;
        loop {
            let mut reply = Reply::open(self.transport, &encoded, Options::default()).await;

            // No await comes between an event and its delivery, so a cancel cannot lose an event.
            while let Some(Ok(event)) = reply.next().await {
                observer.event(&TurnEvent::Model(event));
            }

            let error = match reply.finish().await {
                Ok(response) => return Ok(response),
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
                return Err(error.into());
            };

            let after = Duration::from_millis(delay);
            observer.event(&TurnEvent::RetryScheduled { after, error: &error });
            self.timer.sleep(after).await;
            number += 1;
        }
    }
}
