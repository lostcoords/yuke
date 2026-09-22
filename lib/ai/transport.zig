//! The transport pulls response bytes from a `ResponseBody` and sends them to the SSE parser.

const std = @import("std");
const http = @import("transport/http.zig");
const route = @import("route.zig");
const sse = @import("stream/sse.zig");
const event = @import("stream/event.zig");
const types = @import("types.zig");
const answer = @import("answer.zig");

pub const HttpTransport = http.HttpTransport;
pub const HttpError = http.Error;

/// Cap the whole response so one turn cannot grow memory without bound.
const max_response_bytes = types.limits.max_response_bytes;

pub const Request = route.Request;

/// What one attempt learned. The adapter fills it; the retry classifier reads it after a failure.
pub const AttemptInfo = struct {
    /// A parsed `retry-after-ms`, or `retry-after` converted to milliseconds.
    retry_after_ms: ?u64 = null,
    /// The provider sent `x-should-retry: false`, which vetoes a retry.
    no_retry: bool = false,
    /// The adapter sets this before the first body write. A later transport fault is then ambiguous.
    delivery: Delivery = .definitely_unsent,
    /// The status of a non-200 answer; a 200 stream that fails later leaves it null.
    status: ?u16 = null,
    /// The provider request id from `request-id` or `x-request-id`, when the answer names one.
    request_id: ?[]const u8 = null,
    /// The first bytes of the error answer, at most `max_error_body_bytes`: a non-200 body, or the stream event that failed a 200 response.
    body: ?[]const u8 = null,

    pub const Delivery = enum { definitely_unsent, possibly_sent };
    pub const max_error_body_bytes: usize = 4096;
};

/// Open one provider response through an injected transport, whose body borrows `arena`.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody,
    };

    pub fn open(self: Transport, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        return self.vtable.open(self.ctx, arena, request, info);
    }
};

/// One provider response. A blocking adapter uses cancelable `std.Io` and returns `error.Canceled`.
pub const ResponseBody = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return the bytes the response holds now, or an empty slice at the end of the stream.
        peek: *const fn (ctx: *anyopaque) anyerror![]const u8,
        /// Drop the first `count` bytes of the last peek, which stay readable until the next peek.
        toss: *const fn (ctx: *anyopaque, count: usize) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn peek(self: ResponseBody) anyerror![]const u8 {
        return self.vtable.peek(self.ctx);
    }
    pub fn toss(self: ResponseBody, count: usize) void {
        self.vtable.toss(self.ctx, count);
    }
    pub fn deinit(self: ResponseBody) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Hand each StreamEvent to `onEvent`, which copies what it keeps; an error event leaves its bytes in `info.body` in `arena`.
pub fn stream(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: ResponseBody,
    info: *AttemptInfo,
    reducer: anytype,
    ctx: anytype,
    comptime onEvent: fn (@TypeOf(ctx), event.StreamEvent) anyerror!void,
) !void {
    var parser: sse.Sse = .init(gpa, max_response_bytes);
    defer parser.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var events: std.ArrayList(event.StreamEvent) = .empty;
    defer events.deinit(gpa);

    var saw_done = false;
    // The parser owns the payload until the next call, so the decode and the emit run first.
    while (try parser.next(body)) |data| {
        events.clearRetainingCapacity();
        reducer.decode(data, scratch.allocator(), &events) catch |err| {
            std.debug.assert(info.body == null); // a 200 stream has no error body yet
            if (answer.isAnswer(err)) info.body = try arena.dupe(u8, data[0..@min(data.len, AttemptInfo.max_error_body_bytes)]);
            return err;
        };
        try emit(events.items, &saw_done, ctx, onEvent);
        _ = scratch.reset(.retain_capacity);
    }

    if (!saw_done) return error.IncompleteStream; // Treat a stream without the terminal done event as truncated.
}

/// Hand each event to the callback. Reject an event after the terminal done.
fn emit(
    events: []const event.StreamEvent,
    saw_done: *bool,
    ctx: anytype,
    comptime onEvent: fn (@TypeOf(ctx), event.StreamEvent) anyerror!void,
) !void {
    for (events) |ev| {
        if (saw_done.*) return error.Protocol; // The terminal done event has no next event.
        try onEvent(ctx, ev);
        if (ev == .done) saw_done.* = true;
    }
}

const testing = std.testing;
const anthropic = @import("stream/anthropic.zig");
const ReplayReader = @import("testing.zig").ReplayReader;
const sseFrame = @import("testing.zig").sseFrame;

