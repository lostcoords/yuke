//! Map OpenAI Chat Completions SSE data to neutral stream events.

const std = @import("std");
const event = @import("event.zig");
const json = @import("json.zig");
const answer = @import("../answer.zig");
const types = @import("../types.zig");

const StreamEvent = event.StreamEvent;

pub const Error = json.Error;

/// A content block that stays open until `[DONE]`. The reducer owns its terminal fields until `deinit`.
const Block = struct {
    kind: event.BlockKind,
    tool_index: ?usize = null,
    call_id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
};

pub const Reducer = struct {
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,
    /// The one block of `content` and `refusal`. The wire message has one content string, so the block never splits.
    text_block: ?usize = null,
    /// The one block of the reasoning channel. It interleaves with text in no defined order.
    reasoning_block: ?usize = null,
    usage: types.Usage = .{},
    raw_stop_reason: []const u8 = "",
    stop_reason: types.FinishReason = .unknown,
    /// True when the model refused. This dialect reports `stop`, so the refusal sets the reason.
    refused: bool = false,
    done_emitted: bool = false,

    pub fn init(gpa: std.mem.Allocator) Reducer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Reducer) void {
        for (self.blocks.items) |*b| {
            b.args.deinit(self.gpa);
            self.gpa.free(b.call_id);
            self.gpa.free(b.name);
        }
        self.blocks.deinit(self.gpa);
        self.gpa.free(self.raw_stop_reason);
        self.* = undefined;
    }

    /// Parse one SSE `data` payload and append neutral events to `out`.
    pub fn decode(
        self: *Reducer,
        data: []const u8,
        scratch: std.mem.Allocator,
        out: *std.ArrayList(StreamEvent),
    ) Error!void {
        if (std.mem.eql(u8, data, "[DONE]")) return self.onDone(out);
        // Some gateways send an extra frame after `[DONE]`. Ignore it.
        if (self.done_emitted) return;

        const root = try json.parse(data, scratch);
        // A gateway reports a failure after the 200 head as a chunk with a top-level `error`.
        if (json.fieldGet(root, "error")) |value| if (value != .null) return answer.fromEvent(root);
        const choices = switch (json.fieldGet(root, "choices") orelse return error.Protocol) {
            .array => |a| a,
            else => return error.Protocol,
        };

        if (choices.items.len > 1) return error.Protocol; // The request sets n to 1.
        if (choices.items.len == 1) {
            const index = try json.fieldIndex(choices.items[0], "index");
            if (index != 0) return error.Protocol;
            try self.onChoice(choices.items[0], out);
        }
        try self.onUsage(root);
    }

    fn onChoice(self: *Reducer, choice: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        if (json.fieldGet(choice, "delta")) |delta| switch (delta) {
            .object => try self.onDelta(delta, out),
            else => {},
        };

        if (json.fieldGet(choice, "finish_reason")) |reason| switch (reason) {
            .string => |raw| {
                self.stop_reason = mapStopReason(raw);
                try json.replaceOwned(self.gpa, &self.raw_stop_reason, raw);
            },
            else => {},
        };
    }

    fn onDelta(self: *Reducer, delta: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        // A chunk that crosses the end of thinking carries both fields, and its reasoning comes first.
        const reasoning_text = json.fieldStr(delta, "reasoning_content") orelse json.fieldStr(delta, "reasoning");
        if (reasoning_text) |text| {
            try self.appendDelta(text, .reasoning, out);
        }

        if (json.fieldStr(delta, "content")) |text| {
            try self.appendDelta(text, .text, out);
        }

        // Expose a refusal as assistant text so the consumer receives it.
        if (json.fieldStr(delta, "refusal")) |text| {
            self.refused = true;
            try self.appendDelta(text, .text, out);
        }

        if (json.fieldGet(delta, "tool_calls")) |tool_calls| switch (tool_calls) {
            .array => |calls| for (calls.items) |call| try self.onToolCall(call, out),
            else => {},
        };
    }

    fn appendDelta(self: *Reducer, text: []const u8, kind: event.BlockKind, out: *std.ArrayList(StreamEvent)) Error!void {
        if (text.len == 0) return;
        const channel = switch (kind) {
            .text => &self.text_block,
            .reasoning => &self.reasoning_block,
            else => unreachable, // onDelta passes only text or reasoning.
        };
        const index = channel.* orelse try self.startBlock(kind, null, out);
        std.debug.assert(self.blocks.items[index].kind == kind); // a channel names only blocks of its own kind
        channel.* = index;
        try out.append(self.gpa, switch (kind) {
            .text => .{ .text_delta = .{ .block = @intCast(index), .text = text } },
            .reasoning => .{ .reasoning_delta = .{ .block = @intCast(index), .text = text } },
            else => unreachable, // the channel switch above admitted only text or reasoning.
        });
    }

    fn onToolCall(self: *Reducer, call: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try json.fieldIndex(call, "index");
        // Only `index` is required on a chunk, so an entry with no function carries nothing to add.
        const function = json.fieldGet(call, "function") orelse return;
        const function_object = switch (function) {
            .object => |object| object,
            else => return error.Protocol,
        };
        const block_index = self.findTool(index) orelse try self.startBlock(.tool, index, out);
        const block = &self.blocks.items[block_index];
        std.debug.assert(block.kind == .tool); // The findTool call matched a tool block.
        std.debug.assert(block.tool_index.? == index);

        try self.capture(&block.call_id, try identity(call, "id"));
        try self.capture(&block.name, try identity(function, "name"));

        if (function_object.get("arguments")) |arguments| switch (arguments) {
            .string => |fragment| {
                try json.appendArgs(self.gpa, &block.args, fragment);
                try out.append(self.gpa, .{ .tool_input_delta = .{ .block = @intCast(block_index), .partial_json = fragment } });
            },
            .null => {},
            else => return error.Protocol,
        };
    }

    fn onUsage(self: *Reducer, root: std.json.Value) Error!void {
        const usage = json.fieldObj(root, "usage") orelse return;
        self.usage.input = try json.countOf(usage, "prompt_tokens");
        self.usage.output = try json.countOf(usage, "completion_tokens");
        if (json.childObj(usage, "prompt_tokens_details")) |d| self.usage.cache_read = try json.countOf(d, "cached_tokens");
        if (json.childObj(usage, "completion_tokens_details")) |d| self.usage.reasoning = try json.countOf(d, "reasoning_tokens");
    }

    /// This dialect sends no block-stop event, so only `[DONE]` stops a block.
    fn startBlock(
        self: *Reducer,
        kind: event.BlockKind,
        tool_index: ?usize,
        out: *std.ArrayList(StreamEvent),
    ) Error!usize {
        if (self.blocks.items.len >= event.max_response_blocks) return error.Protocol;
        try self.blocks.append(self.gpa, .{ .kind = kind, .tool_index = tool_index });
        const index = self.blocks.items.len - 1;
        std.debug.assert(index < event.max_response_blocks);
        try out.append(self.gpa, .{ .block_started = .{ .block = @intCast(index), .kind = kind } });
        return index;
    }

    fn findTool(self: *Reducer, tool_index: usize) ?usize {
        for (self.blocks.items, 0..) |block, index| {
            if (block.kind == .tool and block.tool_index.? == tool_index) return index;
        }
        return null;
    }

    fn capture(self: *Reducer, destination: *[]const u8, source: ?[]const u8) Error!void {
        const bytes = source orelse return;
        if (bytes.len == 0) return;
        if (destination.*.len != 0) {
            if (!std.mem.eql(u8, destination.*, bytes)) return error.Protocol;
            return;
        }
        destination.* = try self.gpa.dupe(u8, bytes);
    }

    fn onDone(self: *Reducer, out: *std.ArrayList(StreamEvent)) Error!void {
        if (self.done_emitted) return error.Protocol;
        // Every block stays open until here, so each one stops exactly once.
        for (self.blocks.items, 0..) |block, index| {
            const result: event.BlockResult = switch (block.kind) {
                .text => .text,
                .reasoning => .{ .reasoning = .{ .signature = "" } },
                .redacted_reasoning => .{ .redacted_reasoning = .{ .data = "" } },
                .tool => .{ .tool = .{
                    .call_id = block.call_id,
                    .name = block.name,
                    .arguments = json.arguments(block.args.items),
                } },
            };
            try out.append(self.gpa, .{ .block_stopped = .{ .block = @intCast(index), .result = result } });
        }

        // A refusal outranks the finish reason, because the model declined the request.
        if (self.refused) self.stop_reason = .refusal;
        self.done_emitted = true;
        try out.append(self.gpa, .{ .done = .{ .stop_reason = self.stop_reason, .raw_stop_reason = self.raw_stop_reason, .usage = self.usage } });
    }
};

