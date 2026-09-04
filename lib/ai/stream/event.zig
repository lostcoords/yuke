//! Neutral events name dense blocks and borrow every source slice until the consumer drains them.

const types = @import("../types.zig");

/// A block becomes at most one message part, so the part cap bounds the blocks a reducer holds.
pub const max_blocks = types.limits.max_blocks;

/// The arguments of a tool call reach the wire as one message string, so that cap bounds the accumulation.
pub const max_tool_arg_bytes = types.limits.max_string_bytes;

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
    /// Complete JSON object text, from the provider or from joined deltas. The consumer validates it.
    arguments: []const u8,
};

/// This value marks the end of the turn. `stop_reason` uses the closed set; `raw_stop_reason` keeps the provider value.
pub const Done = struct {
    stop_reason: types.FinishReason,
    raw_stop_reason: []const u8,
    usage: types.Usage,
};
