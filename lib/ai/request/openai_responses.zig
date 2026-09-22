//! Serialize OpenAI Responses requests from the block IR.

const std = @import("std");
const ir = @import("ir.zig");
const json = @import("json.zig");
const request_testing = @import("testing.zig");
const types = @import("../types.zig");

/// The Codex backend refuses a request that folds in no system prompt.
const default_instructions = "You are a helpful assistant.";

/// Write the OpenAI Responses request body for `request` and `blocks`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, blocks: []const ir.Block) !void {
    const wire = request.wire.openai_responses;
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try json.field(&jw, "model", request.model);
    try json.field(&jw, "stream", true);
    // The caller owns the input history, so the endpoint never keeps a copy.
    try json.field(&jw, "store", false);

    // A stable key sends every round of one session to the same cache node.
    if (wire.cache_key.len != 0) try json.field(&jw, "prompt_cache_key", wire.cache_key);

    // An explicit breakpoint pins the last user text; the implicit one still tracks the tail of a tool loop.
    const cache_index = if (wire.cache) lastUserText(blocks) else null;

    // The Codex backend refuses the sampling limits an API key accepts.
    switch (wire.dialect) {
        .standard => {
            if (request.max_output_tokens) |limit| try json.field(&jw, "max_output_tokens", limit);
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
    } else if (wire.dialect == .codex) {
        try json.field(&jw, "instructions", default_instructions);
    }

    // A deferred tool needs the native search tool, so a request that defers declares the search tool natively.
    const native = for (request.tools) |tool| {
        if (tool.defer_loading) break true;
    } else false;
    if (request.tools.len != 0) {
        try jw.objectField("tools");
        try jw.beginArray();
        for (request.tools) |tool| {
            try jw.beginObject();
            if (native and std.mem.eql(u8, tool.name, ir.search_tool_name)) {
                try json.field(&jw, "type", "tool_search");
                try json.field(&jw, "execution", "client");
                try json.field(&jw, "description", tool.description);
                try jw.objectField("parameters");
                try json.writeRawJson(&jw, tool.input_schema);
            } else {
                try json.field(&jw, "type", "function");
                try json.field(&jw, "name", tool.name);
                try json.field(&jw, "description", tool.description);
                if (tool.defer_loading) try json.field(&jw, "defer_loading", true);
                try jw.objectField("parameters");
                try json.writeRawJson(&jw, tool.input_schema);
                try json.field(&jw, "strict", tool.strict);
            }
            try jw.endObject();
        }
        try jw.endArray();
        try json.field(&jw, "tool_choice", @tagName(request.tool_choice));
    }

    try jw.objectField("input");
    try jw.beginArray();
    var message: ?Message = null;
    for (blocks, 0..) |block, index| {
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
                std.debug.assert(block.role == .user); // `validate` gives media the user role.
                try ensureMessage(&jw, &message, .user);
                try writeMedia(&jw, media);
            },
            .reasoning => |reasoning| {
                // Omit reasoning state when it has no encrypted content.
                if (reasoning.signature.len == 0) continue;
                try closeMessage(&jw, &message);
                try writeReasoningItem(&jw, reasoning.text, reasoning.signature);
            },
            .redacted_reasoning => |data| {
                // Omit reasoning state when it has no encrypted content.
                if (data.len == 0) continue;
                try closeMessage(&jw, &message);
                try writeReasoningItem(&jw, null, data);
            },
            .tool_use => |tool_use| {
                try closeMessage(&jw, &message);
                try jw.beginObject();
                if (native and std.mem.eql(u8, tool_use.name, ir.search_tool_name)) {
                    try json.field(&jw, "type", "tool_search_call");
                    try json.field(&jw, "execution", "client");
                    try json.field(&jw, "call_id", tool_use.call_id);
                    try json.field(&jw, "status", "completed");
                    try jw.objectField("arguments");
                    try json.writeRawJson(&jw, tool_use.arguments);
                } else {
                    try json.field(&jw, "type", "function_call");
                    try json.field(&jw, "call_id", tool_use.call_id);
                    try json.field(&jw, "name", tool_use.name);
                    try json.field(&jw, "arguments", tool_use.arguments);
                }
                try jw.endObject();
            },
            .tool_result => |tool_result| {
                try closeMessage(&jw, &message);
                if (native and answersSearch(blocks[0..index], tool_result.call_id)) {
                    try writeSearchOutput(&jw, request.tools, tool_result);
                    continue;
                }
                try jw.beginObject();
                if (tool_result.loaded.len != 0) return error.UnsupportedLoadedTools;
                try json.field(&jw, "type", "function_call_output");
                try json.field(&jw, "call_id", tool_result.call_id);
                if (tool_result.media.len == 0) {
                    try json.field(&jw, "output", tool_result.content);
                } else {
                    try jw.objectField("output");
                    try jw.beginArray();
                    if (tool_result.content.len != 0) {
                        try jw.beginObject();
                        try json.field(&jw, "type", "input_text");
                        try json.field(&jw, "text", tool_result.content);
                        try jw.endObject();
                    }
                    for (tool_result.media) |media| try writeMedia(&jw, media);
                    try jw.endArray();
                }
                try jw.endObject();
            },
        }
    }
    try closeMessage(&jw, &message);
    try jw.endArray();
    try jw.endObject();
}

