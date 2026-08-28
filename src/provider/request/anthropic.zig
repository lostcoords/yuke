//! Serialize the Anthropic Messages request from the neutral IR. Coalesce adjacent blocks with the same role.
//! With `cache`, mark the system block and the last eligible content block. Some compatible hosts reject `cache_control` with 400, so keep cache off by default.

const std = @import("std");
const wire = @import("wire");
const ir = @import("ir.zig");
const json = @import("json.zig");

pub const Options = struct {
    cache: bool = false,
};

/// Write the request JSON to `w`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, request_ir: ir.RequestIr, options: Options) !void {
    std.debug.assert(request_ir.blocks.len != 0); // Anthropic needs at least one message.
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(request.model);
    try jw.objectField("max_tokens");
    try jw.write(request.max_output_tokens);
    try jw.objectField("stream");
    try jw.write(true);

    if (request.system.len != 0) {
        try jw.objectField("system");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write(request.system);
        if (options.cache) try writeCacheControl(&jw);
        try jw.endObject();
        try jw.endArray();
    }

    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try jw.beginArray();
        for (request.tools) |tool| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tool.name);
            try jw.objectField("description");
            try jw.write(tool.description);
            try jw.objectField("input_schema");
            try json.writeRawJson(&jw, tool.input_schema);
            try jw.endObject();
        }
        try jw.endArray();
    }

    // A thinking block cannot carry the marker. Mark the last eligible block.
    const cache_index = if (options.cache) lastCacheable(request_ir.blocks) else null;

    try jw.objectField("messages");
    try jw.beginArray();
    var role: ?ir.Role = null;
    for (request_ir.blocks, 0..) |block, i| {
        if (role == null or role.? != block.role) {
            if (role != null) try endMessage(&jw);
            try beginMessage(&jw, block.role);
            role = block.role;
        }
        try writeBlock(&jw, block, cache_index == i);
    }
    if (role != null) try endMessage(&jw);
    try jw.endArray();

    try jw.endObject();
}

fn beginMessage(jw: *std.json.Stringify, role: ir.Role) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write(if (role == .user) "user" else "assistant");
    try jw.objectField("content");
    try jw.beginArray();
}

fn endMessage(jw: *std.json.Stringify) !void {
    try jw.endArray();
    try jw.endObject();
}

fn writeBlock(jw: *std.json.Stringify, block: ir.Block, cache: bool) !void {
    switch (block.value) {
        .text => |t| {
            try jw.beginObject();
            try json.field(jw, "type", "text");
            try json.field(jw, "text", t);
            if (cache) try writeCacheControl(jw);
            try jw.endObject();
        },
        .image => |m| {
            try jw.beginObject();
            try json.field(jw, "type", "image");
            try writeImageSource(jw, m.source);
            if (cache) try writeCacheControl(jw);
            try jw.endObject();
        },
        .audio, .file => return error.UnsupportedContent,
        .reasoning => |r| {
            std.debug.assert(block.role == .assistant);
            try jw.beginObject();
            try json.field(jw, "type", "thinking");
            try json.field(jw, "thinking", r.text);
            try json.field(jw, "signature", r.signature);
            try jw.endObject();
        },
        .redacted_reasoning => |data| {
            try jw.beginObject();
            try json.field(jw, "type", "redacted_thinking");
            try json.field(jw, "data", data);
            try jw.endObject();
        },
        .tool_use => |tu| {
            std.debug.assert(block.role == .assistant);
            try jw.beginObject();
            try json.field(jw, "type", "tool_use");
            try json.field(jw, "id", tu.call_id);
            try json.field(jw, "name", tu.name);
            try jw.objectField("input");
            try json.writeRawJson(jw, tu.arguments);
            if (cache) try writeCacheControl(jw);
            try jw.endObject();
        },
        .tool_result => |tr| {
            std.debug.assert(block.role == .user);
            try jw.beginObject();
            try json.field(jw, "type", "tool_result");
            try json.field(jw, "tool_use_id", tr.call_id);
            try json.field(jw, "content", tr.content);
            try jw.objectField("is_error");
            try jw.write(tr.is_error);
            if (cache) try writeCacheControl(jw);
            try jw.endObject();
        },
    }
}

fn writeImageSource(jw: *std.json.Stringify, source: wire.content.MediaSource) !void {
    try jw.objectField("source");
    try jw.beginObject();
    switch (source) {
        // The daemon must resolve blobs before serialization.
        .blob => return error.UnsupportedContent,
    }
    try jw.endObject();
}

/// Return the last block that Anthropic accepts for a marker, or null. Skip thinking and redacted thinking blocks.
fn lastCacheable(blocks: []const ir.Block) ?usize {
    var i = blocks.len;
    while (i > 0) {
        i -= 1;
        switch (blocks[i].value) {
            .reasoning, .redacted_reasoning, .audio, .file => {},
            else => return i,
        }
    }
    return null;
}

fn writeCacheControl(jw: *std.json.Stringify) !void {
    try jw.objectField("cache_control");
    try jw.beginObject();
    try json.field(jw, "type", "ephemeral");
    try jw.endObject();
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
        \\{"model":"claude","max_tokens":1024,"stream":true,"system":[{"type":"text","text":"be brief"}],"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}
    ,
        .{ .model = "claude", .system = "be brief", .max_output_tokens = 1024 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "a tool call and its result coalesce by role" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .text = "checking" } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "toolu_1", .name = "run", .arguments = "{\"c\":1}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "toolu_1", .content = "ok", .is_error = false } } },
    };
    try expectJson(
        \\{"model":"claude","max_tokens":64,"stream":true,"messages":[{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"toolu_1","name":"run","input":{"c":1}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok","is_error":false}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 64 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "tools declare a raw input schema" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"tools":[{"name":"run","description":"run a command","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "claude", .tools = &tools, .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{},
    );
}

test "cache marks the system block and the last content block" {
    const blocks = [_]ir.Block{
        .{ .role = .user, .value = .{ .text = "one" } },
        .{ .role = .user, .value = .{ .text = "two" } },
    };
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"system":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"one"},{"type":"text","text":"two","cache_control":{"type":"ephemeral"}}]}]}
    ,
        .{ .model = "claude", .system = "sys", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{ .cache = true },
    );
}

test "cache skips a trailing thinking block and marks the last eligible block" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .text = "answer" } },
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "ponder", .signature = "sig" } } },
    };
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer","cache_control":{"type":"ephemeral"}},{"type":"thinking","thinking":"ponder","signature":"sig"}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
        .{ .cache = true },
    );
}

test "audio content is unsupported on this dialect" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .audio = .{ .source = .{ .blob = .{ .hash = std.mem.zeroes([64]u8), .mime = "audio/mpeg", .bytes = 2 } } } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "claude", .max_output_tokens = 8 }, .{ .blocks = &blocks }, .{}));
}
