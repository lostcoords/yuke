//! The provider transport seam. A run pulls response bytes from a ResponseBody and feeds the SSE
//! parser. The real client suspends on the socket; a mock replays canned bytes for tests.

const std = @import("std");
const sse = @import("stream/sse.zig");
const event = @import("stream/event.zig");

/// Cap the whole response so one turn cannot grow memory without bound.
const max_response_bytes = 16 * 1024 * 1024;

/// A provider HTTP request. This fills only `body`; the real client fills url and headers from resolve.
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Request = struct {
    url: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8,
};

/// A pulled byte stream of one provider response. The owner reads until end of stream, then deinits.
/// `ctx` stays live until deinit. The real client maps its std.Io.Reader semantics to this contract.
pub const ResponseBody = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Fill `buf` (never empty) with one or more bytes, or return 0 at end of stream. A real
        /// adapter must retry a non-EOF zero-byte read and map only std EndOfStream to 0.
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        /// Stop an in-flight read. It returns after no read touches `ctx`, so deinit is then safe.
        cancel: *const fn (ctx: *anyopaque) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn read(self: ResponseBody, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ctx, buf);
    }
    pub fn cancel(self: ResponseBody) void {
        self.vtable.cancel(self.ctx);
    }
    pub fn deinit(self: ResponseBody) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Pull the whole response body and reduce it to StreamEvents. `reducer` is the provider reducer.
/// The provider reducer defines the payload lifetimes; keep the scratch arena and reducer alive.
pub fn drain(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: ResponseBody,
    reducer: anytype,
    out: *std.ArrayList(event.StreamEvent),
) !void {
    var parser: sse.Sse = .init(gpa);
    defer parser.deinit();
    var frames: std.ArrayList([]const u8) = .empty; // the arena owns the frame slices
    defer frames.deinit(arena);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try body.read(&buf);
        if (n == 0) break;
        total += n;
        if (total > max_response_bytes) return error.ResponseTooLarge; // bound a long or hostile stream
        frames.clearRetainingCapacity();
        try parser.push(buf[0..n], arena, &frames);
        for (frames.items) |data| try reducer.decode(data, arena, out);
    }
    frames.clearRetainingCapacity();
    try parser.finish(arena, &frames);
    for (frames.items) |data| try reducer.decode(data, arena, out);
    try reducer.finish(out);

    // A turn ends with a terminal `done`. A stream that ends before it is truncated.
    if (out.items.len == 0 or out.items[out.items.len - 1] != .done) return error.IncompleteStream;
}

/// Pull the response and hand each StreamEvent to `onEvent`. Reset the scratch after each read, so parse
/// trees do not accumulate for the whole turn. An event borrows the scratch, so `onEvent` copies what it
/// keeps before it returns.
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
    // The reducer appends events with its own gpa, so this backing survives a scratch reset.
    var events: std.ArrayList(event.StreamEvent) = .empty;
    defer events.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var saw_done = false;

    while (true) {
        const n = try body.read(&buf);
        if (n == 0) break;
        total += n;
        if (total > max_response_bytes) return error.ResponseTooLarge;
        // A fresh frames list each read. Its backing lives in scratch and is discarded with the reset.
        var frames: std.ArrayList([]const u8) = .empty;
        try parser.push(buf[0..n], scratch.allocator(), &frames);
        for (frames.items) |data| {
            events.clearRetainingCapacity();
            try reducer.decode(data, scratch.allocator(), &events);
            for (events.items) |ev| {
                if (ev == .done) saw_done = true;
                try onEvent(ctx, ev);
            }
        }
        _ = scratch.reset(.retain_capacity); // free this read's frame slices and parse trees
    }

    // Drain the parser tail and the reducer's terminal event.
    var tail: std.ArrayList([]const u8) = .empty;
    try parser.finish(scratch.allocator(), &tail);
    for (tail.items) |data| {
        events.clearRetainingCapacity();
        try reducer.decode(data, scratch.allocator(), &events);
        for (events.items) |ev| {
            if (ev == .done) saw_done = true;
            try onEvent(ctx, ev);
        }
    }
    events.clearRetainingCapacity();
    try reducer.finish(&events);
    for (events.items) |ev| {
        if (ev == .done) saw_done = true;
        try onEvent(ctx, ev);
    }

    if (!saw_done) return error.IncompleteStream; // a stream that ends before the terminal done is truncated
}

