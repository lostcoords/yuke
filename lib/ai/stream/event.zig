//! Neutral events name dense blocks and borrow every source slice until the consumer drains them.

const std = @import("std");
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

    /// Copy every string into `gpa`, which must be an arena, because a result frees nothing itself.
    pub fn cloneLeaky(self: BlockResult, gpa: std.mem.Allocator) std.mem.Allocator.Error!BlockResult {
        return switch (self) {
            .text => .text,
            .reasoning => |value| .{ .reasoning = .{ .signature = try gpa.dupe(u8, value.signature) } },
            .redacted_reasoning => |value| .{ .redacted_reasoning = .{ .data = try gpa.dupe(u8, value.data) } },
            .tool => |value| .{ .tool = .{
                .call_id = try gpa.dupe(u8, value.call_id),
                .name = try gpa.dupe(u8, value.name),
                .arguments = try gpa.dupe(u8, value.arguments),
            } },
        };
    }
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
