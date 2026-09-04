//! The request IR maps provider-neutral input to flat blocks, and borrows every caller string.

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

/// Select how a prior assistant turn returns its reasoning, which DeepSeek requires.
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
    /// Sampling temperature. A null value leaves the endpoint default, which every host defines.
    temperature: ?f64 = null,
    /// Nucleus sampling mass. Anthropic asks that a request set this or `temperature`, not both.
    top_p: ?f64 = null,
    /// Constrain the response to a schema. A null schema leaves the response free.
    output_schema: ?OutputSchema = null,
};

/// Check one request, and bound the input bytes it carries before a serializer reads it.
pub fn validate(arena: std.mem.Allocator, request: Request, request_ir: RequestIr) !void {
    if (request.model.len == 0 or request.model.len > types.limits.max_string_bytes) return error.InvalidRequest;
    if (request.system.len > types.limits.max_string_bytes) return error.InvalidRequest;
    if (request.max_output_tokens == 0) return error.InvalidRequest;
    if (request_ir.blocks.len == 0 or request_ir.blocks.len > types.limits.max_blocks) return error.InvalidRequest;
    if (request.tools.len > types.limits.max_blocks) return error.InvalidRequest;

    // A saturating total needs no overflow branch, because the cap rejects the saturated value.
    var total = request.model.len +| request.system.len;
    for (request.tools) |tool| {
        if (tool.name.len == 0 or !stringValid(tool.name) or !stringValid(tool.description)) return error.InvalidRequest;
        try validateObject(arena, tool.input_schema);
        total +|= tool.name.len +| tool.description.len +| tool.input_schema.len;
        if (total > types.limits.max_request_bytes) return error.RequestTooLarge;
    }
    // A non-finite value serializes to text no JSON parser accepts.
    if (request.temperature) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRequest;
    if (request.top_p) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidRequest;

    if (request.output_schema) |output| {
        if (output.name.len == 0 or !stringValid(output.name)) return error.InvalidRequest;
        // An empty schema constrains nothing, so it is a caller mistake rather than a default.
        if (output.schema.len == 0) return error.InvalidRequest;
        try validateObject(arena, output.schema);
        total +|= output.name.len +| output.schema.len;
    }
    for (request_ir.blocks) |block| {
        try validateBlock(arena, block);
        total +|= blockBytes(block);
        if (total > types.limits.max_request_bytes) return error.RequestTooLarge;
    }
}

/// Report the input bytes one block carries. The count bounds the request, so it needs no exactness.
fn blockBytes(block: Block) usize {
    return switch (block.value) {
        .text, .redacted_reasoning => |value| value.len,
        .media => |media| media.mime.len +| media.filename.len +| switch (media.source) {
            .bytes, .url, .file_id => |value| value.len,
        },
        .reasoning => |value| value.text.len +| value.signature.len,
        .tool_use => |value| value.call_id.len +| value.name.len +| value.arguments.len,
        .tool_result => |value| value.call_id.len +| value.content.len,
    };
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

    const bad_result_role = [_]Block{.{ .role = .assistant, .value = .{ .tool_result = .{ .call_id = "call", .content = "ok", .is_error = false } } }};
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &bad_result_role }));

    const bad_media_role = [_]Block{.{ .role = .assistant, .value = .{ .media = .{ .source = .{ .url = "https://example.test/image.png" }, .mime = "image/png" } } }};
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &bad_media_role }));

    const invalid_utf8 = [_]u8{0xff};
    const bad_text = [_]Block{.{ .role = .user, .value = .{ .text = &invalid_utf8 } }};
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &bad_text }));

    const empty_media = [_]Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "" }, .mime = "image/png" } } }};
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &empty_media }));
}

test "request validation enforces count, size, and token boundaries" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const block = [_]Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    const base: Request = .{ .model = "m", .max_output_tokens = 1 };

    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &.{} }));

    var no_tokens = base;
    no_tokens.max_output_tokens = 0;
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), no_tokens, .{ .blocks = &block }));

    const too_long = "x" ** (types.limits.max_string_bytes + 1);
    var long_model = base;
    long_model.model = too_long;
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), long_model, .{ .blocks = &block }));

    var too_many_blocks: [types.limits.max_blocks + 1]Block = undefined;
    for (&too_many_blocks) |*item| item.* = block[0];
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), base, .{ .blocks = &too_many_blocks }));

    var too_many_tools: [types.limits.max_blocks + 1]Tool = undefined;
    for (&too_many_tools) |*tool| tool.* = .{ .name = "tool", .description = "", .input_schema = "{}" };
    var many_tools = base;
    many_tools.tools = &too_many_tools;
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), many_tools, .{ .blocks = &block }));

    // The byte total is its own bound, because a legal block count still carries any size of text.
    const chunk = "x" ** types.limits.max_string_bytes;
    var oversized: [types.limits.max_request_bytes / chunk.len]Block = undefined;
    for (&oversized) |*item| item.* = .{ .role = .user, .value = .{ .text = chunk } };
    try testing.expectError(error.RequestTooLarge, validate(arena.allocator(), base, .{ .blocks = &oversized }));
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

test "a sampling value outside its domain is refused" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = [_]Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    const request_ir: RequestIr = .{ .blocks = &blocks };
    const base: Request = .{ .model = "m", .max_output_tokens = 1 };

    var hot = base;
    hot.temperature = -0.1;
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), hot, request_ir));

    // A non-finite value serializes to text no JSON parser accepts.
    var nan = base;
    nan.temperature = std.math.nan(f64);
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), nan, request_ir));

    var mass = base;
    mass.top_p = 1.5;
    try testing.expectError(error.InvalidRequest, validate(arena.allocator(), mass, request_ir));

    var ok = base;
    ok.temperature = 2;
    ok.top_p = 1;
    try validate(arena.allocator(), ok, request_ir);
}
