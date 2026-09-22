//! Serialize OpenAI Chat Completions requests from the block IR.

const std = @import("std");
const ir = @import("ir.zig");
const json = @import("json.zig");
const request_testing = @import("testing.zig");
const types = @import("../types.zig");

/// Write the OpenAI Chat Completions request body to `w`.
pub fn serialize(w: *std.Io.Writer, request: ir.Request, blocks: []const ir.Block) !void {
    for (request.tools) |tool| if (tool.defer_loading) return error.UnsupportedDeferredTools;
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();

    try json.field(&jw, "model", request.model);
    try json.field(&jw, "stream", true);
    try json.nested(&jw, "stream_options", "include_usage", true);
    // The caller owns the input history, so the endpoint never keeps a copy.
    try json.field(&jw, "store", false);
    try json.field(&jw, switch (request.max_tokens_field) {
        .max_tokens => "max_tokens",
        .max_completion_tokens => "max_completion_tokens",
    }, request.max_output_tokens);
    try json.sampling(&jw, request.temperature, request.top_p);
    // This endpoint writes no cache marker: OpenAI documents explicit breakpoints for Responses alone.
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
            try json.field(&jw, "strict", tool.strict);
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        // This host reads no member as the automatic control, so only a refusal writes one.
        if (request.tool_choice == .none) try json.field(&jw, "tool_choice", "none");
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
    while (block_index < blocks.len) {
        const block = blocks[block_index];
        switch (block.value) {
            .tool_result => {
                // A tool message holds text only, so the images of a run of results follow the run in one user message.
                const results = blocks[block_index..toolRunEnd(blocks, block_index)];
                var has_media = false;
                for (results) |result| {
                    std.debug.assert(result.role == .user and result.value == .tool_result);
                    const tool_result = result.value.tool_result;
                    try writeToolResult(&jw, tool_result);
                    has_media = has_media or tool_result.media.len != 0;
                }
                block_index += results.len;
                if (!has_media) continue;
                // A strict host refuses two user messages in a row, so the images join the user text that follows.
                const user_end = if (block_index < blocks.len and blocks[block_index].role == .user) userMessageEnd(blocks, block_index) else block_index;
                try writeUserMessage(&jw, results, blocks[block_index..user_end]);
                block_index = user_end;
            },
            else => switch (block.role) {
                .user => {
                    const end_index = userMessageEnd(blocks, block_index);
                    try writeUserMessage(&jw, &.{}, blocks[block_index..end_index]);
                    block_index = end_index;
                },
                .assistant => {
                    const end_index = assistantMessageEnd(blocks, block_index);
                    try writeAssistantMessage(&jw, blocks[block_index..end_index], request.reasoning_replay);
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

fn toolRunEnd(blocks: []const ir.Block, start: usize) usize {
    std.debug.assert(start < blocks.len);
    std.debug.assert(blocks[start].value == .tool_result);

    var end = start + 1;
    while (end < blocks.len and blocks[end].value == .tool_result) : (end += 1) {}
    return end;
}

fn assistantMessageEnd(blocks: []const ir.Block, start: usize) usize {
    std.debug.assert(start < blocks.len);
    std.debug.assert(blocks[start].role == .assistant);

    var end = start + 1;
    while (end < blocks.len and blocks[end].role == .assistant) : (end += 1) {}
    return end;
}

/// Write one user message. The images of `results` lead it, each under a label that names its call.
fn writeUserMessage(jw: *std.json.Stringify, results: []const ir.Block, blocks: []const ir.Block) !void {
    std.debug.assert(results.len != 0 or blocks.len != 0);
    std.debug.assert(blocks.len == 0 or blocks[0].role == .user);

    try jw.beginObject();
    try json.field(jw, "role", "user");
    try jw.objectField("content");
    try jw.beginArray();
    for (results) |result| {
        std.debug.assert(result.role == .user and result.value == .tool_result);
        for (result.value.tool_result.media) |media| {
            try writeImageLabel(jw, result.value.tool_result.call_id);
            try writeMedia(jw, media);
        }
    }
    for (blocks) |block| {
        std.debug.assert(block.role == .user);
        switch (block.value) {
            .text => |text| {
                try writeTextBlock(jw, text);
            },
            .media => |media| try writeMedia(jw, media),
            .reasoning, .redacted_reasoning, .tool_use, .tool_result => return error.UnsupportedContent,
        }
    }
    try jw.endArray();
    try jw.endObject();
}

/// Name the member that carries replayed reasoning, or null when the host takes none.
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
            .media, .tool_result => return error.UnsupportedContent,
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
    try json.schemaMembers(jw, output.name, output.schema, output.strict);
    try jw.endObject();
    try jw.endObject();
}

fn writeTextBlock(jw: *std.json.Stringify, text: []const u8) !void {
    try jw.beginObject();
    try json.field(jw, "type", "text");
    try json.field(jw, "text", text);
    try jw.endObject();
}

/// The label states which call the image belongs to, because it left that call's tool message.
fn writeImageLabel(jw: *std.json.Stringify, call_id: []const u8) !void {
    try jw.beginObject();
    try json.field(jw, "type", "text");
    try jw.objectField("text");
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    try std.json.Stringify.encodeJsonStringChars("Image from tool call ", .{}, jw.writer);
    try std.json.Stringify.encodeJsonStringChars(call_id, .{}, jw.writer);
    try jw.writer.writeAll(":\"");
    jw.endWriteRaw();
    try jw.endObject();
}

fn writeToolResult(jw: *std.json.Stringify, tool_result: ir.Block.ToolResult) !void {
    if (tool_result.tool_references.len != 0) return error.UnsupportedToolReferences;
    try jw.beginObject();
    try json.field(jw, "role", "tool");
    try json.field(jw, "tool_call_id", tool_result.call_id);
    try json.field(jw, "content", tool_result.content);
    try jw.endObject();
}

/// Write one attachment. This endpoint names a different part for each kind.
fn writeMedia(jw: *std.json.Stringify, media: ir.Block.Media) !void {
    switch (media.modality()) {
        .image => {
            try jw.beginObject();
            try json.field(jw, "type", "image_url");
            try jw.objectField("image_url");
            try jw.beginObject();
            try jw.objectField("url");
            // This part reads a URL alone, so bytes travel as a data URL and a handle has nowhere to go.
            switch (media.source) {
                .bytes => |data| try json.writeDataUrl(jw, media.mime, data),
                .url => |value| try jw.write(value),
                .file_id => return error.UnsupportedContent,
            }
            try jw.endObject();
            try jw.endObject();
        },
        .audio => {
            const format = try json.audioFormat(media.mime);
            const data = switch (media.source) {
                .bytes => |value| value,
                // The part carries raw base64 with no envelope, so it names neither a URL nor a handle.
                .url, .file_id => return error.UnsupportedContent,
            };
            try jw.beginObject();
            try json.field(jw, "type", "input_audio");
            try jw.objectField("input_audio");
            try jw.beginObject();
            try jw.objectField("data");
            try json.writeBase64(jw, "", data);
            try json.field(jw, "format", format);
            try jw.endObject();
            try jw.endObject();
        },
        .pdf => {
            try jw.beginObject();
            try json.field(jw, "type", "file");
            try jw.objectField("file");
            try jw.beginObject();
            switch (media.source) {
                .bytes => |data| {
                    if (media.filename.len == 0) return error.UnsupportedContent; // The endpoint names the file.
                    try jw.objectField("file_data");
                    try json.writeDataUrl(jw, media.mime, data);
                    try json.field(jw, "filename", media.filename);
                },
                .file_id => |value| try json.field(jw, "file_id", value),
                .url => return error.UnsupportedContent,
            }
            try jw.endObject();
            try jw.endObject();
        },
        .video, .text => return error.UnsupportedContent,
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
            try json.field(jw, "enable_thinking", on);
        },
        .string_thinking => try json.field(jw, "thinking", level),
        .ant_ling => if (on) try json.nested(jw, "reasoning", "effort", level),
        .deepseek => {
            try json.nested(jw, "thinking", "type", switch_shape);
            if (on) try json.field(jw, "reasoning_effort", level);
        },
        // Only zai adds a second member, so it cannot use the shared shape.
        .zai => {
            try jw.objectField("thinking");
            try jw.beginObject();
            try json.field(jw, "type", switch_shape);
            try json.field(jw, "clear_thinking", false);
            try jw.endObject();
        },
    }
}

const testing = std.testing;
const expectJson = request_testing.forSerializer(serialize).expectJson;

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
        &blocks,
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
        &blocks,
    );
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer"}],"reasoning":"ponder"}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning_replay = .reasoning },
        &blocks,
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
        &blocks,
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
        &blocks,
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
        &blocks,
    );
}

