//! Neutral events use a closed, block-based shape. A reducer maps provider SSE to this stream.
//! It assigns dense `BlockId` values, emits block events and one `done`, and borrows source slices until the consumer drains the stream.

const wire = @import("wire");

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

/// A tool argument fragment. The fragment is not valid JSON alone.
pub const ToolInputDelta = struct {
    block: BlockId,
    partial_json: []const u8,
};

pub const BlockStopped = struct {
    block: BlockId,
    result: BlockResult,
};

/// Data at block stop. It carries provider-only state that deltas cannot carry.
pub const BlockResult = union(enum) {
    text,
    reasoning: Reasoning,
    redacted_reasoning: Redacted,
    tool: ToolCall,
};

pub const Reasoning = struct {
    /// Provider signature. An empty slice means that the provider sent none.
    signature: []const u8,
};

pub const Redacted = struct {
    data: []const u8,
};

pub const ToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    /// Complete JSON object text from the provider or from joined deltas.
    /// The consumer validates this value.
    arguments: []const u8,
};

/// End of the turn. `stop_reason` uses the closed set; `raw_stop_reason` keeps the provider value.
pub const Done = struct {
    stop_reason: wire.enums.StopReason,
    raw_stop_reason: []const u8,
    usage: wire.message.TokenUsage,
};