fn mapStopReason(raw: []const u8) types.FinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return .unknown;
}

fn identity(value: std.json.Value, key: []const u8) Error!?[]const u8 {
    return switch (json.fieldGet(value, key) orelse return null) {
        .string => |text| text,
        .null => null,
        else => error.Protocol,
    };
}

const testing = std.testing;
const stream_testing = @import("testing.zig");

const Harness = stream_testing.Harness(Reducer);

test "text turn: started, deltas, stopped, done with usage" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        ,
        \\{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":20}}}
        ,
        "[DONE]",
    });

    const done = try stream_testing.expectTextResponse(h.out.items);
    try testing.expectEqualStrings("stop", done.raw_stop_reason);
    try testing.expectEqual(@as(u64, 100), done.usage.input);
    try testing.expectEqual(@as(u64, 5), done.usage.output);
    try testing.expectEqual(@as(u64, 20), done.usage.cache_read);
}

test "unknown finish reason keeps its raw provider value" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"pause_turn"}]}
        ,
        "[DONE]",
    });

    const done = h.out.items[3].done;
    try testing.expectEqual(types.FinishReason.unknown, done.stop_reason);
    try testing.expectEqualStrings("pause_turn", done.raw_stop_reason);
}

test "tool turn: input deltas stream and the whole call surfaces at stop" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run","arguments":"{\"cmd\":\"zig "}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"test\"}"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        ,
        "[DONE]",
    });

    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("{\"cmd\":\"zig ", h.out.items[1].tool_input_delta.partial_json);
    try testing.expectEqualStrings("test\"}", h.out.items[2].tool_input_delta.partial_json);
    const call = h.out.items[3].block_stopped.result.tool;
    try testing.expectEqualStrings("call_1", call.call_id);
    try testing.expectEqualStrings("run", call.name);
    try testing.expectEqualStrings("{\"cmd\":\"zig test\"}", call.arguments);
    try testing.expectEqual(types.FinishReason.tool_calls, h.out.items[4].done.stop_reason);
}

