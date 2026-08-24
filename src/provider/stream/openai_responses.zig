//! The OpenAI Responses reducer maps SSE data to `StreamEvent` values.
//! The stream adds output items, emits content, then completes the response. Deltas borrow caller `scratch`; terminal results and `done` borrow reducer buffers until `deinit`; malformed peer input returns `error.Protocol`.

const std = @import("std");
const wire = @import("wire");
const event = @import("event.zig");
const json = @import("json.zig");

const StreamEvent = event.StreamEvent;

/// These bounds prevent a hostile stream from exhausting memory.
const max_blocks = 1024;
const max_tool_arg_bytes = 1 << 20;

pub const Error = error{ Protocol, Provider, OutOfMemory };

const ResponsesEvent = enum {
    @"response.created",
    @"response.in_progress",
    @"response.output_item.added",
    @"response.content_part.added",
    @"response.output_text.delta",
    @"response.reasoning_summary_text.delta",
    @"response.reasoning_text.delta",
    @"response.function_call_arguments.delta",
    @"response.output_text.done",
    @"response.content_part.done",
    @"response.function_call_arguments.done",
    @"response.output_item.done",
    @"response.completed",
    @"response.incomplete",
    @"response.failed",
    @"error",
};

const ItemKind = enum { message, reasoning, tool, ignored };

/// An output item records the blocks that it owns.
const Output = struct {
    kind: ItemKind,
    text: ?event.BlockId = null,
    reasoning: ?event.BlockId = null,
    tool: ?event.BlockId = null,
};

const PartSlot = struct {
    slot: *?event.BlockId,
    kind: event.BlockKind,
};

/// An active stream block. The reducer owns tool and signature fields until `deinit`.
const Block = struct {
    kind: event.BlockKind,
    open: bool = true,
    call_id: []const u8 = "",
    name: []const u8 = "",
    signature: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
    authoritative_args: ?[]const u8 = null,
};

