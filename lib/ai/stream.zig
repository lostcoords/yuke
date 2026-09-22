//! A stream pulls SSE payloads from one response body and answers neutral events one at a time.

const std = @import("std");
const event = @import("stream/event.zig");
const sse = @import("stream/sse.zig");
const anthropic = @import("stream/anthropic.zig");
const openai_chat = @import("stream/openai_chat.zig");
const openai_responses = @import("stream/openai_responses.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");
const answer = @import("answer.zig");
const testing_transport = @import("testing.zig");

const AttemptInfo = transport.AttemptInfo;

/// Cap the whole response so one turn cannot grow memory without bound.
const max_response_bytes = types.limits.max_response_bytes;

/// One reducer per closed protocol.
const Reducer = union(types.Protocol) {
    anthropic_messages: anthropic.Reducer,
    openai_chat: openai_chat.Reducer,
    openai_responses: openai_responses.Reducer,

    fn init(gpa: std.mem.Allocator, protocol: types.Protocol) Reducer {
        return switch (protocol) {
            inline else => |tag| @unionInit(Reducer, @tagName(tag), .init(gpa)),
        };
    }

    fn deinit(self: *Reducer) void {
        switch (self.*) {
            inline else => |*reducer| reducer.deinit(),
        }
    }

    fn decode(self: *Reducer, data: []const u8, scratch: std.mem.Allocator, out: *std.ArrayList(event.StreamEvent)) !void {
        switch (self.*) {
            inline else => |*reducer| try reducer.decode(data, scratch, out),
        }
    }
};

/// Decode one response body. The stream borrows the body, `arena`, and `info`; the caller closes the body after `deinit`.
pub const Stream = struct {
    arena: std.mem.Allocator,
    body: transport.ResponseBody,
    info: *AttemptInfo,
    reducer: Reducer,
    parser: sse.Sse,
    /// The decode scratch of the current payload. The events of that payload borrow it.
    scratch: std.heap.ArenaAllocator,
    events: std.ArrayList(event.StreamEvent) = .empty,
    /// The next event of `events` to answer.
    index: usize = 0,
    saw_done: bool = false,
    ended: bool = false,

    /// Use `gpa` for scratch until `deinit`. A failed 200 stream keeps its error event in `info.body`, in `arena`.
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, body: transport.ResponseBody, info: *AttemptInfo, protocol: types.Protocol) Stream {
        return .{
            .arena = arena,
            .body = body,
            .info = info,
            .reducer = .init(gpa, protocol),
            .parser = .init(gpa, max_response_bytes),
            .scratch = .init(gpa),
        };
    }

    pub fn deinit(self: *Stream) void {
        const gpa = self.parser.gpa;
        self.events.deinit(gpa);
        self.scratch.deinit();
        self.parser.deinit();
        self.reducer.deinit();
        self.* = undefined;
    }

    /// Answer the next event, or null after the terminal done at the end of the body. Event slices expire at the next call.
    pub fn next(self: *Stream) !?event.StreamEvent {
        std.debug.assert(self.index <= self.events.items.len);
        while (self.index == self.events.items.len) {
            if (self.ended) return null;
            self.events.clearRetainingCapacity();
            self.index = 0;
            _ = self.scratch.reset(.retain_capacity);
            // The parser owns the payload until its next call, so every event of one payload drains first.
            const data = try self.parser.next(self.body) orelse {
                self.ended = true;
                // Treat a stream without the terminal done event as truncated.
                if (!self.saw_done) return error.IncompleteStream;
                return null;
            };
            self.reducer.decode(data, self.scratch.allocator(), &self.events) catch |err| {
                std.debug.assert(self.info.body == null); // A 200 stream has no error body yet.
                if (answer.isAnswer(err)) self.info.body = try self.arena.dupe(u8, data[0..@min(data.len, AttemptInfo.max_error_body_bytes)]);
                return err;
            };
        }
        const ev = self.events.items[self.index];
        self.index += 1;
        if (self.saw_done) return error.Protocol; // The terminal done event has no next event.
        if (ev == .done) self.saw_done = true;
        return ev;
    }
};

const testing = std.testing;
const ReplayReader = testing_transport.ReplayReader;
const sseFrame = testing_transport.sseFrame;

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

/// Drain a stream into the facts the tests read.
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
    fn drain(self: *StreamCollector, s: *Stream) !void {
        while (try s.next()) |ev| try self.on(ev);
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

test "a stream answers each event across fragmented reads" {
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    // A 7-byte chunk splits SSE events across reads, so the parser holds cross-read state.
    var replay: ReplayReader = .{ .bytes = canned_text_turn, .chunk_size = 7 };
    var info: AttemptInfo = .{};
    var s = Stream.init(testing.allocator, testing.allocator, replay.body(), &info, .anthropic_messages);
    defer s.deinit();
    try collector.drain(&s);
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
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    var replay: ReplayReader = .{ .bytes = canned_truncated };
    var info: AttemptInfo = .{};
    var s = Stream.init(testing.allocator, testing.allocator, replay.body(), &info, .anthropic_messages);
    defer s.deinit();
    try testing.expectError(error.IncompleteStream, collector.drain(&s));
    try testing.expectEqual(@as(?[]const u8, null), info.body);
}

test "stream keeps the bytes of the error event that failed a 200 response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    const failed_event =
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    ;
    var replay: ReplayReader = .{ .bytes = comptime sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":1}}}
    ) ++ sseFrame(failed_event) };
    var info: AttemptInfo = .{};
    var s = Stream.init(testing.allocator, arena.allocator(), replay.body(), &info, .anthropic_messages);
    defer s.deinit();
    try testing.expectError(error.ServerError, collector.drain(&s));
    try testing.expectEqualStrings(failed_event, info.body.?);
    // The provider answered 200, so the attempt carries no status.
    try testing.expectEqual(@as(?u16, null), info.status);
}

test "stream keeps no bytes for a malformed event, which is no provider answer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var collector: StreamCollector = .{ .gpa = testing.allocator };
    defer collector.deinit();

    var replay: ReplayReader = .{ .bytes = sseFrame("{not json") };
    var info: AttemptInfo = .{};
    var s = Stream.init(testing.allocator, arena.allocator(), replay.body(), &info, .anthropic_messages);
    defer s.deinit();
    try testing.expectError(error.Protocol, collector.drain(&s));
    try testing.expectEqual(@as(?[]const u8, null), info.body);
}
