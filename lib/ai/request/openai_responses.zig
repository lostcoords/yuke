//! Serialize OpenAI Responses requests from the block IR.

const std = @import("std");
const ir = @import("ir.zig");
const json = @import("json.zig");
const types = @import("../types.zig");

/// The Codex backend refuses a request that folds in no system prompt.
const default_instructions = "You are a helpful assistant.";

/// Write the OpenAI Responses request body for `request` and `request_ir`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, request_ir: ir.RequestIr) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(request.model);
    try jw.objectField("stream");
    try jw.write(true);
    // The caller owns the input history, so the endpoint never keeps a copy.
    try jw.objectField("store");
    try jw.write(false);

    // GPT-5.6 and later cache only what a breakpoint marks, and top-level instructions cannot carry one.
    const cache_index = if (request.cache == .openai) lastUserText(request_ir.blocks) else null;
    if (cache_index != null) try json.nested(&jw, "prompt_cache_options", "mode", "explicit");

    // The Codex backend refuses the sampling limits an API key accepts.
    switch (request.responses_dialect) {
        .standard => {
            try jw.objectField("max_output_tokens");
            try jw.write(request.max_output_tokens);
            try json.sampling(&jw, request.temperature, request.top_p);
        },
        .codex => {},
    }

    // Responses reasons by default, so only a named effort is worth a control.
    try writeReasoning(&jw, request.reasoning);
    try writeTextFormat(&jw, request.output_schema);

    // Only the Codex backend refuses a request with no instructions, so the standard one omits it.
    if (request.system.len != 0) {
        try json.field(&jw, "instructions", request.system);
    } else if (request.responses_dialect == .codex) {
        try json.field(&jw, "instructions", default_instructions);
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
        try json.field(&jw, "tool_choice", "auto");
    }

    try jw.objectField("input");
    try jw.beginArray();
    var message: ?Message = null;
    for (request_ir.blocks, 0..) |block, index| {
        switch (block.value) {
            .text => |text| switch (block.role) {
                .user => {
                    try ensureMessage(&jw, &message, .user);
                    try jw.beginObject();
                    try json.field(&jw, "type", "input_text");
                    try json.field(&jw, "text", text);
                    if (cache_index == index) try json.nested(&jw, "prompt_cache_breakpoint", "mode", "explicit");
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
            .media => |media| {
                if (block.role != .user) return error.UnsupportedContent;
                try ensureMessage(&jw, &message, .user);
                try writeMedia(&jw, media);
            },
            .reasoning => |reasoning| {
                // Omit reasoning state when it has no encrypted content.
                if (reasoning.signature.len == 0) continue;
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
                // Omit reasoning state when it has no encrypted content.
                if (data.len == 0) continue;
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

/// Return the last user text block, the only place this endpoint accepts a breakpoint.
fn lastUserText(blocks: []const ir.Block) ?usize {
    var i = blocks.len;
    while (i > 0) {
        i -= 1;
        if (blocks[i].role == .user and blocks[i].value == .text) return i;
    }
    return null;
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

fn writeReasoning(jw: *std.json.Stringify, reasoning: ir.ReasoningControl) !void {
    switch (reasoning) {
        // A model that lists `off` takes `none`. It writes no trace, so it needs no include.
        .off => try json.nested(jw, "reasoning", "effort", "none"),
        .effort => |effort| {
            try jw.objectField("reasoning");
            try jw.beginObject();
            try json.field(jw, "effort", @tagName(effort));
            // Encrypted traces have no visible text without a plaintext summary.
            try json.field(jw, "summary", "auto");
            try jw.endObject();
            try jw.objectField("include");
            try jw.beginArray();
            try jw.write("reasoning.encrypted_content");
            try jw.endArray();
        },
        .default, .adaptive, .budget => {},
    }
}

fn endMessage(jw: *std.json.Stringify) !void {
    try jw.endArray();
    try jw.endObject();
}

/// Constrain the response to a schema. Responses names the format under `text`, not `response_format`.
fn writeTextFormat(jw: *std.json.Stringify, schema: ?ir.OutputSchema) !void {
    const output = schema orelse return;
    try jw.objectField("text");
    try jw.beginObject();
    try jw.objectField("format");
    try jw.beginObject();
    try json.field(jw, "type", "json_schema");
    try json.schemaMembers(jw, output.name, output.schema, output.strict);
    try jw.endObject();
    try jw.endObject();
}

/// Write one attachment. Responses names the image URL as a plain string, not an object.
fn writeMedia(jw: *std.json.Stringify, media: ir.Block.Media) !void {
    try jw.beginObject();
    switch (media.modality()) {
        .image => {
            try json.field(jw, "type", "input_image");
            switch (media.source) {
                .bytes => |data| {
                    try jw.objectField("image_url");
                    try json.writeDataUrl(jw, media.mime, data);
                },
                .url => |value| try json.field(jw, "image_url", value),
                .file_id => |value| try json.field(jw, "file_id", value),
            }
            // The schema requires `detail`, and `auto` is the documented default.
            try json.field(jw, "detail", "auto");
        },
        .pdf => {
            try json.field(jw, "type", "input_file");
            switch (media.source) {
                .bytes => |data| {
                    if (media.filename.len == 0) return error.UnsupportedContent; // The endpoint names the file.
                    try json.field(jw, "filename", media.filename);
                    try jw.objectField("file_data");
                    try json.writeDataUrl(jw, media.mime, data);
                },
                .url => |value| try json.field(jw, "file_url", value),
                .file_id => |value| try json.field(jw, "file_id", value),
            }
        },
        // This API takes text, image and file alone. Sound needs the Chat Completions endpoint.
        .audio, .video, .text => return error.UnsupportedContent,
    }
    try jw.endObject();
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
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":1024,"instructions":"be brief","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .system = "be brief", .max_output_tokens = 1024 },
        .{ .blocks = &blocks },
    );
}

// The ChatGPT-account backend rejects the sampling limits an API key accepts.
test "the codex dialect omits the output ceiling" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .responses_dialect = .codex },
        .{ .blocks = &blocks },
    );
}

// The backend rejects a request that folds in no system prompt.
test "only the codex dialect injects an instruction when none is given" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );

    // The ChatGPT backend refuses a request with no instructions, so only it gets the default.
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .responses_dialect = .codex },
        .{ .blocks = &blocks },
    );
}