test "parallel tool indexes keep stable blocks until done" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{\"a\":"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"two","arguments":"{\"b\":"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"2}"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        ,
        "[DONE]",
    });

    try testing.expectEqual(@as(usize, 9), h.out.items.len);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[0].block_started.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[2].block_started.block);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[4].tool_input_delta.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[5].tool_input_delta.block);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[6].block_stopped.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[7].block_stopped.block);
    try testing.expectEqualStrings("{\"a\":1}", h.out.items[6].block_stopped.result.tool.arguments);
    try testing.expectEqualStrings("{\"b\":2}", h.out.items[7].block_stopped.result.tool.arguments);
}

// Grok streams reasoning after content starts, and a chunk can carry both fields.
test "interleaved reasoning and text keep one block per channel" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"reasoning_content":"how it","role":"assistant"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"The"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"reasoning_content":" works."}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read","arguments":"{}"}}]}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":" plugin","reasoning_content":" Done."}}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        ,
        "[DONE]",
    });

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(testing.allocator);
    var started: [3]event.BlockKind = undefined;
    var started_len: usize = 0;
    var stopped: usize = 0;
    for (h.out.items) |ev| switch (ev) {
        .block_started => |b| {
            try testing.expectEqual(@as(event.BlockId, @intCast(started_len)), b.block);
            try testing.expectEqual(@as(usize, 0), stopped);
            try testing.expect(started_len < started.len);
            started[started_len] = b.kind;
            started_len += 1;
        },
        .text_delta => |d| {
            try testing.expectEqual(@as(event.BlockId, 1), d.block);
            try text.appendSlice(testing.allocator, d.text);
        },
        .reasoning_delta => |d| {
            try testing.expectEqual(@as(event.BlockId, 0), d.block);
            try reasoning.appendSlice(testing.allocator, d.text);
        },
        .block_stopped => |b| {
            try testing.expectEqual(@as(event.BlockId, @intCast(stopped)), b.block);
            stopped += 1;
        },
        else => {},
    };
    try testing.expectEqualSlices(event.BlockKind, &.{ .reasoning, .text, .tool }, started[0..started_len]);
    try testing.expectEqual(@as(usize, 3), stopped);
    try testing.expectEqualStrings("how it works. Done.", reasoning.items);
    try testing.expectEqualStrings("The plugin", text.items);
}

