//! The Anthropic Messages reducer maps SSE data to `StreamEvent` values. The sequence is `message_start`, content blocks, `message_delta`, then `message_stop`.
//! Deltas borrow caller `scratch`; drain `out` before the next `decode`. Terminal results and `done` borrow reducer buffers until `deinit`; malformed peer input returns `error.Protocol`.

const std = @import("std");
const wire = @import("wire");
const event = @import("event.zig");
const json = @import("json.zig");

const StreamEvent = event.StreamEvent;

/// These limits prevent a hostile stream from exhausting memory.
const max_blocks = 1024;
const max_tool_arg_bytes = 1 << 20;

pub const Error = error{ Protocol, Provider, OutOfMemory };

const AnthropicEvent = enum {
    message_start,
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_delta,
    message_stop,
    ping,
    @"error",
};

/// An active content block. The reducer drops an ignored block and its events.
const Block = struct {
    kind: event.BlockKind,
    open: bool = true,
    ignored: bool = false,
    call_id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    data: []const u8 = "",
};

pub const Reducer = struct {
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,
    usage: wire.message.TokenUsage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
    raw_stop_reason: []const u8 = "",
    stop_reason: wire.enums.StopReason = .unknown,
    done_emitted: bool = false,

    pub fn init(gpa: std.mem.Allocator) Reducer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Reducer) void {
        for (self.blocks.items) |*b| {
            b.args.deinit(self.gpa);
            b.signature.deinit(self.gpa);
            self.release(b.call_id);
            self.release(b.name);
            self.release(b.data);
        }
        self.blocks.deinit(self.gpa);
        self.release(self.raw_stop_reason);
        self.* = undefined;
    }

    /// Parses one SSE `data` payload and adds neutral events to `out`.
    pub fn decode(
        self: *Reducer,
        data: []const u8,
        scratch: std.mem.Allocator,
        out: *std.ArrayList(StreamEvent),
    ) Error!void {
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Protocol,
        };
        const kind = std.meta.stringToEnum(AnthropicEvent, json.fieldStr(root, "type") orelse return error.Protocol) orelse return; // Unknown event types are no-ops

        switch (kind) {
            .ping => {},
            .@"error" => return error.Provider,
            .message_start => self.onMessageStart(root),
            .content_block_start => try self.onBlockStart(root, out),
            .content_block_delta => try self.onBlockDelta(root, out),
            .content_block_stop => try self.onBlockStop(root, out),
            .message_delta => try self.onMessageDelta(root),
            .message_stop => try self.onMessageStop(out),
        }
    }

    /// Anthropic sends all events before EOF, so this method emits nothing.
    pub fn finish(_: *Reducer, _: *std.ArrayList(StreamEvent)) Error!void {}

    fn onMessageStart(self: *Reducer, root: std.json.Value) void {
        const usage = json.fieldObj(json.fieldGet(root, "message") orelse return, "usage") orelse return;
        self.usage.input = json.countOf(usage, "input_tokens");
        self.usage.cache_read = json.countOf(usage, "cache_read_input_tokens");
        self.usage.cache_write = json.countOf(usage, "cache_creation_input_tokens");
    }

    fn onBlockStart(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try blockIndex(root);
        if (index != self.blocks.items.len) return error.Protocol; // Block indexes must arrive in dense order
        if (self.blocks.items.len >= max_blocks) return error.Protocol;

        const cb = json.fieldGet(root, "content_block") orelse return error.Protocol;
        const cb_type = json.fieldStr(cb, "type") orelse return error.Protocol;

        // Borrow the fields now; own them only after the block holds a slot, so a
        // failed copy leaks nothing and `deinit` frees whatever the block owns.
        var kind: event.BlockKind = .text;
        var ignored = false;
        var call_id: []const u8 = "";
        var name: []const u8 = "";
        var data: []const u8 = "";
        if (std.mem.eql(u8, cb_type, "text")) {
            kind = .text;
        } else if (std.mem.eql(u8, cb_type, "thinking")) {
            kind = .reasoning;
        } else if (std.mem.eql(u8, cb_type, "redacted_thinking")) {
            kind = .redacted_reasoning;
            data = json.fieldStr(cb, "data") orelse "";
        } else if (std.mem.eql(u8, cb_type, "tool_use")) {
            kind = .tool;
            call_id = json.fieldStr(cb, "id") orelse return error.Protocol;
            name = json.fieldStr(cb, "name") orelse return error.Protocol;
        } else {
            ignored = true;
        }

        try self.blocks.append(self.gpa, .{ .kind = kind, .ignored = ignored });
        const block = &self.blocks.items[index];
        if (data.len != 0) block.data = try self.own(data);
        if (call_id.len != 0) block.call_id = try self.own(call_id);
        if (name.len != 0) block.name = try self.own(name);

        if (!ignored) try out.append(self.gpa, .{ .block_started = .{ .block = @intCast(index), .kind = kind } });
    }

    fn onBlockDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try blockIndex(root);
        const block = try self.openBlock(index);
        if (block.ignored) return;

        const delta = json.fieldGet(root, "delta") orelse return error.Protocol;
        const delta_type = json.fieldStr(delta, "type") orelse return error.Protocol;

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            if (block.kind != .text) return error.Protocol;
            try out.append(self.gpa, .{ .text_delta = .{ .block = @intCast(index), .text = json.fieldStr(delta, "text") orelse return error.Protocol } });
        } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            if (block.kind != .reasoning) return error.Protocol;
            try out.append(self.gpa, .{ .reasoning_delta = .{ .block = @intCast(index), .text = json.fieldStr(delta, "thinking") orelse return error.Protocol } });
        } else if (std.mem.eql(u8, delta_type, "signature_delta")) {
            if (block.kind != .reasoning) return error.Protocol;
            try block.signature.appendSlice(self.gpa, json.fieldStr(delta, "signature") orelse return error.Protocol);
        } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            if (block.kind != .tool) return error.Protocol;
            const fragment = json.fieldStr(delta, "partial_json") orelse return error.Protocol;
            if (fragment.len > max_tool_arg_bytes - block.args.items.len) return error.Protocol;
            try block.args.appendSlice(self.gpa, fragment);
            try out.append(self.gpa, .{ .tool_input_delta = .{ .block = @intCast(index), .partial_json = fragment } });
        }
        // Unknown delta types are no-ops.
    }

    fn onBlockStop(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try blockIndex(root);
        const block = try self.openBlock(index);
        block.open = false;
        if (block.ignored) return;

        const result: event.BlockResult = switch (block.kind) {
            .text => .text,
            .reasoning => .{ .reasoning = .{ .signature = block.signature.items } },
            .redacted_reasoning => .{ .redacted_reasoning = .{ .data = block.data } },
            .tool => .{ .tool = .{
                .call_id = block.call_id,
                .name = block.name,
                .arguments = if (block.args.items.len == 0) "{}" else block.args.items,
            } },
        };
        try out.append(self.gpa, .{ .block_stopped = .{ .block = @intCast(index), .result = result } });
    }

    fn onMessageDelta(self: *Reducer, root: std.json.Value) Error!void {
        if (json.fieldGet(root, "delta")) |delta| {
            if (json.fieldStr(delta, "stop_reason")) |raw| {
                self.stop_reason = mapStopReason(raw);
                const owned = try self.own(raw);
                self.release(self.raw_stop_reason);
                self.raw_stop_reason = owned;
            }
        }
        if (json.fieldObj(root, "usage")) |usage| {
            self.usage.output = json.countOf(usage, "output_tokens");
            if (json.childObj(usage, "output_tokens_details")) |d| self.usage.reasoning = json.countOf(d, "thinking_tokens");
        }
    }

    fn onMessageStop(self: *Reducer, out: *std.ArrayList(StreamEvent)) Error!void {
        if (self.done_emitted) return error.Protocol;
        self.done_emitted = true;
        try out.append(self.gpa, .{ .done = .{
            .stop_reason = self.stop_reason,
            .raw_stop_reason = self.raw_stop_reason,
            .usage = self.usage,
        } });
    }

    fn openBlock(self: *Reducer, index: usize) Error!*Block {
        if (index >= self.blocks.items.len) return error.Protocol;
        const block = &self.blocks.items[index];
        if (!block.open) return error.Protocol;
        return block;
    }

    /// Copies peer bytes into memory that the reducer owns until `deinit`.
    fn own(self: *Reducer, bytes: []const u8) Error![]const u8 {
        return self.gpa.dupe(u8, bytes);
    }

    fn release(self: *Reducer, bytes: []const u8) void {
        if (bytes.len != 0) self.gpa.free(bytes);
    }
};