const canned_text_turn =
    sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20}}}
    ) ++
    sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++
    sseFrame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
    ) ++
    sseFrame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}
    ) ++
    sseFrame(
        \\{"type":"content_block_stop","index":0}
    ) ++
    sseFrame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
    ) ++
    sseFrame(
        \\{"type":"message_stop"}
    );

const canned_truncated =
    sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":100}}}
    ) ++
    sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++
    sseFrame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
    );

const StreamCollector = struct {
    gpa: std.mem.Allocator,
    kinds: std.ArrayList(std.meta.Tag(event.StreamEvent)) = .empty,
    text: std.ArrayList(u8) = .empty,
    stop: ?types.FinishReason = null,
    first_block_kind: ?event.BlockKind = null,
    stop_result: ?std.meta.Tag(event.BlockResult) = null,
    usage_input: ?u64 = null,
    usage_output: ?u64 = null,

    fn deinit(self: *StreamCollector) void {
        self.kinds.deinit(self.gpa);
        self.text.deinit(self.gpa);
    }
    fn on(self: *StreamCollector, ev: event.StreamEvent) !void {
        try self.kinds.append(self.gpa, std.meta.activeTag(ev));
        switch (ev) {
            .block_started => |b| if (self.first_block_kind == null) {
                self.first_block_kind = b.kind;
            },
            .text_delta => |d| try self.text.appendSlice(self.gpa, d.text),
            .block_stopped => |b| self.stop_result = std.meta.activeTag(b.result),
            .done => |d| {
                self.stop = d.stop_reason;
                self.usage_input = d.usage.input;
                self.usage_output = d.usage.output;
            },
            else => {},
        }
    }
};

test "stream delivers each event to the callback across fragmented reads" {
    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    // A 7-byte chunk splits SSE events across reads, so the parser holds cross-read state.
    var replay: ReplayReader = .{ .bytes = canned_text_turn, .chunk_size = 7 };
    var info: AttemptInfo = .{};
    try stream(testing.allocator, testing.allocator, replay.body(), &info, &reducer, &collector, StreamCollector.on);
    try testing.expectEqual(@as(?[]const u8, null), info.body);

    try testing.expectEqualStrings("Hello", collector.text.items);
    try testing.expectEqual(types.FinishReason.stop, collector.stop.?);
    try testing.expectEqual(event.BlockKind.text, collector.first_block_kind.?);
    try testing.expectEqual(std.meta.Tag(event.BlockResult).text, collector.stop_result.?);
    try testing.expectEqual(@as(u64, 120), collector.usage_input.?); // The cache subsets belong to input.
    try testing.expectEqual(@as(u64, 5), collector.usage_output.?);
    // The order is block_started, two text_delta, block_stopped, done.
    try testing.expectEqual(@as(usize, 5), collector.kinds.items.len);
    try testing.expectEqual(std.meta.activeTag(event.StreamEvent{ .block_started = undefined }), collector.kinds.items[0]);
    try testing.expectEqual(std.meta.activeTag(event.StreamEvent{ .done = undefined }), collector.kinds.items[4]);
}

test "stream reports a truncated stream" {
    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    var replay: ReplayReader = .{ .bytes = canned_truncated };
    var info: AttemptInfo = .{};
    try testing.expectError(error.IncompleteStream, stream(testing.allocator, testing.allocator, replay.body(), &info, &reducer, &collector, StreamCollector.on));
    try testing.expectEqual(@as(?[]const u8, null), info.body);
}

test "stream keeps the bytes of the error event that failed a 200 response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    const failed_event =
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    ;
    var replay: ReplayReader = .{ .bytes = comptime sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":1}}}
    ) ++ sseFrame(failed_event) };
    var info: AttemptInfo = .{};
    try testing.expectError(error.ServerError, stream(testing.allocator, arena.allocator(), replay.body(), &info, &reducer, &collector, StreamCollector.on));
    try testing.expectEqualStrings(failed_event, info.body.?);
    // The provider answered 200, so the attempt carries no status.
    try testing.expectEqual(@as(?u16, null), info.status);
}

test "stream keeps no bytes for a malformed event, which is no provider answer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    var replay: ReplayReader = .{ .bytes = sseFrame("{not json") };
    var info: AttemptInfo = .{};
    try testing.expectError(error.Protocol, stream(testing.allocator, arena.allocator(), replay.body(), &info, &reducer, &collector, StreamCollector.on));
    try testing.expectEqual(@as(?[]const u8, null), info.body);
}