pub const Reducer = struct {
    gpa: std.mem.Allocator,
    outputs: std.AutoHashMapUnmanaged(usize, Output) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    usage: wire.message.TokenUsage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
    raw_stop_reason: []const u8 = "",
    stop_reason: wire.enums.StopReason = .unknown,
    done_emitted: bool = false,

    pub fn init(gpa: std.mem.Allocator) Reducer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Reducer) void {
        const blocks = self.blocks.items;
        for (blocks) |*block| {
            block.args.deinit(self.gpa);
            self.release(block.call_id);
            self.release(block.name);
            self.release(block.signature);
            if (block.authoritative_args) |arguments| self.release(arguments);
        }
        self.blocks.deinit(self.gpa);
        self.outputs.deinit(self.gpa);
        self.release(self.raw_stop_reason);
        self.* = undefined;
    }

    /// Parses one SSE `data` payload and appends neutral events to `out`.
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
        const kind = std.meta.stringToEnum(ResponsesEvent, json.fieldStr(root, "type") orelse return error.Protocol) orelse return; // Unknown event types do nothing.
        if (self.done_emitted) return error.Protocol; // No event follows the terminal response.

        switch (kind) {
            .@"response.created", .@"response.in_progress" => {},
            .@"response.output_item.added" => try self.onOutputItemAdded(root, out),
            .@"response.content_part.added" => try self.onContentPartAdded(root, out),
            .@"response.output_text.delta" => try self.onTextDelta(root, out),
            .@"response.reasoning_summary_text.delta", .@"response.reasoning_text.delta" => try self.onReasoningDelta(root, out),
            .@"response.function_call_arguments.delta" => try self.onToolDelta(root, out),
            .@"response.output_text.done" => try self.onTextDone(root, out),
            .@"response.content_part.done" => try self.onContentPartDone(root, out),
            .@"response.function_call_arguments.done" => try self.onToolArgumentsDone(root),
            .@"response.output_item.done" => try self.onOutputItemDone(root, out),
            .@"response.completed" => try self.onCompleted(root, out),
            .@"response.incomplete" => try self.onIncomplete(root, out),
            .@"response.failed", .@"error" => return error.Provider,
        }
    }

    /// Terminal response events arrive before EOF, so this method emits nothing.
    pub fn finish(_: *Reducer, _: *std.ArrayList(StreamEvent)) Error!void {}

    fn onOutputItemAdded(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        const item = json.fieldGet(root, "item") orelse return error.Protocol;
        const item_type = json.fieldStr(item, "type") orelse return error.Protocol;

        if (self.outputs.count() >= max_blocks) return error.Protocol; // Bound the output map.
        var entry = try self.outputs.getOrPut(self.gpa, index);
        if (entry.found_existing) return error.Protocol;
        entry.value_ptr.* = .{ .kind = .ignored };

        if (std.mem.eql(u8, item_type, "message")) {
            entry.value_ptr.kind = .message;
            return;
        }
        if (std.mem.eql(u8, item_type, "reasoning")) {
            entry.value_ptr.kind = .reasoning; // the reasoning block starts on the first delta
            return;
        }
        if (!std.mem.eql(u8, item_type, "function_call")) return;

        const call_id = json.fieldStr(item, "call_id") orelse return error.Protocol;
        const name = json.fieldStr(item, "name") orelse return error.Protocol;
        const block = try self.addBlock(.tool);
        block.call_id = try self.own(call_id);
        block.name = try self.own(name);
        const id: event.BlockId = @intCast(self.blocks.items.len - 1);
        entry.value_ptr.kind = .tool;
        entry.value_ptr.tool = id;
        try out.append(self.gpa, .{ .block_started = .{ .block = id, .kind = .tool } });
    }

    fn onContentPartAdded(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        _ = try contentIndex(root);
        const output = try self.messageOutput(index);
        const part = json.fieldGet(root, "part") orelse return error.Protocol;
        const part_type = json.fieldStr(part, "type") orelse return error.Protocol;

        const part_slot = partSlot(output, part_type) orelse return;
        if (part_slot.slot.* != null) return error.Protocol;
        part_slot.slot.* = try self.startBlock(part_slot.kind, out);
    }

    fn onTextDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const id = try self.outputBlockId(try outputIndex(root), .text);
        _ = try self.openBlock(id);
        const delta = json.fieldStr(root, "delta") orelse return error.Protocol;
        try out.append(self.gpa, .{ .text_delta = .{ .block = id, .text = delta } });
    }

    fn onReasoningDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        const output = self.outputs.getPtr(index) orelse return error.Protocol;
        const id = output.reasoning orelse blk: {
            const new_id = try self.startBlock(.reasoning, out);
            output.reasoning = new_id;
            break :blk new_id;
        };
        _ = try self.openBlock(id);
        const delta = json.fieldStr(root, "delta") orelse return error.Protocol;
        try out.append(self.gpa, .{ .reasoning_delta = .{ .block = id, .text = delta } });
    }

    fn onToolDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const id = try self.outputBlockId(try outputIndex(root), .tool);
        const block = try self.openBlock(id);
        const fragment = json.fieldStr(root, "delta") orelse return error.Protocol;
        if (block.authoritative_args != null) return error.Protocol;
        std.debug.assert(block.args.items.len <= max_tool_arg_bytes);
        if (fragment.len > max_tool_arg_bytes - block.args.items.len) return error.Protocol;
        try block.args.appendSlice(self.gpa, fragment);
        try out.append(self.gpa, .{ .tool_input_delta = .{ .block = id, .partial_json = fragment } });
    }

    fn onTextDone(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        const output = try self.messageOutput(index);
        const id = output.text orelse return error.Protocol;
        try self.stopBlockIfOpen(id, out);
    }

    fn onContentPartDone(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        _ = try contentIndex(root);
        const output = try self.messageOutput(index);
        const part = json.fieldGet(root, "part") orelse return error.Protocol;
        const part_type = json.fieldStr(part, "type") orelse return error.Protocol;

        const part_slot = partSlot(output, part_type) orelse return;
        if (part_slot.slot.*) |id| try self.stopBlockIfOpen(id, out);
    }

    fn onToolArgumentsDone(self: *Reducer, root: std.json.Value) Error!void {
        const id = try self.outputBlockId(try outputIndex(root), .tool);
        const block = try self.openBlock(id);
        if (block.authoritative_args != null) return error.Protocol;
        const arguments = json.fieldStr(root, "arguments") orelse return error.Protocol;
        // Keep the accumulated buffer when the echo matches; own a differing value.
        if (!std.mem.eql(u8, arguments, block.args.items)) block.authoritative_args = try self.own(arguments);
    }

    fn onOutputItemDone(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        const output = self.outputs.getPtr(index) orelse return error.Protocol;
        const item = json.fieldGet(root, "item") orelse return error.Protocol;
        const item_type = json.fieldStr(item, "type") orelse return error.Protocol;

        switch (output.kind) {
            .message => if (!std.mem.eql(u8, item_type, "message")) return error.Protocol,
            .reasoning => {
                // Encrypted reasoning can arrive with no summary deltas, so open a block to carry it.
                const encrypted = json.fieldStr(item, "encrypted_content") orelse "";
                const id = output.reasoning orelse blk: {
                    if (encrypted.len == 0) break :blk null;
                    const new_id = try self.startBlock(.reasoning, out);
                    output.reasoning = new_id;
                    break :blk new_id;
                };
                if (id) |rid| {
                    if (encrypted.len != 0) (try self.openBlock(rid)).signature = try self.own(encrypted);
                    try self.stopBlockIfOpen(rid, out);
                }
            },
            .ignored => {},
            .tool => {
                if (!std.mem.eql(u8, item_type, "function_call")) return error.Protocol;
                const id = output.tool orelse return error.Protocol;
                const block = try self.openBlock(id);
                if (json.fieldGet(item, "arguments")) |value| {
                    const arguments = switch (value) {
                        .string => |arguments| arguments,
                        else => return error.Protocol,
                    };
                    if (block.authoritative_args) |echo| {
                        if (!std.mem.eql(u8, echo, arguments)) return error.Protocol;
                    } else if (!std.mem.eql(u8, arguments, block.args.items)) {
                        block.authoritative_args = try self.own(arguments);
                    }
                }
                try self.stopBlock(id, out);
            },
        }
    }

    fn onCompleted(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        if (self.done_emitted) return error.Protocol;
        const response = json.fieldObj(root, "response") orelse return error.Protocol;
        const status = json.childStr(response, "status") orelse return error.Protocol;
        if (!std.mem.eql(u8, status, "completed")) return error.Protocol;
        self.recordUsage(response);
        self.stop_reason = .stop;
        try self.setRawStopReason("completed");
        try self.emitDone(out);
    }

    fn onIncomplete(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        if (self.done_emitted) return error.Protocol;
        const response = json.fieldObj(root, "response") orelse return error.Protocol;
        self.recordUsage(response);

        var reason: []const u8 = "incomplete";
        if (response.get("incomplete_details")) |details_value| {
            const details = switch (details_value) {
                .object => |details| details,
                else => return error.Protocol,
            };
            if (details.get("reason")) |reason_value| {
                reason = switch (reason_value) {
                    .string => |value| value,
                    else => return error.Protocol,
                };
            }
        }
        self.stop_reason = mapIncompleteReason(reason);
        try self.setRawStopReason(reason);
        try self.emitDone(out);
    }

    fn recordUsage(self: *Reducer, response: std.json.ObjectMap) void {
        const usage = json.childObj(response, "usage") orelse return;
        self.usage.input = json.countOf(usage, "input_tokens");
        self.usage.output = json.countOf(usage, "output_tokens");
        if (json.childObj(usage, "input_tokens_details")) |details| {
            self.usage.cache_read = json.countOf(details, "cached_tokens");
            self.usage.cache_write = json.countOf(details, "cache_write_tokens");
        }
        if (json.childObj(usage, "output_tokens_details")) |details| {
            self.usage.reasoning = json.countOf(details, "reasoning_tokens");
        }
    }

    fn emitDone(self: *Reducer, out: *std.ArrayList(StreamEvent)) Error!void {
        std.debug.assert(!self.done_emitted);
        var i: usize = 0;
        while (i < self.blocks.items.len) : (i += 1) try self.stopBlockIfOpen(@intCast(i), out);
        self.done_emitted = true;
        try out.append(self.gpa, .{ .done = .{
            .stop_reason = self.stop_reason,
            .raw_stop_reason = self.raw_stop_reason,
            .usage = self.usage,
        } });
    }

    fn messageOutput(self: *Reducer, index: usize) Error!*Output {
        const output = self.outputs.getPtr(index) orelse return error.Protocol;
        if (output.kind != .message) return error.Protocol;
        return output;
    }

    fn outputBlockId(self: *Reducer, index: usize, kind: event.BlockKind) Error!event.BlockId {
        const output = self.outputs.getPtr(index) orelse return error.Protocol;
        const id = switch (kind) {
            .text => output.text orelse return error.Protocol,
            .reasoning => output.reasoning orelse return error.Protocol,
            .tool => output.tool orelse return error.Protocol,
            .redacted_reasoning => return error.Protocol,
        };
        const block = try self.openBlock(id);
        if (block.kind != kind) return error.Protocol;
        return id;
    }

    fn addBlock(self: *Reducer, kind: event.BlockKind) Error!*Block {
        std.debug.assert(self.blocks.items.len <= max_blocks);
        if (self.blocks.items.len >= max_blocks) return error.Protocol;
        try self.blocks.append(self.gpa, .{ .kind = kind });
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    fn startBlock(self: *Reducer, kind: event.BlockKind, out: *std.ArrayList(StreamEvent)) Error!event.BlockId {
        _ = try self.addBlock(kind);
        const id: event.BlockId = @intCast(self.blocks.items.len - 1);
        try out.append(self.gpa, .{ .block_started = .{ .block = id, .kind = kind } });
        return id;
    }

    fn openBlock(self: *Reducer, id: event.BlockId) Error!*Block {
        const index: usize = @intCast(id);
        if (index >= self.blocks.items.len) return error.Protocol;
        const block = &self.blocks.items[index];
        if (!block.open) return error.Protocol;
        return block;
    }

    fn stopBlockIfOpen(self: *Reducer, id: event.BlockId, out: *std.ArrayList(StreamEvent)) Error!void {
        const index: usize = @intCast(id);
        if (index >= self.blocks.items.len) return error.Protocol;
        if (!self.blocks.items[index].open) return;
        try self.stopBlock(id, out);
    }

    fn stopBlock(self: *Reducer, id: event.BlockId, out: *std.ArrayList(StreamEvent)) Error!void {
        const block = try self.openBlock(id);
        block.open = false;
        const result: event.BlockResult = switch (block.kind) {
            .text => .text,
            .reasoning => .{ .reasoning = .{ .signature = block.signature } },
            .redacted_reasoning => unreachable,
            .tool => .{ .tool = .{
                .call_id = block.call_id,
                .name = block.name,
                .arguments = if (block.authoritative_args) |arguments| arguments else if (block.args.items.len == 0) "{}" else block.args.items,
            } },
        };
        try out.append(self.gpa, .{ .block_stopped = .{ .block = id, .result = result } });
    }

    /// Copies peer bytes into reducer memory until `deinit`.
    fn own(self: *Reducer, bytes: []const u8) Error![]const u8 {
        return self.gpa.dupe(u8, bytes);
    }

    fn setRawStopReason(self: *Reducer, raw: []const u8) Error!void {
        const owned = try self.own(raw);
        self.release(self.raw_stop_reason);
        self.raw_stop_reason = owned;
    }

    fn release(self: *Reducer, bytes: []const u8) void {
        if (bytes.len != 0) self.gpa.free(bytes);
    }
};

