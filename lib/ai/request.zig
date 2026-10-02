//! A request validates the IR and writes it in the wire shape of one closed protocol.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("request/ir.zig");
const anthropic = @import("request/anthropic.zig");
const openai_chat = @import("request/openai_chat.zig");
const openai_responses = @import("request/openai_responses.zig");
const types = @import("types.zig");

/// The encoded history array of a series of requests. A request encodes again only from the first element that can change.
/// The caller owns it with `gpa` and keeps it while a request borrows `items`.
pub const History = struct {
    /// The encoded elements, joined by commas, then the head of the last request. One buffer holds both.
    items: std.ArrayList(u8) = .empty,
    /// One entry for each block that `items` encodes. One allocation holds both columns.
    blocks: std.MultiArrayList(Block) = .empty,
    /// The hash of the request fields that shape the elements. Another value encodes every element again.
    key: u64 = 0,
    /// The first block of the element that holds the cache marker. A later request moves the marker, so it encodes that element again.
    marked: ?usize = null,

    const Block = struct {
        hash: u64,
        /// The offset of the element that starts at this block, or null inside an element.
        start: ?usize,
    };

    /// Free the buffers that `gpa` owns.
    pub fn deinit(self: *History, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.blocks.deinit(gpa);
        self.* = undefined;
    }

    // Keep the elements before the first one that can change, and return the block to encode from. `marker` is the block of the new cache marker.
    // The hashes of the equal blocks stay, so the caller hashes only the blocks after them.
    // Each start is set before its element, so a failed encoding leaves a prefix that the next call cuts back to its last start.
    fn keep(self: *History, key: u64, blocks: []const ir.Block, marker: ?usize) usize {
        const kept = self.blocks.slice();
        const hashes = kept.items(.hash);
        const starts = kept.items(.start);
        defer self.key = key; // The buffer holds elements of this key from here on, also after a failure.
        if (self.key != key or hashes.len == 0) return self.clear();
        var same: usize = 0;
        while (same < @min(hashes.len, blocks.len) and hashes[same] == hashBlock(blocks[same])) same += 1;
        // Grouping can extend the last element, so it always encodes again.
        var last = hashes.len - 1;
        while (starts[last] == null) last -= 1;
        var floor = @min(same, last);
        // The element of the old marker loses it, and the element of the new marker gains it.
        if (self.marked) |block| floor = @min(floor, block);
        if (marker) |block| floor = @min(floor, block);
        while (starts[floor] == null) floor -= 1;
        self.items.items.len = starts[floor].?;
        self.blocks.shrinkRetainingCapacity(same);
        return floor;
    }

    fn clear(self: *History) usize {
        self.items.clearRetainingCapacity();
        self.blocks.clearRetainingCapacity();
        self.marked = null;
        return 0;
    }
};

