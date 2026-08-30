//! The request IR stays neutral. `build` maps a transcript to flat blocks. Serializers read the IR instead of `wire.Message`.
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

/// A tool definition for the provider. `input_schema` holds raw JSON Schema text.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    /// OpenAI strict mode is off by default. A non-strict schema returns 400 when strict mode is on.
    strict: bool = false,
};

/// A named reasoning effort. The set is closed: the catalog only publishes these.
pub const Effort = enum { minimal, low, medium, high, xhigh, max };

/// Select the reasoning control an OpenAI-chat host accepts. The dialects disagree.
pub const ThinkingFormat = enum {
    none,
    openai,
    openrouter,
    deepseek,
    zai,
    qwen,
    together,
    @"string-thinking",
    @"ant-ling",
};

/// The reasoning control one request asks for, resolved against the model.
pub const ReasoningControl = union(enum) {
    /// Omit the control. The endpoint default stays.
    default,
    /// Ask for no reasoning. Some hosts accept the field and reason again.
    off,
    /// Let the model choose when and how much to think.
    adaptive,
    /// A thinking-token budget, clamped below `max_output_tokens`.
    budget: u64,
    effort: Effort,
};

/// A provider request without the transcript. The daemon assembles it per turn.
pub const Request = struct {
    model: []const u8,
    system: []const u8 = "",
    tools: []const Tool = &.{},
    max_output_tokens: u32,
    reasoning: ReasoningControl = .default,
    /// Only OpenAI-chat reads this field.
    thinking_format: ThinkingFormat = .none,
};

/// These options control the transcript fold.
pub const Options = struct {
    /// Replay reasoning only from a turn with this provenance.
    /// A null target drops all prior reasoning because signatures are model-specific.
    target: ?wire.message.TurnProvenance = null,
};
