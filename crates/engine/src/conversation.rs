//! The decisions of one conversation. A [`Conversation`] does no I/O, reads no clock, and never awaits. Each call
//! that feeds it a fact returns the next [`Action`].

use ai::{Block, FinishReason, Response, ToolCall, ToolResult};

/// The history of one conversation.
#[derive(Debug, Default)]
pub struct Conversation {
    history: Vec<Block>,

    /// The finish reason of the last answer, when that answer ends the turn without new input. It is `None` while
    /// the turn continues.
    turn_end: Option<FinishReason>,
}

/// The next thing the caller does for a turn.
#[derive(Debug)]
#[must_use = "the turn continues only when the caller carries out the action"]
pub enum Action<'a> {
    /// Send a request of these blocks, then give the result to [`Conversation::model_finished`]. The blocks are the
    /// whole history.
    Send(&'a [Block]),

    /// Run these calls in order, then give the results to [`Conversation::tools_finished`] in the same order.
    CallTools(ToolCalls<'a>),

    /// A round ended, and its answer and tool results are in the history. Call [`Conversation::proceed`] or
    /// [`Conversation::stop`]. The blocks are the whole history.
    AfterRound(&'a [Block]),

    /// The turn ended.
    Done(Outcome),
}

/// The tool calls of one answer. It borrows the blocks of the answer, so the calls are not copied.
#[derive(Debug)]
pub struct ToolCalls<'a> {
    blocks: &'a [Block],
}

impl<'a> ToolCalls<'a> {
    /// The calls, in answer order.
    pub fn iter(&self) -> impl Iterator<Item = &'a ToolCall> + use<'a> {
        self.blocks.iter().filter_map(|block| match block {
            Block::ToolCall(call) => Some(call),
            _ => None,
        })
    }
}

/// How a turn ended.
#[derive(Debug, Clone)]
#[must_use = "a turn can fail, so check the outcome"]
pub enum Outcome {
    /// The turn ended with an answer of the model, and the answer joined the history. A filter or a refusal answer
    /// can hold calls that did not run.
    Completed {
        /// The reason in the closed set.
        finish_reason: FinishReason,
    },

    /// The caller stopped the turn after a round that asked for another request. The history ends with the tool
    /// results of that round.
    Stopped,

    /// The request failed. The history keeps the input and no answer.
    Failed(ai::Error),
}

/// Holds the input that arrives during a turn. [`Conversation::proceed`] takes it after each round. Thus input never
/// changes a request in flight.
pub trait Inbox: Send {
    /// Remove and return the input that arrived since the last call. Return at once, with an empty `Vec` when none
    /// arrived.
    fn take(&mut self) -> Vec<Block>;
}

// A `Vec` is the simplest inbox. An empty one means no input.
impl Inbox for Vec<Block> {
    fn take(&mut self) -> Vec<Block> {
        std::mem::take(self)
    }
}

impl Conversation {
    /// An empty conversation.
    pub fn new() -> Self {
        Self::default()
    }

    /// The blocks of the conversation, oldest first.
    pub fn history(&self) -> &[Block] {
        &self.history
    }

    /// Start a turn with the blocks of `input`, such as a text and its attachments. Call it after the previous turn
    /// returned [`Action::Done`].
    pub fn start(&mut self, input: Vec<Block>) -> Action<'_> {
        self.history.extend(input);
        Action::Send(&self.history)
    }

    /// Take the result of the request that [`Action::Send`] asked for.
    pub fn model_finished(&mut self, result: Result<Response, ai::Error>) -> Action<'_> {
        let completion = match result {
            Ok(response) => response.completion,
            Err(error) => return Action::Done(Outcome::Failed(error)),
        };

        let finish_reason = completion.finish_reason;

        if completion.tool_calls().next().is_none() {
            self.history.extend(completion.into_blocks());
            self.turn_end = Some(finish_reason);
            return Action::AfterRound(&self.history);
        }

        if matches!(finish_reason, FinishReason::ToolCalls | FinishReason::Stop) {
            let start = self.history.len();
            self.history.extend(completion.into_blocks());

            return Action::CallTools(ToolCalls {
                blocks: &self.history[start..],
            });
        }

        // No call runs, but each call gets a result, so the next request stays valid.
        let results: Vec<Block> = completion
            .tool_calls()
            .map(|call| {
                Block::ToolResult(ToolResult::error(
                    &call.call_id,
                    not_executed(&call.name, finish_reason),
                ))
            })
            .collect();

        self.history.extend(completion.into_blocks());
        self.history.extend(results);

        // The model can issue a cut call again with complete arguments. A filter or a refusal would likely repeat, so
        // only new input continues the turn.
        if finish_reason != FinishReason::Length {
            self.turn_end = Some(finish_reason);
        }
        Action::AfterRound(&self.history)
    }

    /// Take the results of the calls that [`Action::CallTools`] asked for, in call order.
    pub fn tools_finished(&mut self, results: Vec<ToolResult>) -> Action<'_> {
        self.history.extend(results.into_iter().map(Block::ToolResult));
        Action::AfterRound(&self.history)
    }

    /// Continue after [`Action::AfterRound`]. Take the input of `inbox`, and send it after the round. After an answer
    /// that needs no other request, the turn ends only when `inbox` holds no input.
    pub fn proceed(&mut self, inbox: &mut dyn Inbox) -> Action<'_> {
        let input = inbox.take();
        // Input that arrived during the final answer continues the turn, so the model answers it in this turn.
        if let Some(finish_reason) = self.turn_end.take()
            && input.is_empty()
        {
            return Action::Done(Outcome::Completed { finish_reason });
        }

        self.history.extend(input);
        Action::Send(&self.history)
    }

    /// End the turn after [`Action::AfterRound`]. A round that ended the turn still ends it as
    /// [`Outcome::Completed`].
    pub fn stop(&mut self) -> Action<'_> {
        match self.turn_end.take() {
            Some(finish_reason) => Action::Done(Outcome::Completed { finish_reason }),
            None => Action::Done(Outcome::Stopped),
        }
    }
}

/// The text that tells the model why the call of `name` did not run.
fn not_executed(name: &str, finish_reason: FinishReason) -> String {
    match finish_reason {
        FinishReason::Length => format!(
            "Tool call \"{name}\" was not executed: the response hit the output token limit, so its arguments may be \
             truncated. Re-issue the tool call with complete arguments."
        ),
        _ => format!(
            "Tool call \"{name}\" was not executed: the response ended with finish reason {}.",
            finish_reason.as_str()
        ),
    }
}
