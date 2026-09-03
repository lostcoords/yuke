//! The reducer maps OpenAI Responses SSE data to `StreamEvent` values. The stream adds output items, emits content, then completes the response.
//! Deltas borrow caller `scratch`. Terminal results and `done` borrow reducer buffers until `deinit`. Malformed peer input returns `error.Protocol`.

const std = @import("std");
const proto = @import("proto");
const event = @import("event.zig");
const json = @import("json.zig");
const limits = @import("limits.zig");

const StreamEvent = event.StreamEvent;

pub const Error = error{ Protocol, Provider, OutOfMemory };

const ResponsesEvent = enum {
    @"response.created",
    @"response.in_progress",
    @"response.output_item.added",
    @"response.content_part.added",
    @"response.output_text.delta",
    @"response.refusal.delta",
    @"response.reasoning_summary_text.delta",
    @"response.reasoning_text.delta",
    @"response.function_call_arguments.delta",
    @"response.output_text.done",
    @"response.refusal.done",
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
    /// The hashed `item.id` from the `added` event. Zero means the provider sent none.
    item_id: u64 = 0,
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
    /// True when the reducer discards the block. A dropped block reaches no consumer.
    dropped: bool = false,
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
    usage: proto.message.TokenUsage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 },
    raw_stop_reason: []const u8 = "",
    stop_reason: proto.enums.StopReason = .unknown,
    /// True when the model refused. A refusal arrives beside the content, never inside it.
    refused: bool = false,
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

    /// Parse one SSE `data` payload and append neutral events to `out`.
    pub fn decode(
        self: *Reducer,
        data: []const u8,
        scratch: std.mem.Allocator,
        out: *std.ArrayList(StreamEvent),
    ) Error!void {
        // This dialect ends at `response.completed`, so a gateway's Chat sentinel adds nothing.
        if (std.mem.eql(u8, data, "[DONE]")) return;
        // The first terminal decides the turn. Drop every later frame before the parse can reject it.
        if (self.done_emitted) return;

        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Protocol,
        };
        const kind = std.meta.stringToEnum(ResponsesEvent, json.fieldStr(root, "type") orelse return error.Protocol) orelse return; // Unknown event types do nothing.

        switch (kind) {
            .@"response.created", .@"response.in_progress" => {},
            .@"response.output_item.added" => try self.onOutputItemAdded(root, out),
            .@"response.content_part.added" => try self.onContentPartAdded(root, out),
            .@"response.output_text.delta" => try self.onTextDelta(root, out),
            .@"response.refusal.delta" => try self.onRefusalDelta(root, out),
            .@"response.reasoning_summary_text.delta", .@"response.reasoning_text.delta" => try self.onReasoningDelta(root, out),
            .@"response.function_call_arguments.delta" => try self.onToolDelta(root, out),
            .@"response.output_text.done", .@"response.refusal.done" => try self.onTextDone(root, out),
            .@"response.content_part.done" => try self.onContentPartDone(root, out),
            .@"response.function_call_arguments.done" => try self.onToolArgumentsDone(root),
            .@"response.output_item.done" => try self.onOutputItemDone(root, out),
            .@"response.completed" => try self.onCompleted(root, out),
            .@"response.incomplete" => try self.onIncomplete(root, out),
            .@"response.failed", .@"error" => return error.Provider,
        }
    }

    fn onOutputItemAdded(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const index = try outputIndex(root);
        const item = json.fieldGet(root, "item") orelse return error.Protocol;
        const item_type = json.fieldStr(item, "type") orelse return error.Protocol;

        if (self.outputs.count() >= limits.max_blocks) return error.Protocol; // Bound the output map.
        var entry = try self.outputs.getOrPut(self.gpa, index);
        if (entry.found_existing) return error.Protocol;
        entry.value_ptr.* = .{ .kind = .ignored, .item_id = itemIdHash(json.fieldStr(item, "id")) };

        if (std.mem.eql(u8, item_type, "message")) {
            entry.value_ptr.kind = .message;
            return;
        }
        if (std.mem.eql(u8, item_type, "reasoning")) {
            entry.value_ptr.kind = .reasoning; // The reasoning block starts on the first delta.
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
        _ = try contentIndex(root);
        const output = try self.messageOutput(try self.outputFor(root));
        const part = json.fieldGet(root, "part") orelse return error.Protocol;
        const part_type = json.fieldStr(part, "type") orelse return error.Protocol;

        if (std.mem.eql(u8, part_type, "refusal")) self.refused = true;
        const part_slot = partSlot(output, part_type) orelse return;
        if (part_slot.slot.* != null) return error.Protocol;
        part_slot.slot.* = try self.startBlock(part_slot.kind, out);
    }

    fn onTextDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const id = try self.outputBlockId(try self.outputFor(root), .text);
        const delta = json.fieldStr(root, "delta") orelse return error.Protocol;
        try out.append(self.gpa, .{ .text_delta = .{ .block = id, .text = delta } });
    }

    /// Carry a refusal as assistant text, so the reason the model declined reaches the consumer.
    fn onRefusalDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        self.refused = true;
        return self.onTextDelta(root, out);
    }

    fn onReasoningDelta(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const output = try self.outputFor(root);
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
        const id = try self.outputBlockId(try self.outputFor(root), .tool);
        const block = try self.openBlock(id);
        const fragment = json.fieldStr(root, "delta") orelse return error.Protocol;
        if (block.authoritative_args != null) return error.Protocol;
        std.debug.assert(block.args.items.len <= limits.max_message_bytes);
        if (fragment.len > limits.max_message_bytes - block.args.items.len) return error.Protocol;
        try block.args.appendSlice(self.gpa, fragment);
        try out.append(self.gpa, .{ .tool_input_delta = .{ .block = id, .partial_json = fragment } });
    }

    fn onTextDone(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const output = try self.messageOutput(try self.outputFor(root));
        const id = output.text orelse return error.Protocol;
        try self.stopBlockIfOpen(id, out);
    }

    fn onContentPartDone(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        _ = try contentIndex(root);
        const output = try self.messageOutput(try self.outputFor(root));
        const part = json.fieldGet(root, "part") orelse return error.Protocol;
        const part_type = json.fieldStr(part, "type") orelse return error.Protocol;

        const part_slot = partSlot(output, part_type) orelse return;
        if (part_slot.slot.*) |id| try self.stopBlockIfOpen(id, out);
    }

    fn onToolArgumentsDone(self: *Reducer, root: std.json.Value) Error!void {
        const id = try self.outputBlockId(try self.outputFor(root), .tool);
        const block = try self.openBlock(id);
        if (block.authoritative_args != null) return error.Protocol;
        const arguments = json.fieldStr(root, "arguments") orelse return error.Protocol;
        // Keep the accumulated buffer when the echo matches. Own a different value.
        if (!std.mem.eql(u8, arguments, block.args.items)) block.authoritative_args = try self.own(arguments);
    }

    fn onOutputItemDone(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const output = try self.outputFor(root);
        const item = json.fieldGet(root, "item") orelse return error.Protocol;
        const item_type = json.fieldStr(item, "type") orelse return error.Protocol;
        try checkItemId(output, json.fieldStr(item, "id"));

        switch (output.kind) {
            .message => if (!std.mem.eql(u8, item_type, "message")) return error.Protocol,
            .reasoning => {
                if (!std.mem.eql(u8, item_type, "reasoning")) return error.Protocol;
                // Encrypted reasoning can arrive without summary deltas, so open a block to carry it.
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
                // A status other than `completed` marks a call the model never finished. Drop it.
                if (json.fieldStr(item, "status")) |status| if (!std.mem.eql(u8, status, "completed")) {
                    block.open = false;
                    block.dropped = true;
                    return;
                };
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
        const response = json.fieldObj(root, "response") orelse return error.Protocol;
        const status = json.childStr(response, "status") orelse return error.Protocol;
        if (!std.mem.eql(u8, status, "completed")) return error.Protocol;
        try self.recordUsage(response);
        // This API has no tool stop reason: a response carrying a function call still reports
        // `completed`. The blocks decide instead, or the engine refuses the tool part it was sent.
        self.stop_reason = if (self.refused) .refusal else if (self.hasToolBlock()) .tool_calls else .stop;
        try self.setRawStopReason("completed");
        try self.emitDone(out);
    }

    fn onIncomplete(self: *Reducer, root: std.json.Value, out: *std.ArrayList(StreamEvent)) Error!void {
        const response = json.fieldObj(root, "response") orelse return error.Protocol;
        try self.recordUsage(response);

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

    fn recordUsage(self: *Reducer, response: std.json.ObjectMap) Error!void {
        const usage = json.childObj(response, "usage") orelse return;
        self.usage.input = try json.countOf(usage, "input_tokens");
        self.usage.output = try json.countOf(usage, "output_tokens");
        if (json.childObj(usage, "input_tokens_details")) |details| {
            self.usage.cache_read = try json.countOf(details, "cached_tokens");
            self.usage.cache_write = try json.countOf(details, "cache_write_tokens");
        }
        if (json.childObj(usage, "output_tokens_details")) |details| {
            self.usage.reasoning = try json.countOf(details, "reasoning_tokens");
        }
    }

    fn emitDone(self: *Reducer, out: *std.ArrayList(StreamEvent)) Error!void {
        std.debug.assert(!self.done_emitted);
        // An open tool block holds partial arguments, so drop it instead of an unfinished call.
        for (self.blocks.items, 0..) |block, i| {
            if (block.kind == .tool) continue;
            try self.stopBlockIfOpen(@intCast(i), out);
        }
        self.done_emitted = true;
        try out.append(self.gpa, .{ .done = .{
            .stop_reason = self.stop_reason,
            .raw_stop_reason = self.raw_stop_reason,
            .usage = self.usage,
        } });
    }

    /// Find the item an event names. An `item_id` that names another item rejects the frame.
    fn outputFor(self: *Reducer, root: std.json.Value) Error!*Output {
        const output = self.outputs.getPtr(try outputIndex(root)) orelse return error.Protocol;
        try checkItemId(output, json.fieldStr(root, "item_id"));
        return output;
    }

    fn messageOutput(_: *Reducer, output: *Output) Error!*Output {
        if (output.kind != .message) return error.Protocol;
        return output;
    }

    fn outputBlockId(self: *Reducer, output: *Output, kind: event.BlockKind) Error!event.BlockId {
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

    /// True when this response opened a function call. It decides the stop reason at `completed`.
    fn hasToolBlock(self: *const Reducer) bool {
        // A dropped or unfinished tool block reaches no consumer, so it must not decide the stop reason.
        for (self.blocks.items) |block| if (block.kind == .tool and !block.open and !block.dropped) return true;
        return false;
    }

    fn addBlock(self: *Reducer, kind: event.BlockKind) Error!*Block {
        std.debug.assert(self.blocks.items.len <= limits.max_blocks);
        if (self.blocks.items.len >= limits.max_blocks) return error.Protocol;
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

    /// Copy peer bytes into reducer memory until `deinit`.
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

fn mapIncompleteReason(raw: []const u8) proto.enums.StopReason {
    if (std.mem.eql(u8, raw, "max_output_tokens")) return .length;
    if (std.mem.eql(u8, raw, "max_tokens")) return .length; // The docs expose both forms.
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return .unknown;
}

/// Hash an item id for identity checks. Zero marks an absent id, so a hashed zero moves to one.
fn itemIdHash(id: ?[]const u8) u64 {
    const text = id orelse return 0;
    const hash = std.hash.Wyhash.hash(0, text);
    return if (hash == 0) 1 else hash;
}

/// Compare an item id against the id that opened the item. An absent id on either side skips the check.
fn checkItemId(output: *const Output, id: ?[]const u8) Error!void {
    const hash = itemIdHash(id);
    if (output.item_id == 0 or hash == 0) return;
    if (output.item_id != hash) return error.Protocol;
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
    if (std.mem.eql(u8, part_type, "refusal")) return .{ .slot = &output.text, .kind = .text };
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
    try testing.expectEqual(proto.enums.StopReason.stop, done.stop_reason);
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
    // This API reports `completed` for a function call too, so the blocks decide the stop reason.
    // Reporting `stop` here makes the engine refuse the very tool part it was sent.
    try testing.expectEqual(proto.enums.StopReason.tool_calls, h.out.items[4].done.stop_reason);
}

// This is the shape that opencode zen relays: every item opens before the first one closes.
test "parallel tool items interleave and each block keeps its own call" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_a","name":"read"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":\"a\"}"}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_b","name":"read"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\":\"b\"}"}
        ,
        \\{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"path\":\"a\"}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"path\":\"a\"}"}}
        ,
        \\{"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"path\":\"b\"}"}
        ,
        \\{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","arguments":"{\"path\":\"b\"}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });

    // Both blocks open before either one stops, and each id follows the item that started it.
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[0].block_started.block);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[1].tool_input_delta.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[2].block_started.block);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[3].tool_input_delta.block);

    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[4].block_stopped.block);
    try testing.expectEqualStrings("call_a", h.out.items[4].block_stopped.result.tool.call_id);
    try testing.expectEqualStrings("{\"path\":\"a\"}", h.out.items[4].block_stopped.result.tool.arguments);
    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[5].block_stopped.block);
    try testing.expectEqualStrings("call_b", h.out.items[5].block_stopped.result.tool.call_id);
    try testing.expectEqualStrings("{\"path\":\"b\"}", h.out.items[5].block_stopped.result.tool.arguments);
    try testing.expectEqual(proto.enums.StopReason.tool_calls, h.out.items[6].done.stop_reason);
}