fn mapIncompleteReason(raw: []const u8) wire.enums.StopReason {
    if (std.mem.eql(u8, raw, "max_output_tokens")) return .length;
    if (std.mem.eql(u8, raw, "max_tokens")) return .length; // the docs expose both forms
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return .unknown;
}

/// The output index must be present, non-negative, and representable as `usize`.
fn outputIndex(root: std.json.Value) Error!usize {
    return json.fieldIndex(root, "output_index") orelse error.Protocol;
}

/// The content index must be present, non-negative, and representable as `usize`.
fn contentIndex(root: std.json.Value) Error!usize {
    return json.fieldIndex(root, "content_index") orelse error.Protocol;
}

fn partSlot(output: *Output, part_type: []const u8) ?PartSlot {
    if (std.mem.eql(u8, part_type, "output_text")) return .{ .slot = &output.text, .kind = .text };
    if (std.mem.eql(u8, part_type, "summary_text")) return .{ .slot = &output.reasoning, .kind = .reasoning };
    return null;
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
        try self.reducer.finish(&self.out);
    }
};

test "text turn: started, deltas, stopped, done with usage" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.created"}
        ,
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}
        ,
        \\{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}
        ,
        \\{"type":"response.output_text.delta","output_index":0,"delta":"Hel"}
        ,
        \\{"type":"response.output_text.delta","output_index":0,"delta":"lo"}
        ,
        \\{"type":"response.output_text.done","output_index":0}
        ,
        \\{"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100,"output_tokens":5,"input_tokens_details":{"cached_tokens":20}}}}
    });

    try testing.expectEqual(@as(usize, 5), h.out.items.len);
    try testing.expect(h.out.items[0] == .block_started);
    try testing.expectEqual(event.BlockKind.text, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("Hel", h.out.items[1].text_delta.text);
    try testing.expectEqualStrings("lo", h.out.items[2].text_delta.text);
    try testing.expect(h.out.items[3].block_stopped.result == .text);
    const done = h.out.items[4].done;
    try testing.expectEqual(wire.enums.StopReason.stop, done.stop_reason);
    try testing.expectEqualStrings("completed", done.raw_stop_reason);
    try testing.expectEqual(@as(u64, 100), done.usage.input);
    try testing.expectEqual(@as(u64, 20), done.usage.cache_read);
    try testing.expectEqual(@as(u64, 5), done.usage.output);
}