/// Return the last user text block. A breakpoint on a tool result is accepted but never writes a cache.
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

fn writeReasoningItem(jw: *std.json.Stringify, summary: ?[]const u8, signature: []const u8) !void {
    std.debug.assert(signature.len != 0);
    try jw.beginObject();
    try json.field(jw, "type", "reasoning");
    try jw.objectField("summary");
    try jw.beginArray();
    if (summary) |text| {
        try jw.beginObject();
        try json.field(jw, "type", "summary_text");
        try json.field(jw, "text", text);
        try jw.endObject();
    }
    try jw.endArray();
    try json.field(jw, "encrypted_content", signature);
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

/// Report whether the call a result answers is the search tool. The call comes before its result.
fn answersSearch(before: []const ir.Block, call_id: []const u8) bool {
    var index = before.len;
    while (index > 0) {
        index -= 1;
        const value = before[index].value;
        if (value == .tool_use and std.mem.eql(u8, value.tool_use.call_id, call_id)) return std.mem.eql(u8, value.tool_use.name, ir.search_tool_name);
    }
    return false;
}

/// Answer a client search with its declarations. The output has no error member, so a failed search loads nothing.
fn writeSearchOutput(jw: *std.json.Stringify, tools: []const ir.Tool, tool_result: ir.Block.ToolResult) !void {
    try jw.beginObject();
    try json.field(jw, "type", "tool_search_output");
    try json.field(jw, "execution", "client");
    try json.field(jw, "call_id", tool_result.call_id);
    try json.field(jw, "status", "completed");
    try jw.objectField("tools");
    try jw.beginArray();
    for (tool_result.loaded) |name| {
        const loaded = ir.declaredTool(tools, name).?; // `validate` proves each loaded tool is declared.
        try jw.beginObject();
        try json.field(jw, "type", "function");
        try json.field(jw, "name", loaded.name);
        try json.field(jw, "description", loaded.description);
        try json.field(jw, "defer_loading", true);
        try jw.objectField("parameters");
        try json.writeRawJson(jw, loaded.input_schema);
        try json.field(jw, "strict", loaded.strict);
        try jw.endObject();
    }
    try jw.endArray();
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
const expectJson = request_testing.forSerializer(serialize).expectJson;

test "a plain user turn with a system prompt" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":1024,"instructions":"be brief","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .system = "be brief", .max_output_tokens = 1024 },
        &blocks,
    );
}

// The backend rejects a request that folds in no system prompt.
test "only the codex dialect drops the output ceiling and injects an instruction" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8 },
        &blocks,
    );

    // The ChatGPT backend refuses a request with no instructions, so only it gets the default.
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{ .dialect = .codex } }, .max_output_tokens = 8 },
        &blocks,
    );
}

test "a named effort rides on the responses request" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"reasoning":{"effort":"high","summary":"auto"},"include":["reasoning.encrypted_content"],"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8, .reasoning = .{ .effort = .high } },
        &blocks,
    );
}

// gpt-5.1 and later list `off`, and this endpoint spells it `none`.
test "off asks for no reasoning rather than omitting the control" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5.2","stream":true,"store":false,"max_output_tokens":8,"reasoning":{"effort":"none"},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5.2", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8, .reasoning = .off },
        &blocks,
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
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 64 },
        &blocks,
    );
}

test "a tool result with an image writes an output array" {
    const image: ir.Block.Media = .{ .source = .{ .bytes = "ab" }, .mime = "image/png" };
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = "read", .arguments = "{}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "PNG image", .is_error = false, .media = &.{image} } } },
    };
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"},{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_text","text":"PNG image"},{"type":"input_image","image_url":"data:image/png;base64,YWI=","detail":"auto"}]}]}
    , .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8 }, &blocks);
}

test "a reasoning block with no signature is omitted" {
    const blocks = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .reasoning = .{ .text = "think", .signature = "" } } },
        .{ .role = .assistant, .value = .{ .text = "done" } },
    };
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8 },
        &blocks,
    );
}

test "a deferred catalog declares the client search tool and replays a search as its native pair" {
    const tools = [_]ir.Tool{
        .{ .name = ir.search_tool_name, .description = "Find.", .input_schema = "{\"type\":\"object\"}" },
        .{ .name = "mcp_read", .description = "Read.", .input_schema = "{}", .defer_loading = true },
    };
    const blocks = [_]ir.Block{
        .{ .role = .user, .value = .{ .text = "go" } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = ir.search_tool_name, .arguments = "{\"query\":\"read\"}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "found", .is_error = false, .loaded = &.{"mcp_read"} } } },
    };
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"tool_search","execution":"client","description":"Find.","parameters":{"type":"object"}},{"type":"function","name":"mcp_read","description":"Read.","defer_loading":true,"parameters":{},"strict":false}],"tool_choice":"auto","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]},{"type":"tool_search_call","execution":"client","call_id":"call_1","status":"completed","arguments":{"query":"read"}},{"type":"tool_search_output","execution":"client","call_id":"call_1","status":"completed","tools":[{"type":"function","name":"mcp_read","description":"Read.","defer_loading":true,"parameters":{},"strict":false}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .tools = &tools, .max_output_tokens = 8 },
        &blocks,
    );
    // Without a deferred tool the search tool is an ordinary function and a loaded definition has no place.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedLoadedTools, serialize(&buf.writer, .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .tools = tools[0..1], .max_output_tokens = 8 }, &blocks));
}

