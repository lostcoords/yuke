//! Serialize OpenAI Chat Completions requests from the block IR.

const std = @import("std");
const ir = @import("ir.zig");
const json = @import("json.zig");
const types = @import("../types.zig");

/// Write the OpenAI Chat Completions request body to `w`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, request_ir: ir.RequestIr) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(request.model);
    try jw.objectField("stream");
    try jw.write(true);
    try json.nested(&jw, "stream_options", "include_usage", true);
    // The caller owns the input history, so the endpoint never keeps a copy.
    try jw.objectField("store");
    try jw.write(false);
    try jw.objectField(switch (request.max_tokens_field) {
        .@"max-tokens" => "max_tokens",
        .@"max-completion-tokens" => "max_completion_tokens",
    });
    try jw.write(request.max_output_tokens);
    try writeReasoning(&jw, request.thinking_format, request.reasoning);
    try writeResponseFormat(&jw, request.output_schema);

    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try jw.beginArray();
        for (request.tools) |tool| {
            try jw.beginObject();
            try json.field(&jw, "type", "function");
            try jw.objectField("function");
            try jw.beginObject();
            try json.field(&jw, "name", tool.name);
            try json.field(&jw, "description", tool.description);
            try jw.objectField("parameters");
            try json.writeRawJson(&jw, tool.input_schema);
            try jw.objectField("strict");
            try jw.write(tool.strict);
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
    }

    try jw.objectField("messages");
    try jw.beginArray();
    if (request.system.len != 0) {
        try jw.beginObject();
        try json.field(&jw, "role", "system");
        try json.field(&jw, "content", request.system);
        try jw.endObject();
    }

    var block_index: usize = 0;
    while (block_index < request_ir.blocks.len) {
        const block = request_ir.blocks[block_index];
        switch (block.value) {
            .tool_result => {
                try writeToolResult(&jw, block.value.tool_result);
                block_index += 1;
            },
            else => switch (block.role) {
                .user => {
                    const end_index = userMessageEnd(request_ir.blocks, block_index);
                    try writeUserMessage(&jw, request_ir.blocks[block_index..end_index]);
                    block_index = end_index;
                },
                .assistant => {
                    const end_index = assistantMessageEnd(request_ir.blocks, block_index);
                    try writeAssistantMessage(&jw, request_ir.blocks[block_index..end_index], request.reasoning_replay);
                    block_index = end_index;
                },
            },
        }
    }
    try jw.endArray();

    try jw.endObject();
}

fn userMessageEnd(blocks: []const ir.Block, start: usize) usize {
    std.debug.assert(start < blocks.len);
    std.debug.assert(blocks[start].role == .user);
    std.debug.assert(blocks[start].value != .tool_result);

    var end = start + 1;
    while (end < blocks.len and blocks[end].role == .user and blocks[end].value != .tool_result) : (end += 1) {}
    return end;
}

fn assistantMessageEnd(blocks: []const ir.Block, start: usize) usize {
    std.debug.assert(start < blocks.len);
    std.debug.assert(blocks[start].role == .assistant);

    var end = start + 1;
    while (end < blocks.len and blocks[end].role == .assistant) : (end += 1) {}
    return end;
}

fn writeUserMessage(jw: *std.json.Stringify, blocks: []const ir.Block) !void {
    std.debug.assert(blocks.len != 0);
    std.debug.assert(blocks[0].role == .user);

    try jw.beginObject();
    try json.field(jw, "role", "user");
    try jw.objectField("content");
    try jw.beginArray();
    for (blocks) |block| {
        std.debug.assert(block.role == .user);
        switch (block.value) {
            .text => |text| {
                try writeTextBlock(jw, text);
            },
            .image => |image| try writeImage(jw, image.source),
            .audio, .file, .reasoning, .redacted_reasoning, .tool_use, .tool_result => return error.UnsupportedContent,
        }
    }
    try jw.endArray();
    try jw.endObject();
}