// Only OpenAI renamed the member; every compatible host kept `max_tokens`.
test "the output-token member follows the host" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .max_tokens_field = .max_completion_tokens },
        &blocks,
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
        .{ .format = .string_thinking, .expected = "\"thinking\":\"high\"" },
        .{ .format = .ant_ling, .expected = "\"reasoning\":{\"effort\":\"high\"}" },
    };
    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try serialize(&buf.writer, .{
            .model = "m",
            .max_output_tokens = 8,
            .reasoning = .{ .effort = .high },
            .thinking_format = case.format,
        }, &blocks);
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
        }, &blocks);
        try testing.expect(std.mem.indexOf(u8, buf.written(), case.expected) != null);
    }
    var deepseek: std.Io.Writer.Allocating = .init(testing.allocator);
    defer deepseek.deinit();
    try serialize(&deepseek.writer, .{
        .model = "m",
        .max_output_tokens = 8,
        .reasoning = .off,
        .thinking_format = .deepseek,
    }, &blocks);
    try testing.expect(std.mem.indexOf(u8, deepseek.written(), "\"reasoning_effort\"") == null);
}

test "no dialect writes no control" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .reasoning = .{ .effort = .high }, .thinking_format = .none },
        &blocks,
    );
}

test "a plain user turn with a system prompt" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":1024,"messages":[{"role":"system","content":"be brief"},{"role":"user","content":[{"type":"text","text":"hello"}]}]}
    ,
        .{ .model = "gpt", .system = "be brief", .max_output_tokens = 1024 },
        &blocks,
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
        &blocks,
    );
}

