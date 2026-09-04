//! The request IR maps provider-neutral input to flat blocks.
//! IR strings borrow caller input. Keep the source storage alive through serialization.

const std = @import("std");
const types = @import("../types.zig");

pub const Role = enum { user, assistant };

/// A flat block. Its role selects the provider message.
pub const Block = struct {
    role: Role,
    value: Value,

    pub const Value = union(enum) {
        text: []const u8,
        media: Media,
        reasoning: Reasoning,
        redacted_reasoning: []const u8,
        tool_use: ToolUse,
        tool_result: ToolResult,
    };

    /// One attachment. Its media type selects the block each protocol writes.
    pub const Media = struct {
        source: types.MediaSource,
        /// The IANA media type, such as `image/png` or `application/pdf`.
        mime: []const u8,
        /// The name a provider requires beside file bytes. An image needs none.
        filename: []const u8 = "",

        /// Classify the media type. An unknown type is a document, which every protocol can refuse.
        pub fn modality(self: Media) types.Modality {
            return modalityOf(self.mime);
        }
    };

    pub const Reasoning = struct {
        text: []const u8,
        signature: []const u8,
    };

    pub const ToolUse = struct {
        call_id: []const u8,
        name: []const u8,
        /// Raw JSON object text from the caller.
        arguments: []const u8,
    };

    pub const ToolResult = struct {
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
    };
};

/// Classify one media type. An unknown type is a document, which every protocol can refuse.
pub fn modalityOf(mime: []const u8) types.Modality {
    if (std.mem.startsWith(u8, mime, "image/")) return .image;
    if (std.mem.startsWith(u8, mime, "audio/")) return .audio;
    if (std.mem.startsWith(u8, mime, "video/")) return .video;
    return .pdf;
}

/// Name what a model that cannot read this kind sees in place of the attachment.
pub fn omittedNote(kind: types.Modality) []const u8 {
    return switch (kind) {
        .image => "[image omitted: this model reads no images]",
        .audio => "[audio omitted: this model reads no audio]",
        .video => "[video omitted: this model reads no video]",
        .pdf => "[document omitted: this model reads no documents]",
        .text => unreachable, // `modalityOf` never answers text, because text is not an attachment.
    };
}

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

/// Constrain the response to a JSON Schema. The provider enforces it while it samples.
pub const OutputSchema = struct {
    /// The schema name OpenAI requires. Anthropic takes no name.
    name: []const u8 = "response",
    /// Raw JSON Schema text. It must describe an object.
    schema: []const u8,
    /// OpenAI strict mode. A non-strict schema gives no guarantee.
    strict: bool = true,
};

/// A named reasoning effort from the closed portable set.
pub const Effort = enum { minimal, low, medium, high, xhigh, max };

/// Select the Responses endpoint shape. The Codex backend refuses the sampling limits.
pub const ResponsesDialect = enum { standard, codex };

/// Select the output-token member an OpenAI-chat host accepts. Only OpenAI itself renamed it.
pub const MaxTokensField = enum { max_tokens, max_completion_tokens };

/// Select how a prior assistant turn returns its reasoning in an OpenAI-chat request.
/// DeepSeek rejects a thinking turn that comes back without it.
pub const ReasoningReplay = enum { none, reasoning, reasoning_content, reasoning_details };