// Nothing orders the item completions, so a later item may close first.
test "parallel tool items may complete out of order" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_a","name":"read"}}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_b","name":"read"}}
        ,
        \\{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","arguments":"{}"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });

    try testing.expectEqual(@as(event.BlockId, 1), h.out.items[2].block_stopped.block);
    try testing.expectEqualStrings("call_b", h.out.items[2].block_stopped.result.tool.call_id);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[3].block_stopped.block);
    try testing.expectEqualStrings("call_a", h.out.items[3].block_stopped.result.tool.call_id);
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
    try testing.expectEqual(proto.enums.StopReason.length, done.stop_reason);
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

test "a reasoning item done with a mismatched type is rejected" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"message"}}
    }));
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

// A gateway that speaks both dialects can append the Chat Completions sentinel.
test "the chat done sentinel is ignored" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
        ,
        "[DONE]",
    });
    try testing.expectEqual(@as(usize, 1), h.out.items.len);
    try testing.expect(h.out.items[0] == .done);
}

// A rejection here would throw away an answer that already arrived in full.
test "a frame after the terminal response is ignored" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}
        ,
        \\{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}
        ,
        \\{"type":"response.output_text.delta","output_index":0,"delta":"hi"}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"message"}}
    });
    try testing.expectEqual(@as(usize, 4), h.out.items.len);
    try testing.expect(h.out.items[3] == .done);
}

