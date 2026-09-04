//! The transport pulls response bytes from a `ResponseBody` and sends them to the SSE parser.

const std = @import("std");
const instance = @import("instance/instance.zig");
const sse = @import("stream/sse.zig");
const event = @import("stream/event.zig");
const types = @import("types.zig");

/// Cap the whole response so one turn cannot grow memory without bound.
const max_response_bytes = types.limits.max_response_bytes;

/// A direct caller fills all fields; a route resolver can fill the URL and headers.
pub const Header = instance.Header;

pub fn headersValid(headers: []const Header) bool {
    return instance.validHeaders(headers);
}
pub const Request = struct {
    url: []const u8 = "",
    headers: []const Header = &.{},
    body: []u8,
};

/// What one attempt learned. The adapter fills it; the retry classifier reads it after a failure.
pub const AttemptInfo = struct {
    /// A parsed `retry-after-ms`, or `retry-after` converted to milliseconds.
    retry_after_ms: ?u64 = null,
    /// `x-should-retry`. A false value vetoes a retry.
    should_retry: ?bool = null,
    /// The adapter sets this before the first body write. A later transport fault is then ambiguous.
    delivery: Delivery = .definitely_unsent,

    pub const Delivery = enum { definitely_unsent, possibly_sent };
};

/// Open one provider response through an injected transport.
/// The run's reader child calls open. The returned body borrows `arena` for the turn.
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

/// A response body provides one provider response. The reader child reads to end of stream, then deinits.
/// A blocking adapter must use cancelable `std.Io` and return `error.Canceled` after cancellation.
pub const ResponseBody = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Fill a non-empty `buf` with one or more bytes, or return 0 at end of stream.
        /// A real adapter must retry a non-EOF zero-byte read and map only std EndOfStream to 0.
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn read(self: ResponseBody, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ctx, buf);
    }
    pub fn deinit(self: ResponseBody) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Pull the response and hand each StreamEvent to `onEvent`. Reset scratch after each read.
/// This prevents parse trees from accumulating for the whole turn. The callback must copy each borrowed slice before it returns.
pub fn stream(
    gpa: std.mem.Allocator,
    body: ResponseBody,
    reducer: anytype,
    ctx: anytype,
    comptime onEvent: fn (@TypeOf(ctx), event.StreamEvent) anyerror!void,
) !void {
    var parser: sse.Sse = .init(gpa);
    defer parser.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    // The reducer appends events with its own gpa, so it owns this backing memory.
    var events: std.ArrayList(event.StreamEvent) = .empty;
    defer events.deinit(reducer.gpa);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var saw_done = false;

    while (true) {
        const n = try body.read(&buf);
        if (n == 0) break;
        total += n;
        if (total > max_response_bytes) return error.ResponseTooLarge;
        // Create the list inside the read loop. The scratch allocator owns and resets its backing after the read.
        var frames: std.ArrayList([]const u8) = .empty;
        try parser.push(buf[0..n], scratch.allocator(), &frames);
        for (frames.items) |data| {
            events.clearRetainingCapacity();
            try decodeFrame(reducer, data, scratch.allocator(), &events);
            try emit(events.items, &saw_done, ctx, onEvent);
        }
        _ = scratch.reset(.retain_capacity); // Reset the arena after this read.
    }

    // Drain the parser tail and the reducer's terminal event.
    var tail: std.ArrayList([]const u8) = .empty;
    try parser.finish(scratch.allocator(), &tail);
    for (tail.items) |data| {
        events.clearRetainingCapacity();
        try decodeFrame(reducer, data, scratch.allocator(), &events);
        try emit(events.items, &saw_done, ctx, onEvent);
    }

    if (!saw_done) return error.IncompleteStream; // Treat a stream without the terminal done event as truncated.
}

fn decodeFrame(
    reducer: anytype,
    data: []const u8,
    scratch: std.mem.Allocator,
    events: *std.ArrayList(event.StreamEvent),
) !void {
    return reducer.decode(data, scratch, events);
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

/// Replay canned bytes as one response body. A `chunk_size` of 0 fills the caller buffer.
pub const ReplayReader = struct {
    bytes: []const u8,
    chunk_size: usize = 0,
    offset: usize = 0,
    /// The read fails with this error after it delivers every byte.
    after: ?anyerror = null,

    pub fn body(self: *ReplayReader) ResponseBody {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ResponseBody.VTable = .{ .read = read, .deinit = deinitNoop };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        std.debug.assert(buf.len > 0); // The seam never reads into an empty buffer.
        const self: *ReplayReader = @ptrCast(@alignCast(ctx));
        const remaining = self.bytes[self.offset..];
        if (remaining.len == 0) return self.after orelse 0;
        const limit = if (self.chunk_size == 0) buf.len else @min(buf.len, self.chunk_size);
        const n = @min(limit, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.offset += n;
        return n;
    }
    fn deinitNoop(_: *anyopaque) void {}
};

/// Wrap a JSON event body as one SSE event.
fn frame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

/// A test uses this canned reply. The real path uses `HttpTransport`.
pub const canned_reply =
    frame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":0}}}
    ) ++ frame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++ frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from the yuke mock provider."}}
    ) ++ frame(
        \\{"type":"content_block_stop","index":0}
    ) ++ frame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}
    ) ++ frame(
        \\{"type":"message_stop"}
    );

/// Replay one fixed reply for every open. A test uses it.
pub const CannedTransport = struct {
    bytes: []const u8,

    pub fn transport(self: *CannedTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .open = open };

    /// Allocate a fresh reader in `arena`. Concurrent runs then share no offset state.
    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        _ = .{ request, info };
        const self: *CannedTransport = @ptrCast(@alignCast(ctx));
        const reader = try arena.create(ReplayReader);
        reader.* = .{ .bytes = self.bytes };
        return reader.body();
    }
};

const testing = std.testing;
const anthropic = @import("stream/anthropic.zig");

const canned_text_turn =
    frame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20}}}
    ) ++
    frame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++
    frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
    ) ++
    frame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}
    ) ++
    frame(
        \\{"type":"content_block_stop","index":0}
    ) ++
    frame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
    ) ++
    frame(
        \\{"type":"message_stop"}
    );

const canned_truncated =
    frame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":100}}}
    ) ++
    frame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++
    frame(
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
    try stream(testing.allocator, replay.body(), &reducer, &collector, StreamCollector.on);

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
    try testing.expectError(error.IncompleteStream, stream(testing.allocator, replay.body(), &reducer, &collector, StreamCollector.on));
}
