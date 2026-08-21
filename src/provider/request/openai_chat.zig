//! The OpenAI Chat Completions request serializer. It reads the Block IR and
//! writes the dialect JSON. Tool results always use standalone messages.

const std = @import("std");
const wire = @import("wire");
const ir = @import("ir.zig");
const json = @import("json.zig");

pub const Options = struct {};

/// Write the OpenAI Chat Completions request body to `w`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, request_ir: ir.RequestIr, options: Options) !void {
    _ = options;
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(request.model);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("stream_options");
    try jw.beginObject();
    try jw.objectField("include_usage");
    try jw.write(true);
    try jw.endObject();
    try jw.objectField("max_completion_tokens");
    try jw.write(request.max_output_tokens);

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
                    try writeAssistantMessage(&jw, request_ir.blocks[block_index..end_index]);
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
                try jw.beginObject();
                try json.field(jw, "type", "text");
                try json.field(jw, "text", text);
                try jw.endObject();
            },
            .image => |image| try writeImage(jw, image.source),
            .audio, .file, .reasoning, .redacted_reasoning, .tool_use, .tool_result => return error.UnsupportedContent,
        }
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeAssistantMessage(jw: *std.json.Stringify, blocks: []const ir.Block) !void {
    std.debug.assert(blocks.len != 0);
    std.debug.assert(blocks[0].role == .assistant);

    var has_text = false;
    var has_tool_calls = false;
    for (blocks) |block| {
        std.debug.assert(block.role == .assistant);
        switch (block.value) {
            .text => has_text = true,
            .tool_use => has_tool_calls = true,
            .audio, .file, .image, .reasoning, .redacted_reasoning, .tool_result => return error.UnsupportedContent,
        }
    }

    try jw.beginObject();
    try json.field(jw, "role", "assistant");
    try jw.objectField("content");
    if (has_text) {
        try jw.beginArray();
        for (blocks) |block| switch (block.value) {
            .text => |text| {
                try jw.beginObject();
                try json.field(jw, "type", "text");
                try json.field(jw, "text", text);
                try jw.endObject();
            },
            .tool_use => {},
            else => unreachable,
        };
        try jw.endArray();
    } else {
        try jw.write(null);
    }

    if (has_tool_calls) {
        try jw.objectField("tool_calls");
        try jw.beginArray();
        for (blocks) |block| switch (block.value) {
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

fn writeToolResult(jw: *std.json.Stringify, tool_result: ir.Block.ToolResult) !void {
    try jw.beginObject();
    try json.field(jw, "role", "tool");
    try json.field(jw, "tool_call_id", tool_result.call_id);
    try json.field(jw, "content", tool_result.content);
    try jw.endObject();
}

fn writeImage(jw: *std.json.Stringify, source: wire.content.MediaSource) !void {
    try jw.beginObject();
    try json.field(jw, "type", "image_url");
    try jw.objectField("image_url");
    try jw.beginObject();
    try writeImageSource(jw, source);
    try jw.endObject();
    try jw.endObject();
}

fn writeImageSource(jw: *std.json.Stringify, source: wire.content.MediaSource) !void {
    try jw.objectField("url");
    switch (source) {
        .url => |url| try jw.write(url.url),
        .base64 => |base64| try json.writeDataUrl(jw, base64.mime, base64.data),
        // The daemon resolves a blob to bytes before serialization.
        .blob => return error.UnsupportedContent,
    }
}

const testing = std.testing;

fn expectJson(expected: []const u8, request: ir.Request, request_ir: ir.RequestIr, options: Options) !void {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try serialize(&buf.writer, request, request_ir, options);
    try testing.expectEqualStrings(expected, buf.written());
}

test "a plain user turn with a system prompt" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_completion_tokens":1024,"messages":[{"role":"system","content":"be brief"},{"role":"user","content":[{"type":"text","text":"hello"}]}]}
    ,
        .{ .model = "gpt", .system = "be brief", .max_output_tokens = 1024 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "an assistant tool call has a JSON string and its result is standalone" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .text = "checking" } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = "run", .arguments = "{\"c\":1}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "ok", .is_error = false } } },
    };
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_completion_tokens":64,"messages":[{"role":"assistant","content":[{"type":"text","text":"checking"}],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"run","arguments":"{\"c\":1}"}}]},{"role":"tool","tool_call_id":"call_1","content":"ok"}]}
    ,
        .{ .model = "gpt", .max_output_tokens = 64 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "tools declare a raw input schema and strict mode" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_completion_tokens":8,"tools":[{"type":"function","function":{"name":"run","description":"run a command","parameters":{"type":"object"},"strict":false}}],"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "gpt", .tools = &tools, .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "a base64 image uses a data URL" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .image = .{ .source = .{ .base64 = .{ .mime = "image/png", .data = "aGk=" } } } } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_completion_tokens":8,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,aGk="}}]}]}
    ,
        .{ .model = "gpt", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "audio content is unsupported on this dialect" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .audio = .{ .source = .{ .url = .{ .url = "http://x/a.mp3" } } } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "gpt", .max_output_tokens = 8 }, .{ .blocks = &blocks }, .{}));
}