// The arguments are partial, so the call must not reach the consumer.
test "a tool item still open at the terminal is dropped" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"cmd\":\"zig "}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });
    try testing.expectEqual(@as(usize, 3), h.out.items.len);
    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expect(h.out.items[1] == .tool_input_delta);
    // No block_stopped closes the tool, and the stop reason never claims a call.
    try testing.expect(h.out.items[2] == .done);
    try testing.expectEqual(proto.enums.StopReason.stop, h.out.items[2].done.stop_reason);
}

// A malformed trailer must not undo an answer that already arrived in full.
test "a malformed frame after the terminal response is ignored" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
        ,
        "{not json",
    });
    try testing.expectEqual(@as(usize, 1), h.out.items.len);
    try testing.expect(h.out.items[0] == .done);
}

// The arguments would otherwise attach to a call the event does not name.
test "an item id that names another item is rejected" {
    var h = Harness.init();
    defer h.deinit();
    try testing.expectError(error.Protocol, h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_2","delta":"{}"}
    }));
}

// The provider marks a call it never finished, so the call must not reach the consumer.
test "a tool item that reports an unfinished status is dropped" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"incomplete","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });
    try testing.expectEqual(@as(usize, 2), h.out.items.len);
    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expect(h.out.items[1] == .done);
    try testing.expectEqual(proto.enums.StopReason.stop, h.out.items[1].done.stop_reason);
}

