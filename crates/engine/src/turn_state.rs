//! The decisions of one turn. A [`TurnState`] does no I/O, reads no clock, and never awaits. Each call
//! that feeds it a fact returns the next [`Action`], with the [`Commit`] that the caller saves before it acts.

use std::borrow::Cow;

use serde::{Deserialize, Serialize};
use yuke_ai::{Block, Completion, FinishReason, Origin, Partial, ToolCall, ToolResult, Usage};

use crate::model::RoundError;
use crate::tool::{DisplayBlock, ToolHints, ToolOutcome};

/// The decisions of one turn on the caller's context.
#[derive(Debug)]
pub(crate) struct TurnState<'c> {
    context: &'c mut Vec<Block>,

    /// The number of context blocks that a commit holds already. The context that a turn starts with counts as saved.
    saved: usize,

    /// The finish reason of the last answer, when that answer needs no other request. New input can still continue the
    /// turn.
    turn_end: Option<FinishReason>,

    /// The input tokens of the newest answer, before this turn or in it.
    input_tokens: Option<u64>,

    /// The display of the tool results since the last commit, for the next commit.
    results: Vec<ResultDisplay>,
}

/// The next thing the driver does for a turn. The driver saves the commit of an action before it acts.
#[derive(Debug)]
#[must_use = "the turn continues only when the driver carries out the action"]
pub(crate) enum Action<'a> {
    /// Send a request of the whole context, then give the answer to [`TurnState::model_finished`], or the failure to
    /// [`TurnState::fail`]. The commit holds the new input, and it is `None` without new input.
    Send(Option<Commit<'a>>),

    /// Run these calls, then give the results to [`TurnState::tools_finished`] in call order. The commit holds the
    /// answer.
    CallTools(Commit<'a>),

    /// A round ended, and its answer and tool results are in the context. Call [`TurnState::proceed`],
    /// [`TurnState::send`], [`TurnState::stop`], or [`TurnState::fail`].
    AfterRound {
        /// The whole context.
        context: &'a [Block],

        /// The finish reason of an answer that needs no other request. `None` when the round asks for another request.
        finish_reason: Option<FinishReason>,

        /// The answer or the tool results of the round.
        commit: Commit<'a>,
    },

    /// The turn ended. `Err` holds the failure of a round, and the context keeps the blocks from before the failure.
    /// The end commit holds `tail` and `result`.
    Done {
        /// The blocks after the last commit, such as the partial output of a cancel.
        tail: &'a [Block],

        /// How the turn ended.
        result: Result<Outcome, RoundError>,

        /// The display of the tool results in `tail`.
        display: CommitDisplay,
    },
}

/// The change of the context since the last commit, and the facts of the turn. Replay each commit in order on a copy
/// of the context: apply `replaced`, then append `blocks`. The copy then equals the context. The driver lends its
/// blocks, and a store that reads a commit back owns them.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Commit<'a> {
    /// The replacement of the context. A commit with a replacement holds no blocks.
    pub replaced: Option<Replaced<'a>>,

    /// The blocks after the saved blocks, in context order.
    pub blocks: Cow<'a, [Block]>,

    /// The facts of the answer in `blocks`. A commit without an answer has `None`.
    pub answer: Option<Answer>,

    /// How the turn ended. A commit in the middle of a turn has `None`.
    pub end: Option<TurnEnd>,

    /// What a frontend shows for the tool calls and results in `blocks`. The model never sees it.
    #[serde(default, skip_serializing_if = "CommitDisplay::is_empty")]
    pub display: CommitDisplay,
}

/// What a frontend shows for the tool calls and results of a commit. The model never sees it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CommitDisplay {
    /// The hints of each tool call that the driver handled, in block order.
    pub calls: Vec<CallDisplay>,
    /// The display of each tool result that has one, in block order.
    pub results: Vec<ResultDisplay>,
}

impl CommitDisplay {
    /// Whether the commit has no display.
    pub fn is_empty(&self) -> bool {
        self.calls.is_empty() && self.results.is_empty()
    }
}

