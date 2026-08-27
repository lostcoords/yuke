//! The provider transport seam. A run pulls response bytes from a ResponseBody and feeds the SSE
//! parser. The real client suspends on the socket; a mock replays canned bytes for tests.

const std = @import("std");
const instance = @import("instance/instance.zig");
const sse = @import("stream/sse.zig");
const event = @import("stream/event.zig");

/// Cap the whole response so one turn cannot grow memory without bound.
const max_response_bytes = 16 * 1024 * 1024;

/// The caller fills only `body`; the real client fills `url` and `headers` from `resolve`.
pub const Header = instance.Header;
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

/// Open one provider response. The daemon injects this seam, so tests and the real client can vary the body.
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
/// Use cancelable zio I/O for reads that can block; the run task cancels the child, and the read returns error.Canceled.
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
            try reducer.decode(data, scratch.allocator(), &events);
            try emit(events.items, &saw_done, ctx, onEvent);
        }
        _ = scratch.reset(.retain_capacity); // Reset the arena after this read.
    }

    // Drain the parser tail and the reducer's terminal event.
    var tail: std.ArrayList([]const u8) = .empty;
    try parser.finish(scratch.allocator(), &tail);
    for (tail.items) |data| {
        events.clearRetainingCapacity();
        try reducer.decode(data, scratch.allocator(), &events);
        try emit(events.items, &saw_done, ctx, onEvent);
    }
    events.clearRetainingCapacity();
    try reducer.finish(&events);
    try emit(events.items, &saw_done, ctx, onEvent);

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

/// Replay canned response bytes. `chunk_size` splits the stream to test partial reads and cross-read SSE state.
/// A value of 0 delivers the whole body in one read.
pub const MockTransport = struct {
    bytes: []const u8,
    chunk_size: usize,
    offset: usize = 0,

    pub fn init(bytes: []const u8, chunk_size: usize) MockTransport {
        return .{ .bytes = bytes, .chunk_size = if (chunk_size == 0) bytes.len else chunk_size };
    }

    pub fn body(self: *MockTransport) ResponseBody {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Replay the canned response. The run loop calls this seam.
    pub fn open(self: *MockTransport, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) !ResponseBody {
        _ = info;
        _ = arena;
        _ = request;
        return self.body();
    }

    const vtable: ResponseBody.VTable = .{ .read = read, .deinit = deinitNoop };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        std.debug.assert(buf.len > 0); // The seam never reads into an empty buffer.
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        const remaining = self.bytes[self.offset..];
        const n = @min(@min(buf.len, self.chunk_size), remaining.len);
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

/// The no-providers fallback and tests use this canned reply. The real path uses `HttpTransport`.
pub const placeholder_reply =
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

/// The mock transport and the no-providers fallback replay these fixed bytes.
pub const CannedTransport = struct {
    bytes: []const u8,

    pub fn transport(self: *CannedTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .open = open };

    /// Allocate a fresh reader in `arena`. Concurrent runs then share no offset state.
    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        _ = info;
        _ = request;
        const self: *CannedTransport = @ptrCast(@alignCast(ctx));
        const reader = try arena.create(CannedReader);
        reader.* = .{ .bytes = self.bytes };
        return .{ .ctx = reader, .vtable = &CannedReader.vtable };
    }
};

/// This value represents one in-flight replay of canned bytes. The turn arena owns it.
const CannedReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    const vtable: ResponseBody.VTable = .{ .read = read, .deinit = deinitNoop };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        std.debug.assert(buf.len > 0);
        const self: *CannedReader = @ptrCast(@alignCast(ctx));
        const remaining = self.bytes[self.offset..];
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.offset += n;
        return n;
    }
    fn deinitNoop(_: *anyopaque) void {}
};