fn mapStopReason(raw: []const u8) wire.enums.StopReason {
    if (std.mem.eql(u8, raw, "end_turn")) return .stop;
    if (std.mem.eql(u8, raw, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, raw, "max_tokens")) return .length;
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, raw, "refusal")) return .content_filter;
    if (std.mem.eql(u8, raw, "model_context_window_exceeded")) return .length;
    // pause_turn and any new reason keep only the raw value.
    return .unknown;
}

/// The block index from an event. It rejects a missing, negative, or huge value.
fn blockIndex(root: std.json.Value) Error!usize {
    return json.fieldIndex(root, "index") orelse error.Protocol;
}

const testing = std.testing;

/// Keeps the parse arena and reducer alive while emitted events borrow them.
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
        try self.reducer.finish(&self.out);
    }
};

test "text turn: started, deltas, stopped, done with usage" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
        ,
        \\{"type":"message_stop"}
    });

    try testing.expectEqual(@as(usize, 5), h.out.items.len);
    try testing.expect(h.out.items[0] == .block_started);
    try testing.expectEqual(event.BlockKind.text, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("Hel", h.out.items[1].text_delta.text);
    try testing.expectEqualStrings("lo", h.out.items[2].text_delta.text);
    try testing.expect(h.out.items[3].block_stopped.result == .text);
    const done = h.out.items[4].done;
    try testing.expectEqual(wire.enums.StopReason.stop, done.stop_reason);
    try testing.expectEqualStrings("end_turn", done.raw_stop_reason);
    try testing.expectEqual(@as(u64, 100), done.usage.input);
    try testing.expectEqual(@as(u64, 20), done.usage.cache_read);
    try testing.expectEqual(@as(u64, 5), done.usage.output);
}