/// The hints of one tool call of a commit, and the folder where it ran.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CallDisplay {
    /// The index of the call in the blocks of the commit.
    pub block_index: usize,
    /// The hints of the tool that the call names, after the deferred-tool bridge.
    pub hints: ToolHints,
    /// The folder where the call ran. A relative path of the call starts there.
    pub folder: Option<String>,
}

/// The display of one tool result of a commit.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ResultDisplay {
    /// The index of the result in the blocks of the commit.
    pub block_index: usize,
    /// What a frontend shows in place of the result text.
    pub blocks: Vec<DisplayBlock>,
}

impl<'a> Commit<'a> {
    /// The commit of `blocks` with no other fact.
    pub fn blocks(blocks: impl Into<Cow<'a, [Block]>>) -> Self {
        Commit {
            replaced: None,
            blocks: blocks.into(),
            answer: None,
            end: None,
            display: CommitDisplay::default(),
        }
    }

    /// Replay this commit on `context`, a copy of the context: apply `replaced`, then append `blocks`.
    pub fn apply(&self, context: &mut Vec<Block>) {
        if let Some(replaced) = &self.replaced {
            let cut = context.len().saturating_sub(replaced.keep);
            context.splice(..cut, replaced.head.iter().cloned());
        }
        context.extend_from_slice(&self.blocks);
    }

    /// The same commit with its own copy of each block.
    pub fn into_owned(self) -> Commit<'static> {
        Commit {
            replaced: self.replaced.map(|Replaced { head, keep }| Replaced {
                head: Cow::Owned(head.into_owned()),
                keep,
            }),
            blocks: Cow::Owned(self.blocks.into_owned()),
            answer: self.answer,
            end: self.end,
            display: self.display,
        }
    }

    /// The commit that ends a turn with `result` after the `tail` blocks.
    pub(crate) fn end(tail: &'a [Block], result: Result<&Outcome, &RoundError>) -> Self {
        Commit {
            end: Some(TurnEnd::from_result(result)),
            ..Commit::blocks(tail)
        }
    }
}

/// How a turn ended, in a form that a journal can save. A failure keeps the text of its error, and
/// [`crate::TurnError::Round`] gives the caller the error itself.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum TurnEnd {
    /// The turn ended without a failure.
    Outcome(Outcome),
    /// A round failed, or the turn stopped before it saved its end. The text tells why.
    Failed(String),
}

impl TurnEnd {
    /// The end of a turn that gave `result`. A failure keeps the [`chain_text`] of its error.
    pub fn from_result(result: Result<&Outcome, &RoundError>) -> Self {
        match result {
            Ok(outcome) => Self::Outcome(outcome.clone()),
            Err(error) => Self::Failed(chain_text(error)),
        }
    }
}

/// A new context: `head`, then the last `keep` blocks of the old context. A compaction gives a summary and the recent
/// blocks. Another rewrite gives the whole new context as `head` and keeps nothing. A hook asks for one in a
/// [`RoundPlan`](crate::RoundPlan), and a [`Commit`] saves it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Replaced<'a> {
    /// The new first blocks, such as a summary.
    pub head: Cow<'a, [Block]>,

    /// The number of blocks at the end of the old context that stay after `head`. In a plan, a number above the length
    /// keeps the whole old context; a commit holds the number that stayed.
    pub keep: usize,
}

/// The facts of one answer of the model.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    /// The model and host of the target that answered.
    pub origin: Origin,

    /// The input, output, reasoning, cache read, and cache write token counts of the answer.
    pub usage: Usage,

    /// The reason that the answer stopped, such as `length` or `content_filter`.
    pub finish_reason: FinishReason,
}

/// How a turn ended without a failure.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Outcome {
    /// The turn ended with an answer of the model, and the answer joined the context. A filter or a refusal answer
    /// can hold calls that did not run.
    Completed {
        /// The reason in the closed set.
        finish_reason: FinishReason,
    },

    /// The caller stopped the turn after a round that asked for another request. The context ends with the tool
    /// results of that round.
    Stopped,

    /// The caller cancelled the turn. The context keeps the model output of the turn and a result for each tool call.
    /// It has no note about the cancel, so the caller can put one in the input of the next turn.
    Cancelled,
}

