//! The decisions of one conversation. A [`Conversation`] does no I/O, reads no clock, and never awaits. Each call
//! that feeds it a fact returns the next [`Action`].

use yuke_ai::{Block, FinishReason, Partial, Response, Role, ToolCall, ToolResult};

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

    /// The model ended the turn, and no new input waits. Call [`Conversation::continue_turn`] to send another request
    /// in this turn. Call [`Conversation::stop`] to end the turn as [`Outcome::Completed`].
    AfterTurn {
        /// The whole history. It holds the last answer. It can also hold error results of calls that did not run.
        history: &'a [Block],

        /// The finish reason of the last answer.
        finish_reason: FinishReason,
    },

    /// The turn ended. `Err` holds the failure of a request, and the history keeps the input and no answer.
    Done(Result<Outcome, yuke_ai::Error>),
}

/// The tool calls of one answer. It borrows the blocks of the answer, so the calls are not copied.
#[derive(Debug, Clone, Copy)]
pub struct ToolCalls<'a> {
    blocks: &'a [Block],
}

impl<'a> IntoIterator for ToolCalls<'a> {
    type Item = &'a ToolCall;
    type IntoIter = ToolCallsIter<'a>;

    fn into_iter(self) -> ToolCallsIter<'a> {
        ToolCallsIter {
            blocks: self.blocks.iter(),
        }
    }
}

/// The iterator over the calls of [`ToolCalls`], in answer order.
#[derive(Debug, Clone)]
pub struct ToolCallsIter<'a> {
    blocks: std::slice::Iter<'a, Block>,
}

// The slice iterator stays empty after its end, so this iterator does too.
impl std::iter::FusedIterator for ToolCallsIter<'_> {}

impl<'a> Iterator for ToolCallsIter<'a> {
    type Item = &'a ToolCall;

    fn next(&mut self) -> Option<&'a ToolCall> {
        self.blocks.find_map(|block| match block {
            Block::ToolCall(call) => Some(call),
            _ => None,
        })
    }
}

/// How a turn ended without a failure.
#[derive(Debug, Clone)]
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

    /// The caller cancelled the turn. The history keeps the model output of the turn and a result for each tool call.
    /// It has no note about the cancel, so the caller can put one in the input of the next turn.
    Cancelled,
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

    /// Replace the history, for example with a summary and the recent blocks. Call it between turns, or before the
    /// request of [`Action::Send`]. The next request sends the new history.
    pub fn replace_history(&mut self, history: Vec<Block>) {
        self.history = history;
    }

    /// Start a turn with the blocks of `input`, such as a text and its attachments. Call it after the previous turn
    /// returned [`Action::Done`].
    pub fn start(&mut self, input: Vec<Block>) -> Action<'_> {
        self.history.extend(input);
        Action::Send(&self.history)
    }

    /// Take the result of the request that [`Action::Send`] asked for.
    pub fn model_finished(&mut self, result: Result<Response, yuke_ai::Error>) -> Action<'_> {
        let completion = match result {
            Ok(response) => response.completion,
            Err(error) => return Action::Done(Err(error)),
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
        let reason = match finish_reason {
            FinishReason::Length => OUTPUT_LIMIT_REASON.to_owned(),
            _ => format!("the response ended with finish reason {}.", finish_reason.as_str()),
        };
        let results: Vec<Block> = completion
            .tool_calls()
            .map(|call| Block::ToolResult(not_executed(call, &reason)))
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

    /// Continue after [`Action::AfterRound`], and send `input` after the round. After an answer that needs no other
    /// request, an empty `input` returns [`Action::AfterTurn`].
    pub fn proceed(&mut self, input: Vec<Block>) -> Action<'_> {
        // Input that arrived during the final answer continues the turn. Without input, the caller decides.
        if let Some(finish_reason) = self.turn_end
            && input.is_empty()
        {
            return Action::AfterTurn {
                history: &self.history,
                finish_reason,
            };
        }
        self.continue_turn(input)
    }

    /// Continue after [`Action::AfterTurn`]. The next [`Action::Send`] holds `input` after the answer, also when
    /// `input` is empty.
    pub fn continue_turn(&mut self, input: Vec<Block>) -> Action<'_> {
        self.turn_end = None;
        self.history.extend(input);
        Action::Send(&self.history)
    }

    /// End the turn after [`Action::AfterRound`] or [`Action::AfterTurn`]. A round that ended the turn still ends it
    /// as [`Outcome::Completed`].
    pub fn stop(&mut self) -> Action<'_> {
        match self.turn_end.take() {
            Some(finish_reason) => Action::Done(Ok(Outcome::Completed { finish_reason })),
            None => Action::Done(Ok(Outcome::Stopped)),
        }
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::Send`]. The `partial` output of the cancelled attempt
    /// joins the history, except its reasoning, which has no provider state. Each tool call in it gets an error result.
    pub fn model_cancelled(&mut self, partial: Vec<Partial>) -> Action<'_> {
        self.history.extend(
            partial
                .into_iter()
                .filter(|part| !matches!(part, Partial::Reasoning(_)))
                .map(Block::from),
        );
        self.tools_cancelled(Vec::new())
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::CallTools`]. Give the `results` of the tool calls that
    /// ran, in call order. Each tool call that did not run gets an error result.
    pub fn tools_cancelled(&mut self, results: Vec<ToolResult>) -> Action<'_> {
        let answer = self
            .history
            .iter()
            .rposition(|block| block.role() != Role::Assistant)
            .map_or(0, |index| index + 1);
        let not_run: Vec<Block> = self.history[answer..]
            .iter()
            .filter_map(|block| match block {
                Block::ToolCall(call) => Some(Block::ToolResult(not_executed(call, CANCELLED_REASON))),
                _ => None,
            })
            .skip(results.len())
            .collect();

        self.history.extend(results.into_iter().map(Block::ToolResult));
        self.history.extend(not_run);
        self.cancel()
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::AfterRound`] or [`Action::AfterTurn`].
    pub fn cancel(&mut self) -> Action<'_> {
        self.turn_end = None;
        Action::Done(Ok(Outcome::Cancelled))
    }
}

/// The reason of a call that did not run, because the user cancelled the turn.
pub(crate) const CANCELLED_REASON: &str = "the user cancelled the turn.";

/// The reason of a call that did not run, because the output limit can cut its arguments.
const OUTPUT_LIMIT_REASON: &str = "the response hit the output token limit, so its arguments may be truncated. \
                                   Re-issue the tool call with complete arguments.";

/// The error result of `call` when it did not run. `reason` tells the model why.
pub(crate) fn not_executed(call: &ToolCall, reason: &str) -> ToolResult {
    ToolResult::error(
        &call.call_id,
        format!("Tool call \"{}\" was not executed: {reason}", call.name),
    )
}
