//! The OpenAI Responses request serializer. It reads the Block IR and writes
//! the Responses API JSON.

const std = @import("std");
const wire = @import("wire");
const ir = @import("ir.zig");
const json = @import("json.zig");

pub const Options = struct {};

/// Write the OpenAI Responses request body for `request` and `request_ir`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, request_ir: ir.RequestIr, options: Options) !void {
    _ = options;
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(request.model);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("store");
    try jw.write(false);
    try jw.objectField("max_output_tokens");
    try jw.write(request.max_output_tokens);

    if (request.system.len != 0) {
        try jw.objectField("instructions");
        try jw.write(request.system);
    }

    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try jw.beginArray();
        for (request.tools) |tool| {
            try jw.beginObject();
            try json.field(&jw, "type", "function");
            try json.field(&jw, "name", tool.name);
            try json.field(&jw, "description", tool.description);
            try jw.objectField("parameters");
            try json.writeRawJson(&jw, tool.input_schema);
            try jw.objectField("strict");
            try jw.write(tool.strict);
            try jw.endObject();
        }
        try jw.endArray();
    }

    try jw.objectField("input");
    try jw.beginArray();
    var message: ?Message = null;
    for (request_ir.blocks) |block| {
        switch (block.value) {
            .text => |text| switch (block.role) {
                .user => {
                    try ensureMessage(&jw, &message, .user);
                    try jw.beginObject();
                    try json.field(&jw, "type", "input_text");
                    try json.field(&jw, "text", text);
                    try jw.endObject();
                },
                .assistant => {
                    try ensureMessage(&jw, &message, .assistant);
                    try jw.beginObject();
                    try json.field(&jw, "type", "output_text");
                    try json.field(&jw, "text", text);
                    try jw.endObject();
                },
            },
            .image => |image| {
                if (block.role != .user) return error.UnsupportedContent;
                try ensureMessage(&jw, &message, .user);
                try jw.beginObject();
                try json.field(&jw, "type", "input_image");
                try writeImageSource(&jw, image.source);
                try jw.endObject();
            },
            .audio, .file => return error.UnsupportedContent,
            .reasoning => |reasoning| {
                try closeMessage(&jw, &message);
                try jw.beginObject();
                try json.field(&jw, "type", "reasoning");
                try jw.objectField("summary");
                try jw.beginArray();
                try jw.beginObject();
                try json.field(&jw, "type", "summary_text");
                try json.field(&jw, "text", reasoning.text);
                try jw.endObject();
                try jw.endArray();
                try json.field(&jw, "encrypted_content", reasoning.signature);
                try jw.endObject();
            },
            .redacted_reasoning => |data| {
                try closeMessage(&jw, &message);
                try jw.beginObject();
                try json.field(&jw, "type", "reasoning");
                try jw.objectField("summary");
                try jw.beginArray();
                try jw.endArray();
                try json.field(&jw, "encrypted_content", data);
                try jw.endObject();
            },
            .tool_use => |tool_use| {
                try closeMessage(&jw, &message);
                try jw.beginObject();
                try json.field(&jw, "type", "function_call");
                try json.field(&jw, "call_id", tool_use.call_id);
                try json.field(&jw, "name", tool_use.name);
                try json.field(&jw, "arguments", tool_use.arguments);
                try jw.endObject();
            },
            .tool_result => |tool_result| {
                try closeMessage(&jw, &message);
                try jw.beginObject();
                try json.field(&jw, "type", "function_call_output");
                try json.field(&jw, "call_id", tool_result.call_id);
                try json.field(&jw, "output", tool_result.content);
                try jw.endObject();
            },
        }
    }
    try closeMessage(&jw, &message);
    try jw.endArray();
    try jw.endObject();
}

const Message = enum { user, assistant };

fn ensureMessage(jw: *std.json.Stringify, message: *?Message, role: Message) !void {
    if (message.* == role) return;
    try closeMessage(jw, message);
    try beginMessage(jw, role);
    message.* = role;
}

fn closeMessage(jw: *std.json.Stringify, message: *?Message) !void {
    if (message.* == null) return;
    try endMessage(jw);
    message.* = null;
}

fn beginMessage(jw: *std.json.Stringify, role: Message) !void {
    try jw.beginObject();
    try json.field(jw, "type", "message");
    try json.field(jw, "role", if (role == .user) "user" else "assistant");
    try jw.objectField("content");
    try jw.beginArray();
}

fn endMessage(jw: *std.json.Stringify) !void {
    try jw.endArray();
    try jw.endObject();
}

fn writeImageSource(jw: *std.json.Stringify, source: wire.content.MediaSource) !void {
    try jw.objectField("image_url");
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
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":1024,"instructions":"be brief","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .system = "be brief", .max_output_tokens = 1024 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "assistant reasoning text and tool call precede a tool result" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "check", .signature = "sig_1" } } },
        .{ .role = .assistant, .value = .{ .text = "checking" } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = "run", .arguments = "{\"c\":1}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "ok", .is_error = false } } },
    };
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":64,"input":[{"type":"reasoning","summary":[{"type":"summary_text","text":"check"}],"encrypted_content":"sig_1"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"checking"}]},{"type":"function_call","call_id":"call_1","name":"run","arguments":"{\"c\":1}"},{"type":"function_call_output","call_id":"call_1","output":"ok"}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 64 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "tools declare a flat raw schema with strict mode" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"function","name":"run","description":"run a command","parameters":{"type":"object"},"strict":false}],"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .tools = &tools, .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "a base64 user image writes a data URL" {
    const blocks = [_]ir.Block{.{
        .role = .user,
        .value = .{ .image = .{ .source = .{ .base64 = .{ .mime = "image/png", .data = "aGk=" } } } },
    }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,aGk="}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "audio content is unsupported on this dialect" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .audio = .{ .source = .{ .url = .{ .url = "http://x/a.mp3" } } } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "gpt-5", .max_output_tokens = 8 }, .{ .blocks = &blocks }, .{}));
}