impl<'c> TurnState<'c> {
    /// The decisions of one turn on `context`. The context counts as saved.
    pub(crate) fn new(context: &'c mut Vec<Block>, input_tokens: Option<u64>) -> Self {
        let saved = context.len();
        TurnState {
            context,
            saved,
            turn_end: None,
            input_tokens,
            results: Vec::new(),
        }
    }

    /// The input tokens of the newest answer.
    pub(crate) fn input_tokens(&self) -> Option<u64> {
        self.input_tokens
    }

    /// The context, oldest first.
    pub(crate) fn context(&self) -> &[Block] {
        self.context.as_slice()
    }

    /// Replace the context with `replace.head` and the last `replace.keep` blocks, and return the commit of the
    /// replacement. Call it after the input commit of [`Action::Send`], so the replacement keeps only saved blocks. The
    /// driver saves the returned commit before the next request.
    pub(crate) fn replace(&mut self, replace: Replaced<'_>) -> Commit<'_> {
        let Replaced { head, keep } = replace;
        let cut = self.context.len().saturating_sub(keep);
        let head_len = head.len();
        self.context.splice(..cut, head.into_owned());
        self.saved = self.context.len();
        self.input_tokens = None;
        Commit {
            replaced: Some(Replaced {
                head: Cow::Borrowed(&self.context[..head_len]),
                keep: self.context.len() - head_len,
            }),
            ..Commit::blocks(&[])
        }
    }

    /// Take the answer to the request that [`Action::Send`] asked for. `origin` names the target that answered.
    pub(crate) fn model_finished(&mut self, completion: Completion, origin: Origin) -> Action<'_> {
        let finish_reason = completion.finish_reason;
        self.input_tokens = completion.usage.input;
        let answer = Answer {
            origin,
            usage: completion.usage,
            finish_reason,
        };

        if completion.tool_calls().next().is_none() {
            self.context.extend(completion.into_blocks());
            self.turn_end = Some(finish_reason);
            return self.after_round(Some(answer));
        }

        if matches!(finish_reason, FinishReason::ToolCalls | FinishReason::Stop) {
            self.context.extend(completion.into_blocks());
            let saved = self.take_unsaved();
            return Action::CallTools(Commit {
                answer: Some(answer),
                ..Commit::blocks(&self.context[saved..])
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

        self.context.extend(completion.into_blocks());
        self.context.extend(results);

        // The model can issue a cut call again with complete arguments. A filter or a refusal would likely repeat, so
        // only new input continues the turn.
        if finish_reason != FinishReason::Length {
            self.turn_end = Some(finish_reason);
        }
        self.after_round(Some(answer))
    }

    /// Take the outcomes of the calls that [`Action::CallTools`] asked for, in call order.
    pub(crate) fn tools_finished(&mut self, outcomes: Vec<ToolOutcome>) -> Action<'_> {
        self.add_outcomes(outcomes);
        self.after_round(None)
    }

    /// Continue after [`Action::AfterRound`], and send `input` after the round. After an answer that needs no other
    /// request, an empty `input` ends the turn as [`Outcome::Completed`].
    pub(crate) fn proceed(&mut self, input: Vec<Block>) -> Action<'_> {
        // Input that arrived during the final answer continues the turn.
        if self.turn_end.is_some() && input.is_empty() {
            return self.stop();
        }
        self.send(input)
    }

    /// Send a request at the start of the turn or after [`Action::AfterRound`]. `input`, such as a text and its
    /// attachments, joins the context before the request, also when it is empty.
    pub(crate) fn send(&mut self, input: Vec<Block>) -> Action<'_> {
        self.turn_end = None;
        self.context.extend(input);
        Action::Send(self.commit())
    }