/// Select the reasoning control an OpenAI-chat host accepts. The dialects disagree.
pub const ThinkingFormat = enum {
    none,
    openai,
    openrouter,
    deepseek,
    zai,
    qwen,
    together,
    string_thinking,
    ant_ling,
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

/// Provider request settings separate from the input blocks.
pub const Request = struct {
    model: []const u8,
    system: []const u8 = "",
    tools: []const Tool = &.{},
    max_output_tokens: u32,
    reasoning: ReasoningControl = .default,
    /// Only OpenAI-chat reads this field.
    thinking_format: ThinkingFormat = .none,
    /// Only OpenAI-chat reads this field.
    reasoning_replay: ReasoningReplay = .none,
    /// Only OpenAI-chat reads this field. A compatible host keeps the original member.
    max_tokens_field: MaxTokensField = .max_tokens,
    /// Only Responses reads this field. The bound credential selects it, not the model.
    responses_dialect: ResponsesDialect = .standard,
    /// The marker this request writes. The instance cache policy selects it.
    cache: types.CacheMarker = .none,
    /// Constrain the response to a schema. A null schema leaves the response free.
    output_schema: ?OutputSchema = null,
};

/// These options control the transcript fold.
pub const Options = struct {
    /// Replay reasoning only from a turn with this provenance.
    /// A null target drops all prior reasoning because signatures are model-specific.
    target: ?types.ModelIdentity = null,
    /// What the target model reads. An attachment it cannot read becomes a note instead.
    modalities: types.Modalities = .{},
};

pub fn validate(arena: std.mem.Allocator, request: Request, request_ir: RequestIr) !void {
    if (request.model.len == 0 or request.model.len > types.limits.max_string_bytes) return error.InvalidRequest;
    if (request.system.len > types.limits.max_string_bytes) return error.InvalidRequest;
    if (request.max_output_tokens == 0) return error.InvalidRequest;
    if (request_ir.blocks.len == 0 or request_ir.blocks.len > types.limits.max_blocks) return error.InvalidRequest;
    if (request.tools.len > types.limits.max_blocks) return error.InvalidRequest;

    for (request.tools) |tool| {
        if (tool.name.len == 0 or !stringValid(tool.name) or !stringValid(tool.description)) return error.InvalidRequest;
        try validateObject(arena, tool.input_schema);
    }
    if (request.output_schema) |output| {
        if (output.name.len == 0 or !stringValid(output.name)) return error.InvalidRequest;
        // An empty schema constrains nothing, so it is a caller mistake rather than a default.
        if (output.schema.len == 0) return error.InvalidRequest;
        try validateObject(arena, output.schema);
    }
    for (request_ir.blocks) |block| try validateBlock(arena, block);
}

fn validateBlock(arena: std.mem.Allocator, block: Block) !void {
    switch (block.value) {
        .text => |value| if (!stringValid(value)) return error.InvalidRequest,
        .media => |media| {
            if (block.role != .user) return error.InvalidRequest;
            if (media.mime.len == 0 or !stringValid(media.mime)) return error.InvalidRequest;
            if (!stringValid(media.filename)) return error.InvalidRequest;
            switch (media.source) {
                .bytes => |data| if (data.len == 0 or data.len > types.limits.max_media_bytes) return error.InvalidRequest,
                .url, .file_id => |value| if (value.len == 0 or !stringValid(value)) return error.InvalidRequest,
            }
        },
        .reasoning => |value| {
            if (block.role != .assistant) return error.InvalidRequest;
            if (!stringValid(value.text) or !stringValid(value.signature)) return error.InvalidRequest;
        },
        .redacted_reasoning => |value| {
            if (block.role != .assistant or !stringValid(value)) return error.InvalidRequest;
        },
        .tool_use => |value| {
            if (block.role != .assistant or value.call_id.len == 0 or value.name.len == 0) return error.InvalidRequest;
            if (!stringValid(value.call_id) or !stringValid(value.name)) return error.InvalidRequest;
            try validateObject(arena, value.arguments);
        },
        .tool_result => |value| {
            if (block.role != .user or value.call_id.len == 0) return error.InvalidRequest;
            if (!stringValid(value.call_id) or !stringValid(value.content)) return error.InvalidRequest;
        },
    }
}

fn stringValid(value: []const u8) bool {
    return value.len <= types.limits.max_string_bytes and std.unicode.utf8ValidateSlice(value);
}

fn validateObject(arena: std.mem.Allocator, raw: []const u8) !void {
    if (raw.len == 0) return;
    if (!stringValid(raw)) return error.InvalidRequest;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    if (value != .object) return error.InvalidRequest;
}

test "request validation rejects role mismatches and malformed raw JSON" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base: Request = .{ .model = "m", .max_output_tokens = 1 };

    const bad_role = [_]Block{.{ .role = .user, .value = .{ .reasoning = .{ .text = "why", .signature = "sig" } } }};
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &bad_role }));

    const bad_json = [_]Block{.{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call", .name = "tool", .arguments = "[1]" } } }};
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &bad_json }));
}

test "an output schema must name a JSON object" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = [_]Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    const request_ir: RequestIr = .{ .blocks = &blocks };
    const base: Request = .{ .model = "m", .max_output_tokens = 1 };
    try validate(arena.allocator(), base, request_ir);

    var not_an_object = base;
    not_an_object.output_schema = .{ .schema = "[1]" };
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), not_an_object, request_ir));

    // An empty schema constrains nothing, so it is a mistake rather than a default.
    var empty = base;
    empty.output_schema = .{ .schema = "" };
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), empty, request_ir));

    var unnamed = base;
    unnamed.output_schema = .{ .name = "", .schema = "{}" };
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), unnamed, request_ir));
}
