//! Fold provider StreamEvents into a committed assistant message. Blocks arrive with dense ids in
//! start order and may overlap. E1 handles text and reasoning; a tool block waits for the tools slice.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const event = provider.event;

pub const Error = error{ ToolUnsupported, Protocol, OutOfMemory };

/// The identity and provenance the folder stamps onto the message. The result also borrows the
/// `agent` and `model` strings, so keep them alive with `arena`.
pub const Meta = struct {
    id: wire.ids.MessageId,
    run_id: wire.ids.RunId,
    config_rev: wire.ids.ConfigRev,
    agent: []const u8,
    created_at_ms: u64,
    model: []const u8,
    protocol: wire.enums.ProviderProtocol,
};

/// One assistant content block accumulated across its deltas.
const Block = struct {
    kind: event.BlockKind,
    text: std.ArrayList(u8) = .empty,
    stopped: bool = false,
    part: wire.message.AssistantPart = undefined,
};

/// Assemble an assistant message from a full StreamEvent list. The result borrows `arena`.
/// The stream is peer input, so a bad order, id, or block kind returns error.Protocol.
pub fn assistant(arena: std.mem.Allocator, events: []const event.StreamEvent, meta: Meta) Error!wire.message.AssistantMessage {
    var blocks: std.ArrayList(Block) = .empty;
    var done: ?event.Done = null;

    for (events) |ev| {
        if (done != null) return error.Protocol; // no event follows the terminal done
        switch (ev) {
            .block_started => |b| {
                if (b.block != blocks.items.len) return error.Protocol; // dense ids in start order
                try blocks.append(arena, .{ .kind = b.kind });
            },
            .text_delta => |d| try (try active(&blocks, d.block, .text)).text.appendSlice(arena, d.text),
            .reasoning_delta => |d| try (try active(&blocks, d.block, .reasoning)).text.appendSlice(arena, d.text),
            .tool_input_delta => |d| {
                _ = try active(&blocks, d.block, .tool); // a valid open tool block
                return error.ToolUnsupported;
            },
            .block_stopped => |b| {
                if (b.block >= blocks.items.len) return error.Protocol;
                const blk = &blocks.items[b.block];
                if (blk.stopped) return error.Protocol;
                blk.part = try finalize(arena, blk, b.block, b.result);
                blk.stopped = true;
            },
            .done => |d| {
                for (blocks.items) |b| if (!b.stopped) return error.Protocol; // done closes every block
                done = d;
            },
        }
    }

    const d = done orelse return error.Protocol; // drain requires the terminal done
    const content = try arena.alloc(wire.message.AssistantPart, blocks.items.len);
    for (blocks.items, content) |b, *c| c.* = b.part;
    return .{
        .id = meta.id,
        .run_id = meta.run_id,
        .config_rev = meta.config_rev,
        .agent = meta.agent,
        .content = content,
        .finish = d.stop_reason,
        .tokens = d.usage,
        .cost = null,
        .time = .{ .created_at_ms = meta.created_at_ms },
        .provenance = .{ .protocol = meta.protocol, .model = meta.model },
    };
}

/// Resolve an open block and check its id and kind against a delta.
fn active(blocks: *std.ArrayList(Block), id: event.BlockId, kind: event.BlockKind) Error!*Block {
    if (id >= blocks.items.len) return error.Protocol;
    const blk = &blocks.items[id];
    if (blk.stopped or blk.kind != kind) return error.Protocol;
    return blk;
}

/// Build the finished part. The stop result kind must match the block kind.
fn finalize(arena: std.mem.Allocator, blk: *const Block, id: event.BlockId, result: event.BlockResult) Error!wire.message.AssistantPart {
    const pid: wire.ids.PartId = id;
    switch (result) {
        .text => {
            if (blk.kind != .text) return error.Protocol;
            return .{ .text = .{ .id = pid, .text = blk.text.items } };
        },
        .reasoning => |r| {
            if (blk.kind != .reasoning) return error.Protocol;
            return .{ .reasoning = .{ .id = pid, .text = blk.text.items, .signature = try arena.dupe(u8, r.signature) } };
        },
        .redacted_reasoning => |r| {
            if (blk.kind != .redacted_reasoning) return error.Protocol;
            return .{ .redacted_reasoning = .{ .id = pid, .data = try arena.dupe(u8, r.data) } };
        },
        .tool => {
            if (blk.kind != .tool) return error.Protocol;
            return error.ToolUnsupported;
        },
    }
}