    /// End the turn after [`Action::AfterRound`]. A round that ended the turn still ends it as [`Outcome::Completed`].
    pub(crate) fn stop(&mut self) -> Action<'_> {
        let outcome = match self.turn_end {
            Some(finish_reason) => Outcome::Completed { finish_reason },
            None => Outcome::Stopped,
        };
        self.done(Ok(outcome))
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::Send`]. The `partial` output of the cancelled attempt
    /// joins the context. Each tool call in it gets an error result.
    pub(crate) fn model_cancelled(&mut self, partial: Vec<Partial>) -> Action<'_> {
        let blocks: Vec<Block> = partial.into_iter().map(Block::from).collect();
        let not_run: Vec<Block> = blocks
            .iter()
            .filter_map(|block| match block {
                Block::ToolCall(call) => Some(Block::ToolResult(not_executed(call, CANCELLED_REASON))),
                _ => None,
            })
            .collect();
        self.context.extend(blocks);
        self.context.extend(not_run);
        self.cancel()
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::CallTools`], with the `outcomes` of every call, in call
    /// order. A call that did not run has its error result among them.
    pub(crate) fn tools_cancelled(&mut self, outcomes: Vec<ToolOutcome>) -> Action<'_> {
        self.add_outcomes(outcomes);
        self.cancel()
    }

    /// Add the result of each outcome to the context, and keep its display for the next commit.
    fn add_outcomes(&mut self, outcomes: Vec<ToolOutcome>) {
        for ToolOutcome { result, display } in outcomes {
            if !display.is_empty() {
                self.results.push(ResultDisplay {
                    block_index: self.context.len() - self.saved,
                    blocks: display,
                });
            }
            self.context.push(Block::ToolResult(result));
        }
    }

    /// End the turn as [`Outcome::Cancelled`] after [`Action::AfterRound`].
    pub(crate) fn cancel(&mut self) -> Action<'_> {
        self.done(Ok(Outcome::Cancelled))
    }

    /// End the turn with `error` after [`Action::Send`] or [`Action::AfterRound`].
    pub(crate) fn fail(&mut self, error: RoundError) -> Action<'_> {
        self.done(Err(error))
    }

    /// The question to the caller after a round, with the commit of the round.
    fn after_round(&mut self, answer: Option<Answer>) -> Action<'_> {
        let start = self.take_unsaved();
        Action::AfterRound {
            context: self.context.as_slice(),
            finish_reason: self.turn_end,
            commit: Commit {
                answer,
                display: CommitDisplay {
                    calls: Vec::new(),
                    results: std::mem::take(&mut self.results),
                },
                ..Commit::blocks(&self.context[start..])
            },
        }
    }

    /// The end of the turn with `result`, after the blocks since the last commit.
    fn done(&mut self, result: Result<Outcome, RoundError>) -> Action<'_> {
        let start = self.take_unsaved();
        Action::Done {
            tail: &self.context[start..],
            result,
            display: CommitDisplay {
                calls: Vec::new(),
                results: std::mem::take(&mut self.results),
            },
        }
    }

    /// The commit of the blocks since the last commit, or `None` when no block came.
    fn commit(&mut self) -> Option<Commit<'_>> {
        let start = self.take_unsaved();
        (start < self.context.len()).then(|| Commit::blocks(&self.context[start..]))
    }

    /// Mark the whole context saved, because a commit of it follows. Return the index of the first block that the
    /// commit holds.
    fn take_unsaved(&mut self) -> usize {
        std::mem::replace(&mut self.saved, self.context.len())
    }
}

/// Return the text of `error` and of each of its causes, joined by colons. [`TurnEnd::Failed`] saves this text, because it is
/// all that a reader of the turn gets.
pub fn chain_text(error: &dyn std::error::Error) -> String {
    std::iter::successors(Some(error), |error| error.source())
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}

/// The reason of a call that did not run, because the user cancelled the turn.
pub(crate) const CANCELLED_REASON: &str = "the user cancelled the turn.";

/// The reason of a call that did not run, because the output limit can cut its arguments.
const OUTPUT_LIMIT_REASON: &str = "the response hit the output token limit, so its arguments may be truncated.";

/// The error result of `call` when it did not run. `reason` tells the model why.
pub(crate) fn not_executed(call: &ToolCall, reason: &str) -> ToolResult {
    ToolResult::error(
        &call.call_id,
        format!("Tool call \"{}\" was not executed: {reason}", call.name),
    )
}

#[cfg(test)]
mod tests;