test "tools declare a flat raw schema with strict mode" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"function","name":"run","description":"run a command","parameters":{"type":"object"},"strict":false}],"tool_choice":"auto","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .tools = &tools, .max_output_tokens = 8 },
        &blocks,
    );
}

test "a schema constrains the response through the text format" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"text":{"format":{"type":"json_schema","name":"person","schema":{"type":"object"},"strict":true}},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}" } },
        &blocks,
    );

    // A caller that turns strict mode off must reach the wire, or the schema stops being a guarantee.
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"text":{"format":{"type":"json_schema","name":"person","schema":{"type":"object"},"strict":false}},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}", .strict = false } },
        &blocks,
    );
}

test "this api reads no sound, so audio never reaches an input part" {
    // The Responses input union is text, image and file alone; audio needs Chat Completions.
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "audio/wav" } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8 }, &blocks));
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
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8 },
        &blocks,
    );
}

test "an explicit breakpoint marks the last user text and never disables the implicit one" {
    const blocks = [_]ir.Block{
        .{ .role = .user, .value = .{ .text = "one" } },
        .{ .role = .assistant, .value = .{ .text = "two" } },
        .{ .role = .user, .value = .{ .text = "three" } },
    };
    try expectJson(
        \\{"model":"gpt-5.6","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"three","prompt_cache_breakpoint":{"mode":"explicit"}}]}]}
    ,
        .{ .model = "gpt-5.6", .wire = .{ .openai_responses = .{ .cache = true } }, .max_output_tokens = 8 },
        &blocks,
    );

    // Explicit mode would drop the implicit breakpoint, and a tool loop needs it to reach the tail.
    var explicit: std.Io.Writer.Allocating = .init(testing.allocator);
    defer explicit.deinit();
    try serialize(&explicit.writer, .{ .model = "gpt-5.6", .wire = .{ .openai_responses = .{ .cache = true } }, .max_output_tokens = 8 }, &blocks);
    try testing.expect(std.mem.indexOf(u8, explicit.written(), "prompt_cache_options") == null);

    // A route that marks nothing writes neither member.
    var unmarked: std.Io.Writer.Allocating = .init(testing.allocator);
    defer unmarked.deinit();
    try serialize(&unmarked.writer, .{ .model = "gpt-5.6", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8 }, &blocks);
    try testing.expect(std.mem.indexOf(u8, unmarked.written(), "prompt_cache") == null);
}

test "a cache key rides every dialect and does not need a breakpoint marker" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .tool_result = .{ .call_id = "c1", .content = "ok", .is_error = false } } }};
    // The codex route marks no breakpoint, so the key is the only cache control it carries.
    try expectJson(
        \\{"model":"gpt-5.6","stream":true,"store":false,"prompt_cache_key":"0123456789abcdef","instructions":"You are a helpful assistant.","input":[{"type":"function_call_output","call_id":"c1","output":"ok"}]}
    ,
        .{ .model = "gpt-5.6", .wire = .{ .openai_responses = .{ .cache_key = "0123456789abcdef", .dialect = .codex } }, .max_output_tokens = 8 },
        &blocks,
    );

    // An empty key writes no member, so a route that never sets one keeps its old body.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try serialize(&buf.writer, .{ .model = "gpt-5.6", .wire = .{ .openai_responses = .{ .cache = true } }, .max_output_tokens = 8 }, &blocks);
    try testing.expect(std.mem.indexOf(u8, buf.written(), "prompt_cache_key") == null);
}

test "a turn with no user text carries no breakpoint" {
    // The endpoint refuses a breakpoint on instructions, so a tool-result-only turn marks nothing.
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .tool_result = .{ .call_id = "c1", .content = "ok", .is_error = false } } }};
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try serialize(&buf.writer, .{ .model = "gpt-5.6", .wire = .{ .openai_responses = .{ .cache = true } }, .max_output_tokens = 8 }, &blocks);
    try testing.expect(std.mem.indexOf(u8, buf.written(), "prompt_cache") == null);
}

test "the codex dialect refuses the sampling members too" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"temperature":0.7,"top_p":0.9,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{} }, .max_output_tokens = 8, .temperature = 0.7, .top_p = 0.9 },
        &blocks,
    );

    // The ChatGPT backend refuses every sampling limit, exactly as it refuses the token ceiling.
    try expectJson(
        \\{"model":"gpt-5","stream":true,"store":false,"instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}
    ,
        .{ .model = "gpt-5", .wire = .{ .openai_responses = .{ .dialect = .codex } }, .max_output_tokens = 8, .temperature = 0.7, .top_p = 0.9 },
        &blocks,
    );
}