/// Validate one request with scratch from `arena`, then serialize it as three parts: the head, the history elements, and the tail.
/// The head and the elements borrow `history`, which this call updates. The slice lives in `arena`. The wire tag selects the protocol.
/// It fails on a request that breaks the IR, on content the endpoint cannot carry, on a blob that `request.blobs` does not answer, and on `OutOfMemory`.
/// Only an element that this call encodes reads its blobs. A Debug build also encodes the whole request again to check the kept elements, so it reads every blob.
pub fn serialize(gpa: std.mem.Allocator, arena: std.mem.Allocator, request: ir.Request, blocks: []const ir.Block, history: *History) Error![]const []const u8 {
    try ir.validateRequest(arena, request, blocks);

    var key_hash: std.hash.Wyhash = .init(0);
    feed(&key_hash, .{ request.wire, request.system, request.tools });
    const key = key_hash.final();
    const marker = switch (request.wire) {
        .anthropic_messages => anthropic.cacheIndex(request, blocks),
        .openai_responses => openai_responses.cacheIndex(request, blocks),
        // Chat Completions writes no cache marker.
        .openai_chat => null,
    };
    const from = history.keep(key, blocks, marker);
    // A kept block has the hash of a block that an earlier call checked, so only the encoded blocks need the content checks.
    // A failure here records no hash, like a failed allocation below.
    try ir.validateBlocks(arena, blocks[from..]);
    const hashed = history.blocks.len;
    // One byte more than the largest `std.heap.SmpAllocator` class goes to the page allocator, so mremap grows the buffer with no copy.
    try history.items.ensureTotalCapacityPrecise(gpa, 32 * 1024 + 1);
    try history.blocks.resize(gpa, blocks.len);
    const kept = history.blocks.slice();
    const starts = kept.items(.start);
    for (blocks[hashed..], kept.items(.hash)[hashed..]) |block, *hash| hash.* = hashBlock(block);
    @memset(starts[from..], null);
    var items: std.Io.Writer.Allocating = .fromArrayList(gpa, &history.items);
    defer history.items = items.toArrayList();
    const w = &items.writer;
    const comma = w.end != 0;
    const written_items = switch (request.wire) {
        .anthropic_messages => anthropic.writeItems(w, request, blocks, from, comma, starts),
        .openai_chat => openai_chat.writeItems(w, request, blocks, from, comma, starts),
        .openai_responses => openai_responses.writeItems(w, request, blocks, from, comma, starts),
    };
    written_items catch |err| return mapWrite(err);
    // The next request truncates to a kept element, which drops this head too.
    const elements = w.end;
    const written_head = switch (request.wire) {
        .anthropic_messages => anthropic.writeHead(w, request),
        .openai_chat => openai_chat.writeHead(w, request, elements != 0),
        .openai_responses => openai_responses.writeHead(w, request),
    };
    written_head catch |err| return mapWrite(err);
    history.marked = marker;
    if (history.marked) |*first| while (starts[first.*] == null) {
        first.* -= 1;
    };

    const written = items.written();
    const parts = try arena.dupe([]const u8, &.{ written[elements..], written[0..elements], "]}" });
    if (builtin.mode == .Debug) {
        var whole: std.Io.Writer.Allocating = .init(arena);
        const full = switch (request.wire) {
            .anthropic_messages => anthropic.serialize(&whole.writer, request, blocks),
            .openai_chat => openai_chat.serialize(&whole.writer, request, blocks),
            .openai_responses => openai_responses.serialize(&whole.writer, request, blocks),
        };
        full catch |err| return mapWrite(err);
        std.debug.assert(std.mem.eql(u8, try std.mem.concat(arena, u8, parts), whole.written())); // A kept element must equal a new encoding.
    }
    return parts;
}

fn hashBlock(block: ir.Block) u64 {
    var hash: std.hash.Wyhash = .init(0);
    feed(&hash, block);
    return hash.final();
}

/// Feed a value to `hash` by its content. A byte slice goes in one call, where `std.hash.autoHashStrat` takes one call for each byte.
fn feed(hash: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.size != .slice) @compileError("feed: only slices, got " ++ @typeName(T));
            hash.update(std.mem.asBytes(&value.len));
            if (info.child == u8) hash.update(value) else for (value) |item| feed(hash, item);
        },
        .@"struct" => |info| inline for (info.fields) |field| feed(hash, @field(value, field.name)),
        .array => |info| if (info.child == u8) hash.update(&value) else for (value) |item| feed(hash, item),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                hash.update(std.mem.asBytes(&@intFromEnum(tag)));
                feed(hash, payload);
            },
        },
        .optional => if (value) |payload| {
            hash.update(&.{1});
            feed(hash, payload);
        } else hash.update(&.{0}),
        .@"enum" => hash.update(std.mem.asBytes(&@intFromEnum(value))),
        .bool => hash.update(&.{@intFromBool(value)}),
        .int => hash.update(std.mem.asBytes(&value)),
        .void => {},
        else => @compileError("feed: unsupported type " ++ @typeName(T)),
    }
}

/// The errors of `serialize`.
pub const Error = ir.ValidateError || ir.Unsupported || types.BlobReader.ReadError;

fn mapWrite(err: ir.SerializeError) Error {
    return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |e| e,
    };
}

const testing = std.testing;
const request_testing = @import("request/testing.zig");

fn text(role: ir.Role, value: []const u8) ir.Block {
    return .{ .role = role, .value = .{ .text = value } };
}