const testing = std.testing;
const transport = provider.transport;
const anthropic = provider.anthropic;

const usage_zero: wire.message.TokenUsage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 };

fn meta1() Meta {
    return .{ .id = 1, .run_id = 1, .config_rev = 0, .agent = "a", .created_at_ms = 1, .model = "m", .protocol = .@"anthropic-messages" };
}

fn frame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

const canned =
    frame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":100}}}
    ) ++ frame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++ frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
    ) ++ frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}
    ) ++ frame(
        \\{"type":"content_block_stop","index":0}
    ) ++ frame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
    ) ++ frame(
        \\{"type":"message_stop"}
    );

test "assistant folds a text turn into one part with finish and tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var events: std.ArrayList(event.StreamEvent) = .empty;
    defer events.deinit(testing.allocator);
    var mock = transport.MockTransport.init(canned, 0);
    try transport.drain(testing.allocator, a, mock.body(), &reducer, &events);

    const msg = try assistant(a, events.items, meta1());
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("Hello", msg.content[0].text.text);
    try testing.expectEqual(wire.enums.StopReason.stop, msg.finish.?);
    try testing.expectEqual(@as(u64, 100), msg.tokens.?.input);
    try testing.expectEqual(@as(u64, 5), msg.tokens.?.output);
}

test "overlapping text and reasoning blocks fold in id order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const events = [_]event.StreamEvent{
        .{ .block_started = .{ .block = 0, .kind = .text } },
        .{ .block_started = .{ .block = 1, .kind = .reasoning } },
        .{ .reasoning_delta = .{ .block = 1, .text = "why" } },
        .{ .text_delta = .{ .block = 0, .text = "hi" } },
        .{ .block_stopped = .{ .block = 1, .result = .{ .reasoning = .{ .signature = "sig" } } } },
        .{ .block_stopped = .{ .block = 0, .result = .text } },
        .{ .done = .{ .stop_reason = .stop, .raw_stop_reason = "end_turn", .usage = usage_zero } },
    };
    const msg = try assistant(arena.allocator(), &events, meta1());
    try testing.expectEqual(@as(usize, 2), msg.content.len);
    try testing.expectEqualStrings("hi", msg.content[0].text.text);
    try testing.expectEqualStrings("why", msg.content[1].reasoning.text);
    try testing.expectEqualStrings("sig", msg.content[1].reasoning.signature);
}

test "the fold rejects malformed streams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const done: event.StreamEvent = .{ .done = .{ .stop_reason = .stop, .raw_stop_reason = "x", .usage = usage_zero } };

    // A first block id must be 0.
    try testing.expectError(error.Protocol, assistant(a, &.{.{ .block_started = .{ .block = 1, .kind = .text } }}, meta1()));
    // A delta kind must match the block kind.
    try testing.expectError(error.Protocol, assistant(a, &.{
        .{ .block_started = .{ .block = 0, .kind = .reasoning } },
        .{ .text_delta = .{ .block = 0, .text = "x" } },
    }, meta1()));
    // done must close every block.
    try testing.expectError(error.Protocol, assistant(a, &.{
        .{ .block_started = .{ .block = 0, .kind = .text } },
        done,
    }, meta1()));
    // No event follows done.
    try testing.expectError(error.Protocol, assistant(a, &.{ done, done }, meta1()));
    // A missing done is truncated.
    try testing.expectError(error.Protocol, assistant(a, &.{
        .{ .block_started = .{ .block = 0, .kind = .text } },
        .{ .block_stopped = .{ .block = 0, .result = .text } },
    }, meta1()));
}

test "a tool block is unsupported in E1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ToolUnsupported, assistant(arena.allocator(), &.{
        .{ .block_started = .{ .block = 0, .kind = .tool } },
        .{ .tool_input_delta = .{ .block = 0, .partial_json = "{}" } },
    }, meta1()));
}
