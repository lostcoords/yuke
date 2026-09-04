//! Neutral events use a closed, block-based shape. A reducer maps provider SSE to this stream.
//! It assigns dense `BlockId` values, emits block events and one `done`, and borrows source slices until the consumer drains the stream.
//! Several blocks can stay open at one time, because the Responses API interleaves output items.
//! The consumer numbers its own parts in emit order, so a block id is never a part id.
//! A reducer stops or drops each open block before `done`; a dropped block opens no part.

const proto = @import("proto");

/// A block becomes at most one message part, so the part cap bounds the blocks a reducer holds.
pub const max_blocks: usize = @intCast(proto.meta.limits.max_message_parts);

/// The arguments of a tool call reach the wire as one message string, so that cap bounds the accumulation.
pub const max_tool_arg_bytes: usize = @intCast(proto.meta.limits.max_message_string_bytes);

/// A dense identifier that a reducer assigns to a stream-local block.
pub const BlockId = u32;

pub const BlockKind = enum { text, reasoning, redacted_reasoning, tool };

pub const StreamEvent = union(enum) {
    block_started: BlockStarted,
    text_delta: TextDelta,
    reasoning_delta: ReasoningDelta,
    tool_input_delta: ToolInputDelta,
    block_stopped: BlockStopped,
    done: Done,
};

pub const BlockStarted = struct {
    block: BlockId,
    kind: BlockKind,
};

pub const TextDelta = struct {
    block: BlockId,
    text: []const u8,
};

pub const ReasoningDelta = struct {
    block: BlockId,
    text: []const u8,
};

/// A tool argument fragment. The fragment is not valid JSON by itself.
pub const ToolInputDelta = struct {
    block: BlockId,
    partial_json: []const u8,
};

pub const BlockStopped = struct {
    block: BlockId,
    result: BlockResult,
};

/// The block-stop result carries provider-only state that deltas cannot carry.
pub const BlockResult = union(enum) {
    text,
    reasoning: Reasoning,
    redacted_reasoning: Redacted,
    tool: ToolCall,
};

pub const Reasoning = struct {
    /// The provider signature. An empty slice means that the provider sent none.
    signature: []const u8,
};

pub const Redacted = struct {
    data: []const u8,
};

pub const ToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    /// Complete JSON object text from the provider or joined deltas.
    /// The consumer validates this value.
    arguments: []const u8,
};

/// This value marks the end of the turn. `stop_reason` uses the closed set; `raw_stop_reason` keeps the provider value.
pub const Done = struct {
    stop_reason: proto.enums.StopReason,
    raw_stop_reason: []const u8,
    usage: proto.message.TokenUsage,
};
