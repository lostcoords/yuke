//! Map OpenAI Chat Completions SSE data to neutral stream events.
//! The dialect has no block-stop event, so a new block or `[DONE]` stops the open block.
//! Deltas borrow caller `scratch`. Terminal results and `done` borrow reducer buffers until `deinit`. Malformed peer input returns `error.Protocol`.

const std = @import("std");
const event = @import("event.zig");
const json = @import("json.zig");
const types = @import("../types.zig");

const StreamEvent = event.StreamEvent;

pub const Error = error{ Protocol, Provider, OutOfMemory };

/// An active content block. The reducer owns its terminal fields until `deinit`.
const Block = struct {
    kind: event.BlockKind,
    open: bool = true,
    tool_index: ?usize = null,
    call_id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
};

pub const Reducer = struct {
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,
    /// The one open block. Blocks are sequential.
    open_block: ?usize = null,
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
            self.release(b.call_id);
            self.release(b.name);
        }
        self.blocks.deinit(self.gpa);
        self.release(self.raw_stop_reason);
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

        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Protocol,
        };
        const choices = switch (json.fieldGet(root, "choices") orelse return error.Protocol) {
            .array => |a| a,
            else => return error.Protocol,
        };

        if (choices.items.len > 1) return error.Protocol; // The request sets n to 1.
        if (choices.items.len == 1) {
            const index = json.fieldIndex(choices.items[0], "index") orelse return error.Protocol;
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
                const owned = try self.own(raw);
                self.release(self.raw_stop_reason);
                self.raw_stop_reason = owned;
            },
            else => {},
        };
    }

    fn onDelta(self: *Reducer, delta: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        if (json.fieldStr(delta, "content")) |text| {
            try self.appendTextDelta(text, out);
        }

        // Expose a refusal as assistant text so the consumer receives it.
        if (json.fieldStr(delta, "refusal")) |text| {
            self.refused = true;
            try self.appendTextDelta(text, out);
        }

        if (json.fieldStr(delta, "reasoning_content")) |text| {
            try self.appendReasoningDelta(text, out);
        }

        if (json.fieldGet(delta, "tool_calls")) |tool_calls| switch (tool_calls) {
            .array => |calls| for (calls.items) |call| try self.onToolCall(call, out),
            else => {},
        };
    }

    fn appendTextDelta(self: *Reducer, text: []const u8, out: *std.ArrayList(StreamEvent)) Error!void {
        if (text.len == 0) return;
        const index = try self.openFor(.text, out);
        try out.append(self.gpa, .{ .text_delta = .{ .block = @intCast(index), .text = text } });
    }

    fn appendReasoningDelta(self: *Reducer, text: []const u8, out: *std.ArrayList(StreamEvent)) Error!void {
        if (text.len == 0) return;
        const index = try self.openFor(.reasoning, out);
        try out.append(self.gpa, .{ .reasoning_delta = .{ .block = @intCast(index), .text = text } });
    }

    /// Return the open block of `kind`. A block of another kind stops first.
    fn openFor(self: *Reducer, kind: event.BlockKind, out: *std.ArrayList(StreamEvent)) Error!usize {
        std.debug.assert(kind == .text or kind == .reasoning);
        if (self.open_block) |index| {
            if (self.blocks.items[index].kind == kind) return index;
            try self.stopOpen(out);
        }
        return self.startBlock(kind, null, "", "", out);
    }

    fn onToolCall(self: *Reducer, call: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try toolIndex(call);
        const function = json.fieldGet(call, "function") orelse return error.Protocol;
        const block_index = self.findTool(index) orelse blk: {
            try self.stopOpen(out);
            break :blk try self.startBlock(
                .tool,
                index,
                json.fieldStr(call, "id") orelse "",
                json.fieldStr(function, "name") orelse "",
                out,
            );
        };
        const block = &self.blocks.items[block_index];
        if (!block.open) return error.Protocol; // The decode boundary returns an error for closed stream state.
        std.debug.assert(block.kind == .tool); // The findTool call matched a tool block.
        std.debug.assert(block.tool_index.? == index);

        if (block.call_id.len == 0) try self.capture(&block.call_id, json.fieldStr(call, "id"));
        if (block.name.len == 0) try self.capture(&block.name, json.fieldStr(function, "name"));

        if (json.fieldGet(function, "arguments")) |arguments| switch (arguments) {
            .string => |fragment| {
                std.debug.assert(block.args.items.len <= event.max_tool_arg_bytes);
                if (fragment.len > event.max_tool_arg_bytes - block.args.items.len) return error.Protocol;
                try block.args.appendSlice(self.gpa, fragment);
                try out.append(self.gpa, .{ .tool_input_delta = .{ .block = @intCast(block_index), .partial_json = fragment } });
            },
            else => {},
        };
    }

    fn onUsage(self: *Reducer, root: std.json.Value) Error!void {
        const usage = json.fieldObj(root, "usage") orelse return;
        self.usage.input = try json.countOf(usage, "prompt_tokens");
        self.usage.output = try json.countOf(usage, "completion_tokens");
        if (json.childObj(usage, "prompt_tokens_details")) |d| self.usage.cache_read = try json.countOf(d, "cached_tokens");
        if (json.childObj(usage, "completion_tokens_details")) |d| self.usage.reasoning = try json.countOf(d, "reasoning_tokens");
    }

    fn startBlock(
        self: *Reducer,
        kind: event.BlockKind,
        tool_index: ?usize,
        call_id: []const u8,
        name: []const u8,
        out: *std.ArrayList(StreamEvent),
    ) Error!usize {
        std.debug.assert(self.open_block == null);
        if (self.blocks.items.len >= event.max_blocks) return error.Protocol;
        try self.blocks.append(self.gpa, .{ .kind = kind, .tool_index = tool_index });
        const index = self.blocks.items.len - 1;
        std.debug.assert(index < event.max_blocks);
        const block = &self.blocks.items[index];
        if (call_id.len != 0) block.call_id = try self.own(call_id);
        if (name.len != 0) block.name = try self.own(name);
        try out.append(self.gpa, .{ .block_started = .{ .block = @intCast(index), .kind = kind } });
        self.open_block = index;
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
        if (destination.*.len != 0 or bytes.len == 0) return;
        destination.* = try self.own(bytes);
    }

    /// Stop the open block. A stopped block never reopens.
    fn stopOpen(self: *Reducer, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = self.open_block orelse return;
        const block = &self.blocks.items[index];
        std.debug.assert(block.open);
        const result: event.BlockResult = switch (block.kind) {
            .text => .text,
            .reasoning => .{ .reasoning = .{ .signature = "" } },
            .redacted_reasoning => .{ .redacted_reasoning = .{ .data = "" } },
            .tool => .{ .tool = .{
                .call_id = block.call_id,
                .name = block.name,
                .arguments = if (block.args.items.len == 0) "{}" else block.args.items,
            } },
        };
        try out.append(self.gpa, .{ .block_stopped = .{ .block = @intCast(index), .result = result } });
        block.open = false;
        self.open_block = null;
    }

    fn onDone(self: *Reducer, out: *std.ArrayList(StreamEvent)) Error!void {
        if (self.done_emitted) return error.Protocol;
        try self.stopOpen(out);

        // A refusal outranks the finish reason, because the model declined the request.
        if (self.refused) self.stop_reason = .refusal;
        self.done_emitted = true;
        try out.append(self.gpa, .{ .done = .{
            .stop_reason = self.stop_reason,
            .raw_stop_reason = self.raw_stop_reason,
            .usage = self.usage,
        } });
    }

    /// Copy peer bytes into reducer memory until `deinit`.
    fn own(self: *Reducer, bytes: []const u8) Error![]const u8 {
        return self.gpa.dupe(u8, bytes);
    }

    fn release(self: *Reducer, bytes: []const u8) void {
        if (bytes.len != 0) self.gpa.free(bytes);
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

/// The tool index must be present, non-negative, and representable as `usize`.
fn toolIndex(call: std.json.Value) Error!usize {
    return json.fieldIndex(call, "index") orelse error.Protocol;
}

const testing = std.testing;

/// The parse arena and reducer must stay alive while emitted events borrow them.
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    reducer: Reducer,
    out: std.ArrayList(StreamEvent) = .empty,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .reducer = Reducer.init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.out.deinit(testing.allocator);
        self.reducer.deinit();
        self.arena.deinit();
    }

    fn feed(self: *Harness, events: []const []const u8) Error!void {
        for (events) |e| try self.reducer.decode(e, self.arena.allocator(), &self.out);
    }
};

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

    try testing.expectEqual(@as(usize, 5), h.out.items.len);
    try testing.expect(h.out.items[0] == .block_started);
    try testing.expectEqual(event.BlockKind.text, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("Hel", h.out.items[1].text_delta.text);
    try testing.expectEqualStrings("lo", h.out.items[2].text_delta.text);
    try testing.expect(h.out.items[3].block_stopped.result == .text);
    const done = h.out.items[4].done;
    try testing.expectEqual(types.FinishReason.stop, done.stop_reason);
    try testing.expectEqualStrings("stop", done.raw_stop_reason);
    try testing.expectEqual(@as(u64, 100), done.usage.input);
    try testing.expectEqual(@as(u64, 5), done.usage.output);
    try testing.expectEqual(@as(u64, 20), done.usage.cache_read);
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

test "a second tool index stops the first block before it opens" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{\"a\":1}"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"two","arguments":"{\"b\":2}"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        ,
        "[DONE]",
    });

    try testing.expectEqual(@as(usize, 7), h.out.items.len);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[0].block_started.block);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[2].block_stopped.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[3].block_started.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[5].block_stopped.block);
    try testing.expectEqualStrings("a", h.out.items[2].block_stopped.result.tool.call_id);
    try testing.expectEqualStrings("b", h.out.items[5].block_stopped.result.tool.call_id);
}