test "a named effort rides on the responses request" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"reasoning":{"effort":"high","summary":"auto"},"include":["reasoning.encrypted_content"],"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .reasoning = .{ .effort = .high } },
        .{ .blocks = &blocks },
    );
}

// gpt-5.1 and later list `off`, and this endpoint spells it `none`.
test "off asks for no reasoning rather than omitting the control" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5.2","stream":true,"store":false,"max_output_tokens":8,"reasoning":{"effort":"none"},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5.2", .max_output_tokens = 8, .reasoning = .off },
        .{ .blocks = &blocks },
    );
}

// gpt-4o has no reasoning levels. An empty session level resolves to .default and must omit the object.

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
    );
}

test "a reasoning block with no signature is omitted" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "think", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .text = "done" } },
    };
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );
}

test "tools declare a flat raw schema with strict mode" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"function","name":"run","description":"run a command","parameters":{"type":"object"},"strict":false}],"tool_choice":"auto","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .tools = &tools, .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );
}

test "a schema constrains the response through the text format" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"text":{"format":{"type":"json_schema","name":"person","schema":{"type":"object"},"strict":true}},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}" } },
        .{ .blocks = &blocks },
    );

    // A caller that turns strict mode off must reach the wire, or the schema stops being a guarantee.
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"text":{"format":{"type":"json_schema","name":"person","schema":{"type":"object"},"strict":false}},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}", .strict = false } },
        .{ .blocks = &blocks },
    );
}

test "this api reads no sound, so audio never reaches an input part" {
    // The Responses input union is text, image and file alone; audio needs Chat Completions.
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "audio/wav" } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "gpt-5", .max_output_tokens = 8 }, .{ .blocks = &blocks }));
}

test "each attachment kind reaches its own input part" {
    const blocks = [_]ir.Block{
        .{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "image/png" } } },
        .{ .role = .user, .value = .{ .media = .{ .source = .{ .file_id = "file_1" }, .mime = "image/jpeg" } } },
        .{ .role = .user, .value = .{ .media = .{ .source = .{ .url = "https://x.test/a.pdf" }, .mime = "application/pdf" } } },
    };
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,YWI=","detail":"auto"},{"type":"input_image","file_id":"file_1","detail":"auto"},{"type":"input_file","file_url":"https://x.test/a.pdf"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8 },
        .{ .blocks = &blocks },
    );
}

test "an explicit breakpoint marks the last user text and nothing else" {
    const blocks = [_]ir.Block{
        .{ .role = .user, .value = .{ .text = "one" } },
        .{ .role = .assistant, .value = .{ .text = "two" } },
        .{ .role = .user, .value = .{ .text = "three" } },
    };
    try expectJson(
        \\{"model":"gpt-5.6","stream":true,"store":false,"prompt_cache_options":{"mode":"explicit"},"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"three","prompt_cache_breakpoint":{"mode":"explicit"}}]}]}
    ,
        .{ .model = "gpt-5.6", .max_output_tokens = 8, .cache = .openai },
        .{ .blocks = &blocks },
    );

    // A route that marks nothing, or marks another protocol's shape, writes neither member.
    inline for (.{ types.CacheMarker.none, types.CacheMarker.anthropic }) |marker| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try serialize(&buf.writer, .{ .model = "gpt-5.6", .max_output_tokens = 8, .cache = marker }, .{ .blocks = &blocks });
        try testing.expect(std.mem.indexOf(u8, buf.written(), "prompt_cache") == null);
    }
}

test "a turn with no user text carries no breakpoint and no options member" {
    // The endpoint refuses a breakpoint on instructions, so a tool-result-only turn marks nothing.
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .tool_result = .{ .call_id = "c1", .content = "ok", .is_error = false } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try serialize(&buf.writer, .{ .model = "gpt-5.6", .max_output_tokens = 8, .cache = .openai }, .{ .blocks = &blocks });
    try testing.expect(std.mem.indexOf(u8, buf.written(), "prompt_cache") == null);
}

test "the codex dialect refuses the sampling members too" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"temperature":0.7,"top_p":0.9,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .temperature = 0.7, .top_p = 0.9 },
        .{ .blocks = &blocks },
    );

    // The ChatGPT backend refuses every sampling limit, exactly as it refuses the token ceiling.
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .max_output_tokens = 8, .temperature = 0.7, .top_p = 0.9, .responses_dialect = .codex },
        .{ .blocks = &blocks },
    );
}