fn image(comptime data: []const u8) ir.Block {
    return .{ .role = .user, .value = .{ .media = .{ .source = .{ .blob = request_testing.blob(data) }, .mime = "image/png" } } };
}

// The Debug assertion in `serialize` checks that the history stays consistent after each failed call.
test "a block that fails its checks fails each call, and the fixed request resumes" {
    const invalid = [_]u8{0xff};
    const calls = [_]struct { blocks: []const ir.Block, valid: bool }{
        .{ .blocks = &.{text(.user, &invalid)}, .valid = false },
        .{ .blocks = &.{text(.user, &invalid)}, .valid = false },
        .{ .blocks = &.{ text(.user, "a"), text(.assistant, "b"), text(.user, "c") }, .valid = true },
        .{ .blocks = &.{ text(.user, "a"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, &invalid) }, .valid = false },
        .{ .blocks = &.{ text(.user, "a"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, &invalid) }, .valid = false },
        .{ .blocks = &.{ text(.user, "a"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, "e") }, .valid = true },
    };
    for ([_]ir.Wire{ .{ .anthropic_messages = .{ .cache = true } }, .{ .openai_chat = .{} }, .{ .openai_responses = .{ .cache = true } } }) |wire| {
        var history: History = .{};
        defer history.deinit(testing.allocator);
        for (calls) |call| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const parts = serialize(testing.allocator, arena.allocator(), .{ .model = "m", .wire = wire, .max_output_tokens = 8 }, call.blocks, &history);
            if (call.valid) _ = try parts else try testing.expectError(error.InvalidRequest, parts);
        }
    }
}

// `serialize` encodes the whole request again in a Debug build, so this test calls the protocol writers.
test "a protocol writer reads the blobs of the elements it writes and no others" {
    const Counter = struct {
        reads: usize = 0,

        fn read(ctx: *const anyopaque, digest: [32]u8) types.BlobReader.ReadError![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            self.reads += 1;
            return request_testing.blobs.readFn(request_testing.blobs.ctx, digest);
        }
    };
    const blocks = [_]ir.Block{ image("ab"), text(.assistant, "b"), text(.user, "c") };
    inline for (.{ anthropic, openai_chat, openai_responses }, [_]ir.Wire{ .{ .anthropic_messages = .{} }, .{ .openai_chat = .{} }, .{ .openai_responses = .{} } }) |protocol, wire| {
        var counter: Counter = .{};
        const request: ir.Request = .{ .model = "m", .wire = wire, .max_output_tokens = 8, .blobs = .{ .ctx = &counter, .readFn = Counter.read } };
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try protocol.writeItems(&out.writer, request, &blocks, 1, false, null);
        try testing.expectEqual(@as(usize, 0), counter.reads);
        try protocol.writeItems(&out.writer, request, &blocks, 0, false, null);
        try testing.expectEqual(@as(usize, 1), counter.reads);
    }
}

// `serialize` checks each resumed body against a fresh encoding in a Debug build, so each call below is the assertion.
test "a resumed history equals a fresh encoding after an append, an edit, a marker that moves back, and a new blob" {
    const rounds = [_][]const ir.Block{
        &.{text(.user, "a")},
        &.{ text(.user, "a"), text(.assistant, "b"), text(.user, "c") },
        &.{ text(.user, "a"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, "e") },
        &.{ text(.user, "x"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, "e") },
        // The last user text goes, so the marker moves back to an element that a resume would keep.
        &.{ text(.user, "x"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d") },
        &.{ image("ab"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, "e") },
        // Only the digest changes, so the element must encode again.
        &.{ image("cd"), text(.assistant, "b"), text(.user, "c"), text(.assistant, "d"), text(.user, "e") },
    };
    for ([_]ir.Wire{ .{ .anthropic_messages = .{ .cache = true } }, .{ .openai_chat = .{} }, .{ .openai_responses = .{ .cache = true } } }) |wire| {
        var history: History = .{};
        defer history.deinit(testing.allocator);
        for (rounds) |blocks| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            _ = try serialize(testing.allocator, arena.allocator(), .{ .model = "m", .wire = wire, .system = "s", .max_output_tokens = 8, .blobs = request_testing.blobs }, blocks, &history);
        }
    }
}
