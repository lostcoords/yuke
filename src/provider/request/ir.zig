//! The neutral request IR. `build` maps a transcript to flat blocks.
//! Serializers read the IR, not `wire.Message`.
//!
//! IR strings borrow the transcript. Keep the transcript and block arena alive.

const wire = @import("wire");

pub const Role = enum { user, assistant };

/// A flat block. Its role selects the provider message.
pub const Block = struct {
    role: Role,
    value: Value,

    pub const Value = union(enum) {
        text: []const u8,
        image: Media,
        audio: Media,
        file: Media,
        reasoning: Reasoning,
        redacted_reasoning: []const u8,
        tool_use: ToolUse,
        tool_result: ToolResult,
    };

    pub const Media = struct {
        source: wire.content.MediaSource,
    };

    pub const Reasoning = struct {
        text: []const u8,
        signature: []const u8,
    };

    pub const ToolUse = struct {
        call_id: []const u8,
        name: []const u8,
        /// Raw JSON object text from the transcript.
        arguments: []const u8,
    };

    pub const ToolResult = struct {
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
    };
};

pub const RequestIr = struct {
    blocks: []const Block,
};

/// A tool definition for the provider. `input_schema` is raw JSON Schema text.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    /// OpenAI strict mode. Off by default; a non-strict schema returns 400 with it on.
    strict: bool = false,
};

/// A provider request without the transcript. The daemon assembles it per turn.
pub const Request = struct {
    model: []const u8,
    system: []const u8 = "",
    tools: []const Tool = &.{},
    max_output_tokens: u32,
};

/// Options for the transcript fold.
pub const Options = struct {
    /// Replay reasoning only from a turn with this provenance.
    /// A null target drops all prior reasoning because signatures are model-specific.
    target: ?wire.message.TurnProvenance = null,
};