test "reasoning then text gives two sequential blocks" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"reasoning_content":"why","role":"assistant"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"hi"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        ,
        "[DONE]",
    });

    try testing.expectEqual(@as(usize, 7), h.out.items.len);
    try testing.expectEqual(event.BlockKind.reasoning, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("why", h.out.items[1].reasoning_delta.text);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[2].block_stopped.block);
    // This dialect carries no reasoning signature.
    try testing.expectEqualStrings("", h.out.items[2].block_stopped.result.reasoning.signature);
    try testing.expectEqual(event.BlockKind.text, h.out.items[3].block_started.kind);
    try testing.expectEqualStrings("hi", h.out.items[4].text_delta.text);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[5].block_stopped.block);
}

test "text after a tool call stops the tool block first" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{}"}}]}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"done"}}]}
        ,
        "[DONE]",
    });

    try testing.expectEqual(@as(usize, 7), h.out.items.len);
    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("a", h.out.items[2].block_stopped.result.tool.call_id);
    try testing.expectEqual(event.BlockKind.text, h.out.items[3].block_started.kind);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[5].block_stopped.block);
}

test "every block stops before the next block starts" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"choices":[{"index":0,"delta":{"reasoning_content":"r"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"t"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{}"}}]}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"two","arguments":"{}"}}]}}]}
        ,
        "[DONE]",
    });

    var open: usize = 0;
    for (h.out.items) |ev| switch (ev) {
        .block_started => {
            try testing.expectEqual(@as(usize, 0), open);
            open += 1;
        },
        .block_stopped => {
            try testing.expectEqual(@as(usize, 1), open);
            open -= 1;
        },
        .done => try testing.expectEqual(@as(usize, 0), open),
        else => {},
    };
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
    try testing.expectEqualStrings("stop", done.raw_stop_reason); // The provider value stays intact.
}

test "malformed JSON degrades to a protocol error" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{"{not json"}));
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

fn decodeAll(gpa: std.mem.Allocator, events: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var reducer = Reducer.init(gpa);
    defer reducer.deinit();
    var out: std.ArrayList(StreamEvent) = .empty;
    defer out.deinit(gpa);
    for (events) |e| try reducer.decode(e, arena.allocator(), &out);
}

test "decode frees everything on allocation failure at every point" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeAll, .{&.{
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"tool_1","function":{"name":"run","arguments":"{\"a\":1"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        ,
        "[DONE]",
    }});
}