test "tool images follow the whole run of tool messages, or join the user text that follows" {
    const image: ir.Block.Media = .{ .source = .{ .bytes = "ab" }, .mime = "image/png" };
    const request: ir.Request = .{ .model = "gpt", .max_output_tokens = 8 };
    // A middle image tests both the media scan and the order of all three results.
    const run = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = "read", .arguments = "{}" } } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_2", .name = "read", .arguments = "{}" } } },
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_3", .name = "read", .arguments = "{}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "text", .is_error = false } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_2", .content = "PNG image", .is_error = false, .media = &.{image} } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_3", .content = "text", .is_error = false } } },
        .{ .role = .assistant, .value = .{ .text = "three files" } },
    };
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}},{"id":"call_2","type":"function","function":{"name":"read","arguments":"{}"}},{"id":"call_3","type":"function","function":{"name":"read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"text"},{"role":"tool","tool_call_id":"call_2","content":"PNG image"},{"role":"tool","tool_call_id":"call_3","content":"text"},{"role":"user","content":[{"type":"text","text":"Image from tool call call_2:"},{"type":"image_url","image_url":{"url":"data:image/png;base64,YWI="}}]},{"role":"assistant","content":[{"type":"text","text":"three files"}]}]}
    , request, &run);

    // A canceled turn ends on the result, so the next user text takes the image instead of a second user message.
    const merged = [_]ir.Block{
        .{ .role = .assistant, .value = .{ .tool_use = .{ .call_id = "call_1", .name = "read", .arguments = "{}" } } },
        .{ .role = .user, .value = .{ .tool_result = .{ .call_id = "call_1", .content = "PNG image", .is_error = false, .media = &.{image} } } },
        .{ .role = .user, .value = .{ .text = "what is it" } },
    };
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"PNG image"},{"role":"user","content":[{"type":"text","text":"Image from tool call call_1:"},{"type":"image_url","image_url":{"url":"data:image/png;base64,YWI="}},{"type":"text","text":"what is it"}]}]}
    , request, &merged);
}

