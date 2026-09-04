//! Serialize an Anthropic Messages request from the neutral IR.
//! With `request.cache`, mark the system block and the last eligible content block. Some compatible hosts answer 400, so the instance policy decides.

const std = @import("std");
const ir = @import("ir.zig");
const json = @import("json.zig");
const types = @import("../types.zig");

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
    try writeOutputConfig(&jw, request.reasoning, request.output_schema);
    const cache = request.cache == .anthropic;

    if (request.system.len != 0) {
        try jw.objectField("system");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write(request.system);
        if (cache) try writeCacheControl(&jw);
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
    const cache_index = if (cache) lastCacheable(request_ir.blocks) else null;

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
        // An effort is a whole-request control, so `output_config` carries it instead.
        .default, .effort => return,
        .off => "disabled",
        .adaptive => "adaptive",
        .budget => "enabled",
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

/// Write `output_config`. The effort and the response format share the one object.
fn writeOutputConfig(jw: *std.json.Stringify, reasoning: ir.ReasoningControl, schema: ?ir.OutputSchema) !void {
    const effort: ?ir.Effort = switch (reasoning) {
        .effort => |value| value,
        else => null,
    };
    if (effort == null and schema == null) return;

    try jw.objectField("output_config");
    try jw.beginObject();
    if (effort) |value| try json.field(jw, "effort", @tagName(value));
    if (schema) |output| {
        // Anthropic constrains sampling from the schema alone; it takes no name and no strict flag.
        try jw.objectField("format");
        try jw.beginObject();
        try json.field(jw, "type", "json_schema");
        try jw.objectField("schema");
        try json.writeRawJson(jw, output.schema);
        try jw.endObject();
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
        .media => |media| try writeMedia(jw, media, cache),
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

/// Write one attachment. An image is an `image` block and every other document is a `document` block.
fn writeMedia(jw: *std.json.Stringify, media: ir.Block.Media, cache: bool) !void {
    const kind: []const u8 = switch (media.modality()) {
        .image => "image",
        .pdf => "document",
        // Anthropic reads no sound and no moving picture.
        .audio, .video, .text => return error.UnsupportedContent,
    };

    // A document is a PDF or plain text; any other media type has no source shape on this API.
    const plain_text = std.mem.startsWith(u8, media.mime, "text/");
    const is_document = std.mem.eql(u8, kind, "document");
    const is_pdf = std.mem.eql(u8, media.mime, "application/pdf");
    if (is_document and !plain_text and !is_pdf) return error.UnsupportedContent;

    try jw.beginObject();
    try json.field(jw, "type", kind);
    try jw.objectField("source");
    try jw.beginObject();
    switch (media.source) {
        .bytes => |data| {
            // Plain text rides in a `text` source, which carries the characters rather than base64.
            try json.field(jw, "type", if (plain_text) "text" else "base64");
            try json.field(jw, "media_type", media.mime);
            try jw.objectField("data");
            if (plain_text) try jw.write(data) else try json.writeBase64(jw, "", data);
        },
        .url => |value| {
            try json.field(jw, "type", "url");
            try json.field(jw, "url", value);
        },
        .file_id => |value| {
            try json.field(jw, "type", "file");
            try json.field(jw, "file_id", value);
        },
    }
    try jw.endObject();
    if (cache) try writeCacheControl(jw);
    try jw.endObject();
}

/// Return the last block that Anthropic accepts for a marker, or null. Skip thinking and redacted thinking blocks.
fn lastCacheable(blocks: []const ir.Block) ?usize {
    var i = blocks.len;
    while (i > 0) {
        i -= 1;
        switch (blocks[i].value) {
            .reasoning, .redacted_reasoning => {},
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
        .{ .model = "claude", .system = "sys", .max_output_tokens = 8, .cache = .anthropic },
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
        .{ .model = "claude", .max_output_tokens = 8, .cache = .anthropic },
        .{ .blocks = &blocks },
    );
}

test "an image and a document reach their own block shapes" {
    const blocks = [_]ir.Block{
        .{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "image/png" } } },
        .{ .role = .user, .value = .{ .media = .{ .source = .{ .url = "https://x.test/a.pdf" }, .mime = "application/pdf" } } },
        .{ .role = .user, .value = .{ .media = .{ .source = .{ .file_id = "file_1" }, .mime = "image/jpeg" } } },
    };
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"YWI="}},{"type":"document","source":{"type":"url","url":"https://x.test/a.pdf"}},{"type":"image","source":{"type":"file","file_id":"file_1"}}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );
}

test "anthropic reads no sound and no moving picture" {
    inline for (.{ "audio/mpeg", "video/mp4" }) |mime| {
        const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = mime } } }};
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "claude", .max_output_tokens = 8 }, .{ .blocks = &blocks }));
    }
}

test "a schema constrains the response through output_config" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"output_config":{"format":{"type":"json_schema","schema":{"type":"object"}}},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8, .output_schema = .{ .schema = "{\"type\":\"object\"}" } },
        .{ .blocks = &blocks },
    );
}

test "an effort and a schema share the one output_config" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hi" } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"output_config":{"effort":"high","format":{"type":"json_schema","schema":{"type":"object"}}},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ,
        .{
            .model = "claude",
            .max_output_tokens = 8,
            .reasoning = .{ .effort = .high },
            .output_schema = .{ .schema = "{\"type\":\"object\"}" },
        },
        .{ .blocks = &blocks },
    );
}

test "a plain-text document rides in a text source, and an unknown type is refused" {
    const text_doc = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "note" }, .mime = "text/plain" } } }};
    try expectJson(
        \\{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"document","source":{"type":"text","media_type":"text/plain","data":"note"}}]}]}
    ,
        .{ .model = "claude", .max_output_tokens = 8 },
        .{ .blocks = &text_doc },
    );

    // A document is a PDF or plain text; anything else has no source shape and must not be mislabelled.
    const spreadsheet = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "application/zip" } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "claude", .max_output_tokens = 8 }, .{ .blocks = &spreadsheet }));
}