test "tool turn: input deltas stream and the whole call surfaces at stop" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":\"zig "}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"test\"}"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
        ,
        \\{"type":"message_stop"}
    });

    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("{\"cmd\":\"zig ", h.out.items[1].tool_input_delta.partial_json);
    const call = h.out.items[3].block_stopped.result.tool;
    try testing.expectEqualStrings("toolu_1", call.call_id);
    try testing.expectEqualStrings("run", call.name);
    try testing.expectEqualStrings("{\"cmd\":\"zig test\"}", call.arguments);
    try testing.expectEqual(wire.enums.StopReason.tool_calls, h.out.items[4].done.stop_reason);
}

test "thinking block accumulates its signature into the result" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}
        ,
        \\{"type":"content_block_stop","index":0}
    });

    try testing.expectEqual(event.BlockKind.reasoning, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("pondering", h.out.items[1].reasoning_delta.text);
    try testing.expectEqualStrings("sig123", h.out.items[2].block_stopped.result.reasoning.signature);
}

test "unknown event type is a forward-compatible no-op" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"some_future_event","data":{}}
        ,
        \\{"type":"ping"}
    });
    try testing.expectEqual(@as(usize, 0), h.out.items.len);
}

test "malformed JSON degrades to a protocol error" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{"{not json"}));
}

test "an error event terminates with a provider error" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Provider, h.feed(&.{
        \\{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}
    }));
}

test "a second message_stop is rejected, not asserted" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{
        \\{"type":"message_stop"}
        ,
        \\{"type":"message_stop"}
    }));
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
        \\{"type":"message_start","message":{"usage":{"input_tokens":100}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
        ,
        \\{"type":"message_stop"}
    }});
}