// These are the frames the provider sent when `max_output_tokens` cut a call off mid-arguments.
test "a call cut off by the output cap reports length and no tool" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"in_progress","call_id":"call_1","name":"exec"}}
        ,
        \\{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{}}}
    });
    try testing.expectEqual(@as(usize, 2), h.out.items.len);
    try testing.expectEqual(event.BlockKind.tool, h.out.items[0].block_started.kind);
    try testing.expect(h.out.items[1] == .done);
    try testing.expectEqual(proto.enums.StopReason.length, h.out.items[1].done.stop_reason);
}

// One call finished and one did not, so only the finished call reaches the consumer.
test "a mix of closed and open tools keeps only the closed call" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"read"}}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_2","type":"function_call","call_id":"call_b","name":"read"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"completed","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });
    try testing.expectEqual(@as(usize, 4), h.out.items.len);
    try testing.expectEqual(@as(event.BlockId, 0), h.out.items[2].block_stopped.block);
    try testing.expectEqualStrings("call_a", h.out.items[2].block_stopped.result.tool.call_id);
    // The open call never stops, and the closed one still sets the stop reason.
    try testing.expectEqual(proto.enums.StopReason.tool_calls, h.out.items[3].done.stop_reason);
}

// A refusal arrives in its own content part, so it would otherwise commit an empty message.
test "a refusal streams as text and reports refusal" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message"}}
        ,
        \\{"type":"response.content_part.added","output_index":0,"content_index":0,"item_id":"msg_1","part":{"type":"refusal"}}
        ,
        \\{"type":"response.refusal.delta","output_index":0,"content_index":0,"item_id":"msg_1","delta":"I cannot help"}
        ,
        \\{"type":"response.refusal.done","output_index":0,"content_index":0,"item_id":"msg_1","refusal":"I cannot help"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_1","type":"message"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });

    try testing.expectEqual(event.BlockKind.text, h.out.items[0].block_started.kind);
    try testing.expectEqualStrings("I cannot help", h.out.items[1].text_delta.text);
    try testing.expect(h.out.items[2] == .block_stopped);
    // The turn reports the refusal, so a caller never reads it as a plain answer.
    try testing.expectEqual(proto.enums.StopReason.refusal, h.out.items[3].done.stop_reason);
}

// A refusal outranks a call, because the model declined the request it was given.
test "a refusal outranks a tool call in the stop reason" {
    var h = Harness.init();
    defer h.deinit();
    try h.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run"}}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"completed","arguments":"{}"}}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message"}}
        ,
        \\{"type":"response.content_part.added","output_index":1,"content_index":0,"item_id":"msg_1","part":{"type":"refusal"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
    });
    const done = h.out.items[h.out.items.len - 1].done;
    try testing.expectEqual(proto.enums.StopReason.refusal, done.stop_reason);
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