test "tool turn: input deltas stream and authoritative arguments surface at stop" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"cmd\":\"zig "}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"test\"}"}
        ,
        \\{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"cmd\":\"zig test\"}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"cmd\":\"zig test\"}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });

    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("{\"cmd\":\"zig ", h.out.items[1].tool_input_delta.partial_json);
    try testing.expectEqualStrings("test\"}", h.out.items[2].tool_input_delta.partial_json);
    const call = h.out.items[3].block_stopped.result.tool;
    try testing.expectEqualStrings("call_1", call.call_id);
    try testing.expectEqualStrings("run", call.name);
    try testing.expectEqualStrings("{\"cmd\":\"zig test\"}", call.arguments);
    try testing.expectEqual(wire.enums.StopReason.stop, h.out.items[4].done.stop_reason);
}

test "authoritative arguments override deltas and conflicting echoes fail" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"a\":1"}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"}"}
        ,
        \\{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"a\":1}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"a\":1}"}}
    });
    try testing.expectEqualStrings("{\"a\":1}", h.out.items[3].block_stopped.result.tool.arguments);

    var conflict = Harness.init();
    defer conflict.deinit();
    try testing.expectError(error.Protocol, conflict.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"a\":1}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"a\":2}"}}
    }));
}

test "an incomplete response maps max output tokens to length" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"output_tokens":9}}}
    });
    const done = h.out.items[0].done;
    try testing.expectEqual(wire.enums.StopReason.length, done.stop_reason);
    try testing.expectEqualStrings("max_output_tokens", done.raw_stop_reason);
}