/// Name the member that carries a replayed reasoning text, or null when the host takes none.
/// `reasoning_details` needs the provider array back byte for byte, which the reducer drops.
fn replayField(replay: ir.ReasoningReplay) ?[]const u8 {
    return switch (replay) {
        .none, .reasoning_details => null,
        .reasoning => "reasoning",
        .reasoning_content => "reasoning_content",
    };
}

fn writeAssistantMessage(jw: *std.json.Stringify, blocks: []const ir.Block, replay: ir.ReasoningReplay) !void {
    std.debug.assert(blocks.len != 0);
    std.debug.assert(blocks[0].role == .assistant);

    var has_text = false;
    var has_tool_calls = false;
    var has_reasoning = false;
    for (blocks) |block| {
        std.debug.assert(block.role == .assistant);
        switch (block.value) {
            .text => has_text = true,
            .tool_use => has_tool_calls = true,
            // A host that takes no replay drops the block. It is never a reason to fail the turn.
            .reasoning, .redacted_reasoning => has_reasoning = true,
            .audio, .file, .image, .tool_result => return error.UnsupportedContent,
        }
    }

    try jw.beginObject();
    try json.field(jw, "role", "assistant");
    try jw.objectField("content");
    if (has_text) {
        try jw.beginArray();
        for (blocks) |block| switch (block.value) {
            .text => |text| try writeTextBlock(jw, text),
            .tool_use, .reasoning, .redacted_reasoning => {},
            else => unreachable,
        };
        try jw.endArray();
    } else {
        try jw.write(null);
    }

    // DeepSeek answers 400 when a thinking turn returns without its reasoning.
    if (has_reasoning) {
        if (replayField(replay)) |field| {
            try jw.objectField(field);
            try jw.beginWriteRaw();
            try jw.writer.writeByte('"');
            for (blocks) |block| switch (block.value) {
                .reasoning => |r| try std.json.Stringify.encodeJsonStringChars(r.text, .{}, jw.writer),
                else => {},
            };
            try jw.writer.writeByte('"');
            jw.endWriteRaw();
        }
    }

    if (has_tool_calls) {
        try jw.objectField("tool_calls");
        try jw.beginArray();
        for (blocks) |block| switch (block.value) {
            .reasoning, .redacted_reasoning => {},
            .tool_use => |tool_use| {
                try jw.beginObject();
                try json.field(jw, "id", tool_use.call_id);
                try json.field(jw, "type", "function");
                try jw.objectField("function");
                try jw.beginObject();
                try json.field(jw, "name", tool_use.name);
                try json.field(jw, "arguments", tool_use.arguments);
                try jw.endObject();
                try jw.endObject();
            },
            .text => {},
            else => unreachable,
        };
        try jw.endArray();
    }
    try jw.endObject();
}

/// Constrain the response to a schema. The endpoint nests the schema one level deeper than Responses.
fn writeResponseFormat(jw: *std.json.Stringify, schema: ?ir.OutputSchema) !void {
    const output = schema orelse return;
    try jw.objectField("response_format");
    try jw.beginObject();
    try json.field(jw, "type", "json_schema");
    try jw.objectField("json_schema");
    try jw.beginObject();
    try json.field(jw, "name", output.name);
    try jw.objectField("schema");
    try json.writeRawJson(jw, output.schema);
    try jw.objectField("strict");
    try jw.write(output.strict);
    try jw.endObject();
    try jw.endObject();
}

fn writeTextBlock(jw: *std.json.Stringify, text: []const u8) !void {
    try jw.beginObject();
    try json.field(jw, "type", "text");
    try json.field(jw, "text", text);
    try jw.endObject();
}

fn writeToolResult(jw: *std.json.Stringify, tool_result: ir.Block.ToolResult) !void {
    try jw.beginObject();
    try json.field(jw, "role", "tool");
    try json.field(jw, "tool_call_id", tool_result.call_id);
    try json.field(jw, "content", tool_result.content);
    try jw.endObject();
}

fn writeImage(jw: *std.json.Stringify, source: types.MediaSource) !void {
    try jw.beginObject();
    try json.field(jw, "type", "image_url");
    try jw.objectField("image_url");
    try jw.beginObject();
    try writeImageSource(jw, source);
    try jw.endObject();
    try jw.endObject();
}