test "a tool index rejects conflicting identity" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one"}}]}}]}
    });
    try testing.expectError(error.Protocol, h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"b","function":{"name":"one"}}]}}]}
    }));
}

// This dialect reports `stop` for a refusal, so only the refusal field marks the turn.
test "a refusal streams as text and reports refusal" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"refusal":"I cannot help"},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        ,
        "[DONE]",
    });

    try testing.expectEqual(event.BlockKind.text, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("I cannot help", h.out.items[1].text_delta.text);
    const done = h.out.items[h.out.items.len - 1].done;
    try testing.expectEqual(types.FinishReason.refusal, done.stop_reason);
    try testing.expectEqualStrings("stop", done.raw_stop_reason);
}

test "malformed JSON degrades to a protocol error" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{"{not json"}));
}

test "a gateway error chunk fails the stream, never a finish with an unknown reason" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.ServerError, h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}
        ,
        \\{"id":"gen-1","object":"chat.completion.chunk","error":{"code":502,"message":"upstream failed"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}
    }));
    // A null `error` is no error.
    var ok = Harness.init();
    defer ok.deinit();
    try ok.feed(&.{
        \\{"error":null,"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}
    });
}

test "a choice with index one is rejected" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{
        \\{"choices":[{"index":1,"delta":{"content":"no"},"finish_reason":null}]}
    }));
}

test "a second done sentinel is rejected" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{ "[DONE]", "[DONE]" }));
}

test "decode frees everything on allocation failure at every point" {
    try testing.checkAllAllocationFailures(testing.allocator, stream_testing.decodeAll(Reducer), .{
        &.{
            \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"tool_1","function":{"name":"run","arguments":"{\"a\":1"}}]},"finish_reason":null}]}
            ,
            \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}
            ,
            \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
            ,
            "[DONE]",
        },
    });
}

test "a chunk with no function and an openrouter reasoning field are both handled" {
    var h = Harness.init();
    defer h.deinit();

    // Only `index` is required on a tool-call chunk, so an entry with no function must not abort.
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function"}]}}]}
        ,
        // OpenRouter names the field `reasoning`; DeepSeek names it `reasoning_content`.
        \\{"choices":[{"index":0,"delta":{"reasoning":"why"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}
    });

    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(testing.allocator);
    for (h.out.items) |ev| switch (ev) {
        .reasoning_delta => |d| try reasoning.appendSlice(testing.allocator, d.text),
        else => {},
    };
    try testing.expectEqualStrings("why", reasoning.items);
}