test "a reasoning output item streams a block and captures encrypted content" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}
        ,
        \\{"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"pondering"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"gAAAAsig"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":7}}}
    });
    try testing.expectEqual(event.BlockKind.reasoning, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("pondering", h.out.items[1].reasoning_delta.text);
    try testing.expectEqualStrings("gAAAAsig", h.out.items[2].block_stopped.result.reasoning.signature);
    try testing.expect(h.out.items[3] == .done);
}

test "encrypted reasoning with no summary delta still emits a block" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"gAAAAsig"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":7}}}
    });
    try testing.expectEqual(event.BlockKind.reasoning, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("gAAAAsig", h.out.items[1].block_stopped.result.reasoning.signature);
    try testing.expect(h.out.items[2] == .done);
}

test "a reasoning item with no summary and no encrypted content emits no block" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":7}}}
    });
    try testing.expectEqual(@as(usize, 1), h.out.items.len);
    try testing.expect(h.out.items[0] == .done);
}

test "a failed response terminates with a provider error" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Provider, h.feed(&.{
        \\{"type":"response.failed"}
    }));
}

test "malformed JSON degrades to a protocol error" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{"{not json"}));
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
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"gAAAAsig"}}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"a\":1}"}
        ,
        \\{"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"a\":1}"}
        ,
        \\{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","arguments":"{\"a\":1}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":1}}}
    }});
}
