//! Serialize the Anthropic Messages request from the neutral IR. Coalesce adjacent blocks with the same role.
//! With `request.cache`, mark the system block and the last eligible content block. Some compatible hosts answer 400, so the instance policy decides.

const std = @import("std");
const proto = @import("proto");
const ir = @import("ir.zig");
const json = @import("json.zig");

/// Write the request JSON to `w`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, request_ir: ir.RequestIr) !void {
    std.debug.assert(request_ir.blocks.len != 0); // Anthropic needs at least one message.
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(request.model);
    try jw.objectField("max_tokens");
    try jw.write(request.max_output_tokens);
    try jw.objectField("stream");
    try jw.write(true);

    try writeThinking(&jw, request.reasoning);

    if (request.system.len != 0) {
        try jw.objectField("system");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write(request.system);
        if (request.cache) try writeCacheControl(&jw);
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
    const cache_index = if (request.cache) lastCacheable(request_ir.blocks) else null;

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

/// Write the thinking control. Compatible hosts take `adaptive`; Anthropic takes a budget.
fn writeThinking(jw: *std.json.Stringify, reasoning: ir.ReasoningControl) !void {
    const kind: []const u8 = switch (reasoning) {
        .default => return,
        .off => "disabled",
        .adaptive => "adaptive",
        .budget => "enabled",
        // An effort is a whole-request control, not a thinking shape.
        .effort => |effort| return json.nested(jw, "output_config", "effort", @tagName(effort)),
    };

    try jw.objectField("thinking");
    try jw.beginObject();
    try json.field(jw, "type", kind);
    if (reasoning == .budget) {
        try jw.objectField("budget_tokens");
        try jw.write(reasoning.budget);
    }
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

fn writeImageSource(jw: *std.json.Stringify, source: proto.content.MediaSource) !void {
    try jw.objectField("source");
    try jw.beginObject();
    switch (source) {
        // The engine must resolve blobs before serialization.
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
    try json.nested(jw, "cache_control", "type", "ephemeral");
}

const testing = std.testing;

fn expectJson(expected: []const u8, request: ir.Request, request_ir: ir.RequestIr) !void {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try serialize(&buf.writer, request, request_ir);
    try testing.expectEqualStrings(expected, buf.written());
}

test "a plain user turn with a system prompt" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":1024,"stream":true,"system":[{"type":"text","text":"be brief"}],"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}
    ,
        .{ .model = "claude", .system = "be brief", .max_output_tokens = 1024 },
        .{ .blocks = &blocks },
    );
}

test "adaptive thinking rides on the request" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    try expectJson(
        \\{"model":"MiniMax-M3","max_tokens":8,"stream":true,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{ .model = "MiniMax-M3", .max_output_tokens = 8, .reasoning = .adaptive },
        .{ .blocks = &blocks },
    );
}

test "a token budget writes the enabled shape" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8192,"stream":true,"thinking":{"type":"enabled","budget_tokens":4096},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8192, .reasoning = .{ .budget = 4096 } },
        .{ .blocks = &blocks },
    );
}

test "off writes disabled and the default omits the member" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"thinking":{"type":"disabled"},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8, .reasoning = .off },
        .{ .blocks = &blocks },
    );
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8, .reasoning = .default },
        .{ .blocks = &blocks },
    );
}

test "a named effort rides on output_config, not on thinking" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"output_config":{"effort":"high"},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8, .reasoning = .{ .effort = .high } },
        .{ .blocks = &blocks },
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
        .{ .model = "claude", .system = "sys", .max_output_tokens = 8, .cache = true },
        .{ .blocks = &blocks },
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
        .{ .model = "claude", .max_output_tokens = 8, .cache = true },
        .{ .blocks = &blocks },
    );
}

test "audio content is unsupported on this dialect" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .audio = .{ .source = .{ .blob = .{ .hash = std.mem.zeroes([64]u8), .mime = "audio/mpeg", .bytes = 2 } } } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "claude", .max_output_tokens = 8 }, .{ .blocks = &blocks }));
}