test "tools declare a raw input schema and strict mode" {
    const tools = [_]ir.Tool{.{ .name = "run", .description = "run a command", .input_schema = "{\"type\":\"object\"}" }};
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"tools":[{"type":"function","function":{"name":"run","description":"run a command","parameters":{"type":"object"},"strict":false}}],"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "gpt", .tools = &tools, .max_output_tokens = 8 },
        &blocks,
    );
}

test "a schema constrains the response through response_format" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object"},"strict":true}},"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}" } },
        &blocks,
    );

    // A caller that turns strict mode off must reach the wire, or the schema stops being a guarantee.
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object"},"strict":false}},"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .output_schema = .{ .name = "person", .schema = "{\"type\":\"object\"}", .strict = false } },
        &blocks,
    );
}

test "each attachment kind reaches its own content part" {
    const image = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "image/png" } } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,YWI="}}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8 },
        &image,
    );

    const document = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "application/pdf", .filename = "a.pdf" } } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"file","file":{"file_data":"data:application/pdf;base64,YWI=","filename":"a.pdf"}}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8 },
        &document,
    );

    const sound = [_]ir.Block{.{ .role = .user, .value = .{ .media = .{ .source = .{ .bytes = "ab" }, .mime = "audio/mpeg" } } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"YWI=","format":"mp3"}}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8 },
        &sound,
    );
}

test "a part refuses a source its shape cannot carry" {
    const cases = [_]ir.Block.Media{
        // The image part reads a URL alone, so a provider handle has nowhere to go.
        .{ .source = .{ .file_id = "file_1" }, .mime = "image/png" },
        // The audio part carries raw base64 with no envelope.
        .{ .source = .{ .url = "https://x.test/a.mp3" }, .mime = "audio/mpeg" },
        // A document sent as bytes must name itself.
        .{ .source = .{ .bytes = "ab" }, .mime = "application/pdf" },
        .{ .source = .{ .bytes = "ab" }, .mime = "video/mp4" },
        .{ .source = .{ .bytes = "ab" }, .mime = "audio/flac" },
    };
    for (cases) |media| {
        const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .media = media } }};
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expectError(error.UnsupportedContent, serialize(&buf.writer, .{ .model = "m", .max_output_tokens = 8 }, &blocks));
    }
}

test "sampling members reach the chat request" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "go" } }};
    try expectJson(
        \\{"model":"m","stream":true,"stream_options":{"include_usage":true},"store":false,"max_tokens":8,"temperature":1.5,"top_p":0.1,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}
    ,
        .{ .model = "m", .max_output_tokens = 8, .temperature = 1.5, .top_p = 0.1 },
        &blocks,
    );
}

test "Chat Completions refuses native deferral instead of silent eager exposure" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expectError(error.UnsupportedDeferredTools, serialize(&buf.writer, .{
        .model = "chat",
        .max_output_tokens = 100,
        .tools = &.{.{ .name = "mcp_read", .description = "read", .input_schema = "{}", .defer_loading = true }},
    }, &.{.{ .role = .user, .value = .{ .text = "read" } }}));
    try testing.expectEqual(@as(usize, 0), buf.written().len);
}
