//! The decisions of one conversation. A [`Conversation`] does no I/O, reads no clock, and never awaits. Each call
//! that feeds it a fact returns the next [`Action`].

use yuke_ai::{Block, FinishReason, Partial, Response, Role, ToolCall, ToolResult};

/// The decisions of one turn on the caller's history.
#[derive(Debug)]
pub(crate) struct Conversation<'h> {
    history: &'h mut Vec<Block>,

    /// The finish reason of the last answer, when that answer needs no other request. New input can still continue the
    /// turn.
    turn_end: Option<FinishReason>,
}

/// The next thing the driver does for a turn.
#[derive(Debug)]
#[must_use = "the turn continues only when the driver carries out the action"]
pub(crate) enum Action<'a> {
    /// Send a request of the whole history, then give the result to [`Conversation::model_finished`].
    Send,

    /// Run these calls, then give the results to [`Conversation::tools_finished`] in call order.
    CallTools(ToolCalls<'a>),

    /// A round ended, and its answer and tool results are in the history. Call [`Conversation::proceed`],
    /// [`Conversation::continue_turn`], or [`Conversation::stop`].
    AfterRound {
        /// The whole history.
        history: &'a [Block],

        /// The finish reason of an answer that needs no other request. `None` when the round asks for another request.
        finish_reason: Option<FinishReason>,
    },

    /// The turn ended. `Err` holds the failure of a request, and the history keeps the input and no answer.
    Done(Result<Outcome, yuke_ai::Error>),
}

/// The tool calls of one answer. It borrows the blocks of the answer, so the calls are not copied.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ToolCalls<'a> {
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
pub(crate) struct ToolCallsIter<'a> {
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

impl<'h> Conversation<'h> {
    /// The decisions of one turn on `history`.
    pub(crate) fn new(history: &'h mut Vec<Block>) -> Self {
        Conversation {
            history,
            turn_end: None,
        }
    }

    /// The blocks of the conversation, oldest first.
    pub(crate) fn history(&self) -> &[Block] {
        self.history.as_slice()
    }

    /// Replace the history, for example with a summary and the recent blocks. Call it before the request of
    /// [`Action::Send`]. The next request sends the new history.
    pub(crate) fn replace_history(&mut self, history: Vec<Block>) {
        *self.history = history;
    }

    /// Start a turn with the blocks of `input`, such as a text and its attachments. Call it after the previous turn
    /// returned [`Action::Done`].
    pub(crate) fn start(&mut self, input: Vec<Block>) -> Action<'_> {
        self.history.extend(input);
        Action::Send
    }

    /// Take the result of the request that [`Action::Send`] asked for.
    pub(crate) fn model_finished(&mut self, result: Result<Response, yuke_ai::Error>) -> Action<'_> {
        let completion = match result {
            Ok(response) => response.completion,
            Err(error) => return Action::Done(Err(error)),
        };

        let finish_reason = completion.finish_reason;

        if completion.tool_calls().next().is_none() {
            self.history.extend(completion.into_blocks());
            self.turn_end = Some(finish_reason);
            return self.after_round();
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
        self.after_round()
    }

    /// Take the results of the calls that [`Action::CallTools`] asked for, in call order.
    pub(crate) fn tools_finished(&mut self, results: Vec<ToolResult>) -> Action<'_> {
        self.history.extend(results.into_iter().map(Block::ToolResult));
        self.after_round()
    }

    /// Continue after [`Action::AfterRound`], and send `input` after the round. After an answer that needs no other
    /// request, an empty `input` ends the turn as [`Outcome::Completed`].
    pub(crate) fn proceed(&mut self, input: Vec<Block>) -> Action<'_> {
        // Input that arrived during the final answer continues the turn.
        if self.turn_end.is_some() && input.is_empty() {
            return self.stop();
        }
        self.continue_turn(input)
    }

    /// Send another request after [`Action::AfterRound`]. `input` joins the history before the request, also when it is
    /// empty.
    pub(crate) fn continue_turn(&mut self, input: Vec<Block>) -> Action<'_> {
        self.turn_end = None;
        self.history.extend(input);
        Action::Send
    }

    /// End the turn after [`Action::AfterRound`]. A round that ended the turn still ends it as [`Outcome::Completed`].
    pub(crate) fn stop(&mut self) -> Action<'_> {
        match self.turn_end.take() {
            Some(finish_reason) => Action::Done(Ok(Outcome::Completed { finish_reason })),
            None => Action::Done(Ok(Outcome::Stopped)),
        }
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::Send`]. The `partial` output of the cancelled attempt
    /// joins the history, except its reasoning, which has no provider state. Each tool call in it gets an error result.
    pub(crate) fn model_cancelled(&mut self, partial: Vec<Partial>) -> Action<'_> {
        self.history.extend(
            partial
                .into_iter()
                .filter(|part| !matches!(part, Partial::Reasoning(_)))
                .map(Block::from),
        );
        self.tools_cancelled(Vec::new())
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::CallTools`]. Give the `results` of the first calls, in call
    /// order, for example of the calls that ran. Each later call gets an error result.
    pub(crate) fn tools_cancelled(&mut self, results: Vec<ToolResult>) -> Action<'_> {
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

    /// End the turn as [`Outcome::Cancelled`] after [`Action::AfterRound`].
    pub(crate) fn cancel(&mut self) -> Action<'_> {
        self.turn_end = None;
        Action::Done(Ok(Outcome::Cancelled))
    }

    /// The question to the caller after a round.
    fn after_round(&self) -> Action<'_> {
        Action::AfterRound {
            history: self.history.as_slice(),
            finish_reason: self.turn_end,
        }
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

#[cfg(test)]
mod tests;