/// Replays canned response bytes. `chunk_size` fragments the stream to exercise partial reads and the
/// SSE parser's cross-read state. 0 delivers the whole body in one read.
pub const MockTransport = struct {
    bytes: []const u8,
    chunk_size: usize,
    offset: usize = 0,
    canceled: bool = false,
    captured: ?[]const u8 = null, // the last request body, for assertions

    pub fn init(bytes: []const u8, chunk_size: usize) MockTransport {
        return .{ .bytes = bytes, .chunk_size = if (chunk_size == 0) bytes.len else chunk_size };
    }

    pub fn body(self: *MockTransport) ResponseBody {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Record the request and replay the canned response. The seam the run loop calls.
    pub fn open(self: *MockTransport, arena: std.mem.Allocator, request: Request) !ResponseBody {
        _ = arena;
        self.captured = request.body;
        return self.body();
    }

    const vtable: ResponseBody.VTable = .{ .read = read, .cancel = cancel, .deinit = deinitNoop };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        std.debug.assert(buf.len > 0); // the seam never reads into an empty buffer
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.canceled) return error.Canceled;
        const remaining = self.bytes[self.offset..];
        const n = @min(@min(buf.len, self.chunk_size), remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.offset += n;
        return n;
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.canceled = true;
    }
    fn deinitNoop(_: *anyopaque) void {}
};

const testing = std.testing;
const anthropic = @import("stream/anthropic.zig");

/// Wrap a JSON event body as one SSE event.
fn frame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

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

test "drain reduces a fragmented mock SSE stream to StreamEvents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var out: std.ArrayList(event.StreamEvent) = .empty;
    defer out.deinit(testing.allocator);

    // A 7-byte chunk splits SSE events across reads, so the parser must hold cross-read state.
    var mock = MockTransport.init(canned_text_turn, 7);
    try drain(testing.allocator, arena.allocator(), mock.body(), &reducer, &out);

    try testing.expectEqual(@as(usize, 5), out.items.len);
    try testing.expectEqual(event.BlockKind.text, out.items[0].block_started.kind);
    try testing.expectEqualStrings("Hel", out.items[1].text_delta.text);
    try testing.expectEqualStrings("lo", out.items[2].text_delta.text);
    try testing.expect(out.items[3].block_stopped.result == .text);
    const done = out.items[4].done;
    try testing.expectEqual(wire.enums.StopReason.stop, done.stop_reason);
    try testing.expectEqual(@as(u64, 100), done.usage.input);
    try testing.expectEqual(@as(u64, 5), done.usage.output);
}

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

test "a stream that ends before done is truncated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reducer = anthropic.Reducer.init(testing.allocator);
    defer reducer.deinit();
    var out: std.ArrayList(event.StreamEvent) = .empty;
    defer out.deinit(testing.allocator);

    var mock = MockTransport.init(canned_truncated, 0);
    try testing.expectError(error.IncompleteStream, drain(testing.allocator, arena.allocator(), mock.body(), &reducer, &out));
}

test "cancel makes the next read fail" {
    var mock = MockTransport.init(canned_text_turn, 0);
    const b = mock.body();
    b.cancel();
    var buf: [16]u8 = undefined;
    try testing.expectError(error.Canceled, b.read(&buf));
}

const StreamCollector = struct {
    gpa: std.mem.Allocator,
    kinds: std.ArrayList(std.meta.Tag(event.StreamEvent)) = .empty,
    text: std.ArrayList(u8) = .empty,
    stop: ?wire.enums.StopReason = null,

    fn deinit(self: *StreamCollector) void {
        self.kinds.deinit(self.gpa);
        self.text.deinit(self.gpa);
    }
    fn on(self: *StreamCollector, ev: event.StreamEvent) !void {
        try self.kinds.append(self.gpa, std.meta.activeTag(ev));
        switch (ev) {
            .text_delta => |d| try self.text.appendSlice(self.gpa, d.text),
            .done => |d| self.stop = d.stop_reason,
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
    var mock = MockTransport.init(canned_text_turn, 7);
    try stream(testing.allocator, mock.body(), &reducer, &collector, StreamCollector.on);

    try testing.expectEqualStrings("Hello", collector.text.items);
    try testing.expectEqual(wire.enums.StopReason.stop, collector.stop.?);
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

    var mock = MockTransport.init(canned_truncated, 0);
    try testing.expectError(error.IncompleteStream, stream(testing.allocator, mock.body(), &reducer, &collector, StreamCollector.on));
}

const wire = @import("wire");
