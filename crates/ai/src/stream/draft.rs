//! The block table and the response end that the three reducers share. A pending delta borrows the payload that
//! holds its text, and the draft copies any other text.

use std::ops::Range;

use crate::json::Malformed;
use crate::request::{Origin, ReasoningReplayRef, ReplayKind, ToolCallRef};
use crate::response::{
    BlockId, BlockKind, BlockResult, BlockStarted, BlockStopped, Delta, Done, Event, FinishReason, ResponseLimits,
    Usage,
};

/// A reducer fails on malformed or oversized input. A provider error is no decode error: the reducer names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DecodeError {
    Protocol,
    TooLarge,
}

impl From<Malformed> for DecodeError {
    fn from(_: Malformed) -> Self {
        DecodeError::Protocol
    }
}

/// The action for each open tool call at the end of a response.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OpenTools {
    Keep,
    Drop,
}

/// The state of one block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BlockState {
    Open,
    Stopped,
    /// Closed without a result. A dropped block reaches no consumer.
    Dropped,
}

/// One neutral block. Its id is its index, so ids stay dense from 0.
#[derive(Debug)]
pub(crate) struct Block {
    pub(crate) kind: BlockKind,
    pub(crate) state: BlockState,
    pub(crate) call_id: String,
    pub(crate) name: String,
    /// The joined bytes of the block's state: the argument fragments of a tool, or the provider state of a reasoning
    /// block. A block has one kind, so one buffer serves both.
    pub(crate) bytes: String,
    /// Which provider state a reasoning block carries in `bytes`, or `None` for none.
    pub(crate) replay: Option<ReplayKind>,
}

/// Where the text of a pending delta lies.
#[derive(Debug, Clone)]
enum Text {
    /// A range of the current payload.
    Payload(Range<usize>),
    /// A range of [`Draft::text`]: an escaped string or a separator.
    Copied(Range<usize>),
}

/// One event of the current payload.
#[derive(Debug, Clone)]
enum Pending {
    Started(BlockId, BlockKind),
    /// A text, refusal, reasoning, or argument fragment. The block kind names which.
    Delta(BlockId, BlockKind, Text),
    Section(BlockId),
    Stopped(BlockId),
    Done,
}

/// The blocks and the end of one response, while the response streams.
#[derive(Debug)]
pub(crate) struct Draft {
    /// The model and host that answer. Every reasoning state names it.
    origin: Origin,
    /// The bounds on the blocks and the tool arguments of this draft.
    pub(crate) limits: ResponseLimits,
    pub(crate) blocks: Vec<Block>,
    /// The events of the current payload. The stream clears them once it has handed out every event.
    events: Vec<Pending>,
    /// The text of the pending deltas that the payload does not hold.
    text: String,
    /// The address range of the current payload, so a delta can tell whether the payload holds its text.
    payload: Range<usize>,
    pub(crate) usage: Usage,
    pub(crate) finish_reason: FinishReason,
    pub(crate) raw_finish_reason: String,
    pub(crate) done: bool,
}

impl Draft {
    pub(crate) fn new(origin: Origin, limits: ResponseLimits) -> Self {
        Draft {
            origin,
            limits,
            blocks: Vec::new(),
            events: Vec::new(),
            text: String::new(),
            payload: 0..0,
            usage: Usage::default(),
            finish_reason: FinishReason::Unknown,
            raw_finish_reason: String::new(),
            done: false,
        }
    }

    /// The number of pending events.
    pub(crate) fn pending(&self) -> usize {
        self.events.len()
    }

    /// Drop the pending events and their text.
    pub(crate) fn clear_events(&mut self) {
        self.events.clear();
        self.text.clear();
    }

    /// Start the events of `payload`. The deltas borrow `payload` until the stream clears the events.
    pub(crate) fn begin_payload(&mut self, payload: &str) {
        let start = payload.as_ptr().addr();
        self.payload = start..start + payload.len();
    }

    /// Lend the pending event at `index`. `payload` is the payload that [`Draft::begin_payload`] began.
    pub(crate) fn event<'t>(&'t self, index: usize, payload: &'t str) -> Event<'t> {
        debug_assert_eq!(
            payload.as_ptr().addr()..payload.as_ptr().addr() + payload.len(),
            self.payload
        );
        match &self.events[index] {
            &Pending::Started(block, kind) => Event::BlockStarted(BlockStarted { block, kind }),
            Pending::Delta(block, kind, text) => {
                let delta = Delta {
                    block: *block,
                    text: match text {
                        Text::Payload(range) => &payload[range.clone()],
                        Text::Copied(range) => &self.text[range.clone()],
                    },
                };
                match kind {
                    BlockKind::Text => Event::TextDelta(delta),
                    BlockKind::Refusal => Event::RefusalDelta(delta),
                    BlockKind::Reasoning => Event::ReasoningDelta(delta),
                    BlockKind::ToolCall => Event::ToolInputDelta(delta),
                }
            }
            &Pending::Section(block) => Event::ReasoningSectionStarted(block),
            &Pending::Stopped(block) => Event::BlockStopped(BlockStopped {
                block,
                result: self.result(block),
            }),
            Pending::Done => Event::Done(Done {
                finish_reason: self.finish_reason,
                raw_finish_reason: &self.raw_finish_reason,
                usage: self.usage,
            }),
        }
    }