/// This transport returns one canned reply per `open`, in order. It drives multi-round turns. It records
/// each request body when `capture` holds an allocator, so a test can inspect the built request.
pub const SequenceTransport = struct {
    replies: []const []const u8,
    index: usize = 0,
    capture: ?std.mem.Allocator = null,
    requests: std.ArrayList([]const u8) = .empty,

    pub fn transport(self: *SequenceTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .open = open };

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        _ = info;
        const self: *SequenceTransport = @ptrCast(@alignCast(ctx));
        if (self.index >= self.replies.len) return error.NoMoreReplies;
        if (self.capture) |alloc| try self.requests.append(alloc, try alloc.dupe(u8, request.body));
        const reader = try arena.create(CannedReader);
        reader.* = .{ .bytes = self.replies[self.index] };
        self.index += 1;
        return .{ .ctx = reader, .vtable = &CannedReader.vtable };
    }
};

/// One scripted attempt.
pub const Step = union(enum) {
    /// The open call fails. No body arrives.
    open_error: anyerror,
    /// The open call succeeds and the body streams these bytes.
    body: []const u8,
    /// The body streams `prefix`, then the read fails.
    body_then_error: struct { prefix: []const u8, err: anyerror },
};

/// A transport that plays scripted attempts. A test drives the retry loop with it and counts the
/// opens, so a loop that never repeats fails the test.
pub const ScriptedTransport = struct {
    steps: []const Step,
    index: usize = 0,
    /// The number of open calls the loop made.
    opens: usize = 0,
    /// The adapter reports this for every attempt.
    delivery: AttemptInfo.Delivery = .definitely_unsent,
    retry_after_ms: ?u64 = null,
    /// A test sets this to observe the first open.
    opened: ?*bool = null,

    pub fn transport(self: *ScriptedTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .open = open };

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        _ = request;
        const self: *ScriptedTransport = @ptrCast(@alignCast(ctx));
        self.opens += 1;
        if (self.opened) |flag| flag.* = true;
        info.delivery = self.delivery;
        info.retry_after_ms = self.retry_after_ms;
        if (self.index >= self.steps.len) return error.NoMoreReplies;
        const step = self.steps[self.index];
        self.index += 1;
        switch (step) {
            .open_error => |err| return err,
            .body => |bytes| {
                const reader = try arena.create(ScriptedReader);
                reader.* = .{ .bytes = bytes };
                return .{ .ctx = reader, .vtable = &ScriptedReader.vtable };
            },
            .body_then_error => |b| {
                const reader = try arena.create(ScriptedReader);
                reader.* = .{ .bytes = b.prefix, .after = b.err };
                return .{ .ctx = reader, .vtable = &ScriptedReader.vtable };
            },
        }
    }
};

/// A reader that streams its bytes once, then ends or fails.
const ScriptedReader = struct {
    bytes: []const u8,
    sent: bool = false,
    after: ?anyerror = null,

    const vtable: ResponseBody.VTable = .{ .read = read, .deinit = deinit };

    fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *ScriptedReader = @ptrCast(@alignCast(ctx));
        if (!self.sent) {
            self.sent = true;
            const n = @min(buf.len, self.bytes.len);
            @memcpy(buf[0..n], self.bytes[0..n]);
            if (n != 0) return n;
        }
        if (self.after) |err| return err;
        return 0;
    }
    fn deinit(ctx: *anyopaque) void {
        _ = ctx;
    }
};

var placeholder_instance = CannedTransport{ .bytes = placeholder_reply };

/// This is the default daemon transport until startup connects a real adapter.
pub fn placeholderTransport() Transport {
    return placeholder_instance.transport();
}

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
    stop: ?wire.enums.StopReason = null,
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
    var mock = MockTransport.init(canned_text_turn, 7);
    try stream(testing.allocator, mock.body(), &reducer, &collector, StreamCollector.on);

    try testing.expectEqualStrings("Hello", collector.text.items);
    try testing.expectEqual(wire.enums.StopReason.stop, collector.stop.?);
    try testing.expectEqual(event.BlockKind.text, collector.first_block_kind.?);
    try testing.expectEqual(std.meta.Tag(event.BlockResult).text, collector.stop_result.?);
    try testing.expectEqual(@as(u64, 100), collector.usage_input.?);
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

    var mock = MockTransport.init(canned_truncated, 0);
    try testing.expectError(error.IncompleteStream, stream(testing.allocator, mock.body(), &reducer, &collector, StreamCollector.on));
}

const wire = @import("wire");