fn writeImageSource(jw: *std.json.Stringify, source: types.MediaSource) !void {
    try jw.objectField("url");
    switch (source) {
        // The caller resolves a blob to bytes before serialization.
        .blob => return error.UnsupportedContent,
    }
}

/// Write the reasoning control in the dialect of the host. Anthropic shapes write nothing.
fn writeReasoning(
    jw: *std.json.Stringify,
    format: ir.ThinkingFormat,
    reasoning: ir.ReasoningControl,
) !void {
    if (format == .none) return;
    const level: []const u8 = switch (reasoning) {
        .off => "none",
        .effort => |effort| @tagName(effort),
        .default, .adaptive, .budget => return,
    };
    const on = reasoning != .off;
    const switch_shape: []const u8 = if (on) "enabled" else "disabled";

    switch (format) {
        .none => unreachable,
        .openai => try json.field(jw, "reasoning_effort", level),
        .openrouter => try json.nested(jw, "reasoning", "effort", level),
        .together => try json.nested(jw, "reasoning", "enabled", on),
        .qwen => {
            try jw.objectField("enable_thinking");
            try jw.write(on);
        },
        .@"string-thinking" => try json.field(jw, "thinking", level),
        .@"ant-ling" => if (on) try json.nested(jw, "reasoning", "effort", level),
        .deepseek => {
            try json.nested(jw, "thinking", "type", switch_shape);
            if (on) try json.field(jw, "reasoning_effort", level);
        },
        // Only zai adds a second member, so it cannot use the shared shape.
        .zai => {
            try jw.objectField("thinking");
            try jw.beginObject();
            try json.field(jw, "type", switch_shape);
            try jw.objectField("clear_thinking");
            try jw.write(false);
            try jw.endObject();
        },
    }
}

const testing = std.testing;

fn expectJson(expected: []const u8, request: ir.Request, request_ir: ir.RequestIr) !void {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try serialize(&buf.writer, request, request_ir);
    try testing.expectEqualStrings(expected, buf.written());
}

// The live bug: a replayed reasoning block used to fail the whole turn.
test "a host with no replay drops the reasoning block instead of failing" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "ponder", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .text = "answer" } },
    };
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );
}

// DeepSeek answers 400 when a thinking turn returns without its reasoning.
test "a replay host carries the reasoning back on the assistant message" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "ponder", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .text = "answer" } },
    };
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer"}],"reasoning_content":"ponder"}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning_replay = .reasoning_content },
        .{ .blocks = &blocks },
    );
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer"}],"reasoning":"ponder"}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning_replay = .reasoning },
        .{ .blocks = &blocks },
    );
}

// The array form needs the provider structure back byte for byte, which we do not keep yet.
test "reasoning_details replays nothing rather than send a string" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "ponder", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .text = "answer" } },
    };
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning_replay = .reasoning_details },
        .{ .blocks = &blocks },
    );
}

test "a replayed reasoning text is escaped and joined across blocks" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "say \"hi\"\n", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "then stop", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .text = "ok" } },
    };
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":"ok"}],"reasoning_content":"say \"hi\"\nthen stop"}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning_replay = .reasoning_content },
        .{ .blocks = &blocks },
    );
}

// A reasoning-only turn keeps a null content and still carries the replay.
test "a reasoning block with no text leaves content null" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "only", .signature = "" } } },
    };
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":null,"reasoning_content":"only"}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning_replay = .reasoning_content },
        .{ .blocks = &blocks },
    );
}

// Only OpenAI renamed the member; every compatible host kept `max_tokens`.
test "the output-token member follows the host" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .max_tokens_field = .@"max-completion-tokens" },
        .{ .blocks = &blocks },
    );
}