    /// The result of a stopped block. A stopped block never changes, so the result reads it when the event goes out.
    fn result(&self, id: BlockId) -> BlockResult<'_> {
        let block = &self.blocks[id as usize];
        match block.kind {
            BlockKind::Text => BlockResult::Text,
            BlockKind::Refusal => BlockResult::Refusal,
            BlockKind::Reasoning => BlockResult::Reasoning(block.replay.map(|kind| ReasoningReplayRef {
                origin: self.origin.as_borrowed(),
                kind,
                data: &block.bytes,
            })),
            // A call with no fragment takes the empty object.
            BlockKind::ToolCall => BlockResult::ToolCall(ToolCallRef {
                call_id: &block.call_id,
                name: &block.name,
                arguments: if block.bytes.is_empty() { "{}" } else { &block.bytes },
            }),
        }
    }

    /// Add a block and announce it.
    pub(crate) fn start(&mut self, kind: BlockKind) -> Result<BlockId, DecodeError> {
        if self.blocks.len() >= self.limits.max_blocks as usize {
            return Err(DecodeError::TooLarge);
        }
        let id = BlockId::try_from(self.blocks.len()).map_err(|_| DecodeError::TooLarge)?;
        self.blocks.push(Block {
            kind,
            state: BlockState::Open,
            call_id: String::new(),
            name: String::new(),
            bytes: String::new(),
            replay: None,
        });
        self.events.push(Pending::Started(id, kind));
        Ok(id)
    }

    /// Add a tool block that owns copies of its call id and name, and announce it.
    pub(crate) fn start_tool(&mut self, call_id: &str, name: &str) -> Result<BlockId, DecodeError> {
        let id = self.start(BlockKind::ToolCall)?;
        self.identify(id, call_id, name)?;
        Ok(id)
    }

    /// Set a tool's call id and name from the first value that names each. A later value changes nothing: Mistral
    /// repeats the id as the string `null` in later chunks.
    pub(crate) fn identify(&mut self, id: BlockId, call_id: &str, name: &str) -> Result<(), DecodeError> {
        let block = self.open(id)?;
        if block.call_id.is_empty() {
            call_id.clone_into(&mut block.call_id);
        }
        if block.name.is_empty() {
            name.clone_into(&mut block.name);
        }
        Ok(())
    }

    /// The open block with this id. A finished block rejects the frame. Every id a reducer holds came from `start`.
    pub(crate) fn open(&mut self, id: BlockId) -> Result<&mut Block, DecodeError> {
        let block = &mut self.blocks[id as usize];
        if block.state == BlockState::Open {
            Ok(block)
        } else {
            Err(DecodeError::Protocol)
        }
    }

    /// Announce text of a text, refusal, or reasoning block.
    pub(crate) fn delta(&mut self, id: BlockId, text: &str) -> Result<(), DecodeError> {
        let kind = self.open(id)?.kind;
        debug_assert!(kind != BlockKind::ToolCall, "a tool fragment goes to `tool_delta`");
        self.push_delta(id, kind, text);
        Ok(())
    }

    /// Announce a delta. Text inside the payload stays there, and other text is copied.
    fn push_delta(&mut self, id: BlockId, kind: BlockKind, text: &str) {
        let start = text.as_ptr().addr();
        let place = if self.payload.contains(&start) && start + text.len() <= self.payload.end {
            let offset = start - self.payload.start;
            Text::Payload(offset..offset + text.len())
        } else {
            let offset = self.text.len();
            self.text.push_str(text);
            Text::Copied(offset..self.text.len())
        };
        self.events.push(Pending::Delta(id, kind, place));
    }

    /// Mark the start of a new reasoning section. The next delta of the block opens it.
    pub(crate) fn section(&mut self, id: BlockId) -> Result<(), DecodeError> {
        debug_assert_eq!(
            self.open(id)?.kind,
            BlockKind::Reasoning,
            "only a reasoning block has sections"
        );
        self.events.push(Pending::Section(id));
        Ok(())
    }

    /// Join one argument fragment, within `limits.max_tool_arg_bytes`.
    pub(crate) fn tool_delta(&mut self, id: BlockId, fragment: &str) -> Result<(), DecodeError> {
        let max = self.limits.max_tool_arg_bytes;
        let block = self.open(id)?;
        debug_assert!(block.bytes.len() <= max);
        if fragment.len() > max - block.bytes.len() {
            return Err(DecodeError::TooLarge);
        }
        block.bytes.push_str(fragment);
        self.push_delta(id, BlockKind::ToolCall, fragment);
        Ok(())
    }

    /// Record the provider's final arguments, within `limits.max_tool_arg_bytes`. They replace whatever came before,
    /// as the OpenAI SDK replaces an item with the one its done event carries.
    pub(crate) fn final_args(&mut self, id: BlockId, arguments: &str) -> Result<(), DecodeError> {
        let max = self.limits.max_tool_arg_bytes;
        let block = self.open(id)?;
        if arguments.len() > max {
            return Err(DecodeError::TooLarge);
        }
        arguments.clone_into(&mut block.bytes);
        Ok(())
    }

    pub(crate) fn stop(&mut self, id: BlockId) -> Result<(), DecodeError> {
        self.open(id)?.state = BlockState::Stopped;
        self.events.push(Pending::Stopped(id));
        Ok(())
    }

    pub(crate) fn stop_if_open(&mut self, id: BlockId) -> Result<(), DecodeError> {
        if self.blocks[id as usize].state == BlockState::Open {
            self.stop(id)
        } else {
            Ok(())
        }
    }

    /// Close a block without a result. A dropped block reaches no consumer.
    pub(crate) fn drop_block(&mut self, id: BlockId) -> Result<(), DecodeError> {
        self.open(id)?.state = BlockState::Dropped;
        Ok(())
    }

    pub(crate) fn any_open(&self) -> bool {
        self.blocks.iter().any(|block| block.state == BlockState::Open)
    }

    pub(crate) fn set_finish(&mut self, finish_reason: FinishReason, raw: &str) {
        raw.clone_into(&mut self.raw_finish_reason);
        self.finish_reason = finish_reason;
    }

    /// Close every open block, then end the draft. `OpenTools::Drop` discards unfinished tool calls.
    pub(crate) fn close_and_finish(&mut self, open_tools: OpenTools) -> Result<(), DecodeError> {
        for index in 0..self.blocks.len() {
            let block = &self.blocks[index];
            if block.state != BlockState::Open {
                continue;
            }
            let id = BlockId::try_from(index).map_err(|_| DecodeError::TooLarge)?;
            if open_tools == OpenTools::Drop && block.kind == BlockKind::ToolCall {
                self.drop_block(id)?;
            } else {
                self.stop(id)?;
            }
        }
        self.finish();
        Ok(())
    }

    /// End the draft, which holds no open block. A stopped refusal turns `Stop` or `ToolCalls` into `Refusal`, but a
    /// token limit or a content filter stays the reason, as in the OpenAI SDK.
    pub(crate) fn finish(&mut self) {
        debug_assert!(!self.done);
        debug_assert!(!self.any_open());
        self.done = true;
        let refused = self
            .blocks
            .iter()
            .any(|block| block.kind == BlockKind::Refusal && block.state == BlockState::Stopped);
        if refused && matches!(self.finish_reason, FinishReason::Stop | FinishReason::ToolCalls) {
            self.finish_reason = FinishReason::Refusal;
        }
        self.events.push(Pending::Done);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draft(limits: ResponseLimits) -> Draft {
        Draft::new(
            Origin {
                model: "m".into(),
                base_url: "https://example.test/v1".into(),
            },
            limits,
        )
    }

    #[test]
    fn tool_argument_limit_rejects_before_mutation() {
        let mut draft = draft(ResponseLimits {
            max_tool_arg_bytes: 8,
            ..ResponseLimits::default()
        });
        let id = draft.start(BlockKind::ToolCall).unwrap();
        draft.tool_delta(id, "xxxxxxxx").unwrap();
        let before = draft.pending();
        assert_eq!(draft.tool_delta(id, "x"), Err(DecodeError::TooLarge));
        assert_eq!(draft.blocks[id as usize].bytes.len(), 8);
        assert_eq!(draft.pending(), before);
    }

    #[test]
    fn delta_borrows_payload_or_copies() {
        let mut draft = draft(ResponseLimits::default());
        let payload = String::from("{\"text\":\"Hello\"}");
        draft.begin_payload(&payload);
        let id = draft.start(BlockKind::Text).unwrap();
        draft.delta(id, &payload[9..14]).unwrap();
        draft.delta(id, "\n\n").unwrap();
        let Event::TextDelta(inside) = draft.event(1, &payload) else {
            panic!()
        };
        assert_eq!(inside.text, "Hello");
        assert_eq!(inside.text.as_ptr(), payload[9..].as_ptr());
        let Event::TextDelta(outside) = draft.event(2, &payload) else {
            panic!()
        };
        assert_eq!(outside.text, "\n\n");
        assert_eq!(draft.text, "\n\n");
    }
}