test "each host dialect spells the reasoning control its own way" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    const cases = [_]struct { format: ir.ThinkingFormat, expected: []const u8 }{
        .{ .format = .openai, .expected = "\"reasoning_effort\":\"high\"" },
        .{ .format = .openrouter, .expected = "\"reasoning\":{\"effort\":\"high\"}" },
        .{ .format = .deepseek, .expected = "\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"high\"" },
        .{ .format = .zai, .expected = "\"thinking\":{\"type\":\"enabled\",\"clear_thinking\":false}" },
        .{ .format = .qwen, .expected = "\"enable_thinking\":true" },
        .{ .format = .together, .expected = "\"reasoning\":{\"enabled\":true}" },
        .{ .format = .@"string-thinking", .expected = "\"thinking\":\"high\"" },
        .{ .format = .@"ant-ling", .expected = "\"reasoning\":{\"effort\":\"high\"}" },
    };
    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try serialize(&buf.writer, .{
            .model = "m",
            .max_output_tokens = 8,
            .reasoning = .{ .effort = .high },
            .thinking_format = case.format,
        }, .{ .blocks = &blocks });
        try testing.expect(std.mem.indexOf(u8, buf.written(), case.expected) != null);
    }
}

test "off disables thinking in the dialect that has a switch" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    const cases = [_]struct { format: ir.ThinkingFormat, expected: []const u8 }{
        .{ .format = .qwen, .expected = "\"enable_thinking\":false" },
        .{ .format = .zai, .expected = "\"thinking\":{\"type\":\"disabled\",\"clear_thinking\":false}" },
        .{ .format = .together, .expected = "\"reasoning\":{\"enabled\":false}" },
        .{ .format = .openai, .expected = "\"reasoning_effort\":\"none\"" },
    };
    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try serialize(&buf.writer, .{
            .model = "m",
            .max_output_tokens = 8,
            .reasoning = .off,
            .thinking_format = case.format,
        }, .{ .blocks = &blocks });
        try testing.expect(std.mem.indexOf(u8, buf.written(), case.expected) != null);
    }
    var deepseek: std.Io.Writer.Allocating = .init(testing.allocator);
    defer deepseek.deinit();
    try serialize(&deepseek.writer, .{
        .model = "m",
        .max_output_tokens = 8,
        .reasoning = .off,
        .thinking_format = .deepseek,
    }, .{ .blocks = &blocks });
    try testing.expect(std.mem.indexOf(u8, deepseek.written(), "\"reasoning_effort\"") == null);
}

test "no dialect writes no control" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning = .{ .effort = .high }, .thinking_format = .none },
        .{ .blocks = &blocks },
    );
}

test "a plain user turn with a system prompt" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":1024,"messages":[{"role":"system","content":"be brief"},{"role":"user","content":[{"type":"text","text":"hello"}]}]}
    ,
        .{ .model = "gpt", .system = "be brief", .max_output_tokens = 1024 },
        .{ .blocks = &blocks },
    );
}

test "an assistant tool call has a JSON string and its result is standalone" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .text = "checking" } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = "run", .arguments = "{\"c\":1}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "ok", .is_error = false } } },
    };
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":64,"messages":[{"role":"assistant","content":[{"type":"text","text":"checking"}],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"run","arguments":"{\"c\":1}"}}]},{"role":"tool","tool_call_id":"call_1","content":"ok"}]}
    ,
        .{ .model = "gpt", .max_output_tokens = 64 },
        .{ .blocks = &blocks },
    );
}

test "tools declare a raw input schema and strict mode" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"tools":[{"type":"function","function":{"name":"run","description":"run a command","parameters":{"type":"object"},"strict":false}}],"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "gpt", .tools = &tools, .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );
}

test "a blob image waits for blob resolution" {
    const blocks = [_]ir.Block{.{
        .role = .user,
        .value = .{ .image = .{ .source = .{ .blob = .{ .hash = std.mem.zeroes([64]u8), .mime = "image/png", .bytes = 2 } } } },
    }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "gpt", .max_output_tokens = 8 }, .{ .blocks = &blocks }));
}

test "audio content is unsupported on this dialect" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .audio = .{ .source = .{ .blob = .{ .hash = std.mem.zeroes([64]u8), .mime = "audio/mpeg", .bytes = 2 } } } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "gpt", .max_output_tokens = 8 }, .{ .blocks = &blocks }));
}

test "a schema constrains the response through response_format" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object"},"strict":true}},"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}" } },
        .{ .blocks = &blocks },
    );
}
