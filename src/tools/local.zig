//! Run the built-in file-system primitives natively over `std.Io`. There is no path confinement (a
//! trusted local user); the container backend is the boundary. See docs/plan.md "Execution isolation".

const std = @import("std");
const t = @import("tool.zig");
const paths = @import("../paths/paths.zig");

const Map = std.process.Environ.Map;

pub const LocalHost = struct {
    io: std.Io,
    root: []const u8, // The canonical workspace root, the base for a relative path.
    env: ?*const Map, // The environment expands an initial `~`.

    pub fn host(self: *LocalHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: t.ToolHost.VTable = .{ .readRange = readRange };

    fn readRange(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, range: t.Range, limits: t.ReadLimits) t.HostError!t.RangeRead {
        const self: *LocalHost = @ptrCast(@alignCast(ctx));
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        var file = std.Io.Dir.cwd().openFile(self.io, full, .{}) catch |err| return mapError(err);
        defer file.close(self.io);
        // One buffered line at a time. The scan never holds the whole file, whatever its size.
        const buffer = scratch.alloc(u8, limits.max_line_bytes) catch return error.OutOfMemory;
        // One byte more than the limit. A line AT the limit then finds its delimiter and stays whole.
        const line_buf = scratch.alloc(u8, limits.max_line_bytes + 1) catch return error.OutOfMemory;
        var reader = file.reader(self.io, buffer);
        return scan(scratch, &reader.interface, line_buf, range, limits) catch |err| switch (err) {
            error.InvalidUtf8, error.OutOfMemory => |e| e,
            // The open call accepts a directory on POSIX. The first read reports this case.
            error.ReadFailed => if (reader.err) |e| mapError(e) else error.HostFailure,
        };
    }

    /// Expand an initial `~` and resolve a relative path against the workspace root. An absolute path or a
    /// `..` escape is allowed (no confinement). The caller owns the result.
    fn resolve(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        const expanded = if (self.env) |e| try paths.expandHome(scratch, e, path) else path;
        if (std.fs.path.isAbsolute(expanded)) return std.fs.path.resolve(scratch, &.{expanded});
        return std.fs.path.resolve(scratch, &.{ self.root, expanded });
    }
};

const ScanError = error{ InvalidUtf8, OutOfMemory, ReadFailed };

/// The next byte after a streamed line.
const NextByte = enum { newline, other, eof };

/// Stream the requested lines. Stop at the first limit. `line_buf` holds one line, so memory stays
/// bounded by the limits and not by the file size.
fn scan(scratch: std.mem.Allocator, reader: *std.Io.Reader, line_buf: []u8, range: t.Range, limits: t.ReadLimits) ScanError!t.RangeRead {
    std.debug.assert(limits.max_lines > 0 and limits.max_line_bytes > 0);
    std.debug.assert(line_buf.len == limits.max_line_bytes + 1);
    // A first line must always fit. Otherwise a capped read makes no progress and the model repeats it.
    std.debug.assert(limits.max_line_bytes < limits.max_bytes);

    var line_no: u64 = 1;
    const first: u64 = range.start orelse 1;
    while (line_no < first) : (line_no += 1) {
        _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return .{ .text = "" }, // the file ends before `start`
            error.ReadFailed => return error.ReadFailed,
        };
    }

    var text: std.ArrayList(u8) = .empty;
    var writer: std.Io.Writer = .fixed(line_buf);
    var long_lines: u32 = 0;
    var kept: u32 = 0;
    while (true) {
        if (range.end) |last| if (line_no > last) break;
        const line = (try takeLine(reader, &writer, limits.max_line_bytes, &long_lines)) orelse break;
        // The scan reads the line BEFORE it tests a limit, so a limit never reports a line that the
        // file does not hold.
        if (kept == limits.max_lines or text.items.len + line.len + 1 > limits.max_bytes) {
            return .{ .text = text.items, .next_line = std.math.cast(u32, line_no), .long_lines = long_lines };
        }
        // `line` borrows `line_buf`. Copy it before the next call reuses that buffer.
        try text.appendSlice(scratch, line);
        try text.append(scratch, '\n');
        std.debug.assert(text.items.len <= limits.max_bytes);
        kept += 1;
        line_no += 1;
    }
    return .{ .text = text.items, .long_lines = long_lines };
}

/// Take one line without its newline. The scan cuts a line above `max_bytes` and drops the rest of it.
/// Return null at the end of the file. The result borrows the writer buffer until the next call.
fn takeLine(reader: *std.Io.Reader, writer: *std.Io.Writer, max_bytes: u32, long_lines: *u32) ScanError!?[]const u8 {
    writer.end = 0;
    var cut = false;
    var ended = false;
    if (reader.streamDelimiterLimit(writer, '\n', .limited(max_bytes + 1))) |_| {
        // The delimiter stays in the reader. Its absence means the file ends on this line.
        switch (try peekNext(reader)) {
            .newline => _ = reader.takeByte() catch return error.ReadFailed,
            .eof => ended = true,
            .other => unreachable, // the stream stopped at the delimiter or at the file end
        }
    } else |err| switch (err) {
        error.WriteFailed => unreachable, // the limit equals the buffer length
        error.ReadFailed => return error.ReadFailed,
        // The limit allows one byte more than `max_bytes`, so this line is longer than the limit.
        error.StreamTooLong => {
            _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => {}, // the file ends inside this line
                error.ReadFailed => return error.ReadFailed,
            };
            long_lines.* += 1;
            cut = true;
        },
    }
    if (ended and writer.end == 0) return null; // the file holds no more lines
    const raw = writer.buffered();
    // Only a cut line can end inside a codepoint. Validate a whole line as it stands.
    if (!cut) return if (std.unicode.utf8ValidateSlice(raw)) raw else error.InvalidUtf8;
    const clipped = raw[0..@min(raw.len, max_bytes)];
    return clipped[0 .. utf8Floor(clipped) orelse return error.InvalidUtf8];
}

/// Report the next byte without consuming it.
fn peekNext(reader: *std.Io.Reader) ScanError!NextByte {
    const byte = reader.peekByte() catch |err| switch (err) {
        error.EndOfStream => return .eof,
        error.ReadFailed => return error.ReadFailed,
    };
    return if (byte == '\n') .newline else .other;
}

/// Return the length of the longest prefix that ends on a UTF-8 codepoint boundary. Return null when
/// the trailing bytes are not the start of a valid sequence, because that data is invalid, not cut.
fn utf8Floor(bytes: []const u8) ?usize {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes.len;
    var i = bytes.len;
    var back: usize = 0;
    // A codepoint uses at most 4 bytes. At most 3 continuation bytes can follow its start byte.
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        if (bytes[i] & 0xC0 == 0x80) continue;
        const need = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return null;
        if (bytes.len - i >= need) return null; // the sequence is complete, so the data is invalid
        return if (std.unicode.utf8ValidateSlice(bytes[0..i])) i else null;
    }
    return null;
}

const ExpandError = @typeInfo(@typeInfo(@TypeOf(paths.expandHome)).@"fn".return_type.?).error_union.error_set;

/// Every native error the local backend can raise. `mapError` covers this set, not `anyerror`.
const FsError = ExpandError || std.mem.Allocator.Error || std.Io.File.OpenError;
const NativeError = FsError || std.Io.File.Reader.Error;

/// Map a native file-system error to `HostError`. Map an unlisted error to `HostFailure`. The open
/// call accepts a directory on POSIX. The first read reports that case.
fn mapError(err: NativeError) t.HostError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.IsDir => error.NotAFile,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.HostFailure,
    };
}

const testing = std.testing;

const test_limits: t.ReadLimits = .{ .max_lines = 2000, .max_line_bytes = 64, .max_bytes = 4096 };

/// The fixture writes `data` to a temporary file. It reads a range through `LocalHost`.
const Fixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init(self: *Fixture, data: []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = data });
        self.root_len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
    /// Build the host per call. A stored root slice would dangle if the fixture moved.
    fn read(self: *Fixture, a: std.mem.Allocator, range: t.Range, limits: t.ReadLimits) t.HostError!t.RangeRead {
        var local: LocalHost = .{ .io = testing.io, .root = self.root_buf[0..self.root_len], .env = null };
        return local.host().readRange(a, "a.txt", range, limits);
    }
};

test "LocalHost reads a whole file and a line range" {
    var f: Fixture = undefined;
    try f.init("one\ntwo\nthree\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const all = try f.read(a, .{}, test_limits);
    try testing.expectEqualStrings("one\ntwo\nthree\n", all.text);
    try testing.expectEqual(@as(?u32, null), all.next_line);

    const some = try f.read(a, .{ .start = 2, .end = 3 }, test_limits);
    try testing.expectEqualStrings("two\nthree\n", some.text);
}

test "LocalHost returns the final unterminated line" {
    var f: Fixture = undefined;
    try f.init("x\ny");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const last = try f.read(arena.allocator(), .{ .start = 2, .end = 2 }, test_limits);
    try testing.expectEqualStrings("y\n", last.text); // the scan adds the newline the file lacks
}

test "LocalHost returns an empty result for a start past the file end" {
    var f: Fixture = undefined;
    try f.init("x\ny");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const past = try f.read(arena.allocator(), .{ .start = 10 }, test_limits);
    try testing.expectEqualStrings("", past.text);
    try testing.expectEqual(@as(?u32, null), past.next_line);
}

test "LocalHost reports the next line after the line limit" {
    var f: Fixture = undefined;
    try f.init("1\n2\n3\n4\n5\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var narrow = test_limits;
    narrow.max_lines = 2;
    const got = try f.read(arena.allocator(), .{}, narrow);
    try testing.expectEqualStrings("1\n2\n", got.text);
    try testing.expectEqual(@as(?u32, 3), got.next_line);
}

test "LocalHost reports no next line when the limit lands on the file end" {
    var f: Fixture = undefined;
    try f.init("1\n2\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var narrow = test_limits;
    narrow.max_lines = 2; // the file holds exactly the limit, so no line remains
    const got = try f.read(arena.allocator(), .{}, narrow);
    try testing.expectEqualStrings("1\n2\n", got.text);
    try testing.expectEqual(@as(?u32, null), got.next_line);
}

test "LocalHost stops at the byte limit with complete lines" {
    var f: Fixture = undefined;
    try f.init("aaaa\nbbbb\ncccc\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var narrow = test_limits;
    narrow.max_line_bytes = 8; // a line must always fit inside the byte limit
    narrow.max_bytes = 12; // two five-byte lines fit. The third line does not fit.
    const got = try f.read(arena.allocator(), .{}, narrow);
    try testing.expectEqualStrings("aaaa\nbbbb\n", got.text);
    try testing.expectEqual(@as(?u32, 3), got.next_line);
}

test "LocalHost keeps a line of exactly the line limit whole" {
    var f: Fixture = undefined;
    var exact: [64]u8 = @splat('z');
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &exact);
    try data.appendSlice(testing.allocator, "\ntail\n");
    try f.init(data.items);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = try f.read(arena.allocator(), .{}, test_limits);
    try testing.expectEqual(@as(u32, 0), got.long_lines); // the scan did not cut it
    try testing.expectEqualStrings(data.items, got.text);
}

test "LocalHost cuts a long line on a codepoint boundary" {
    var f: Fixture = undefined;
    // The data uses 40 three-byte codepoints. The 64-byte limit falls inside a codepoint.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(testing.allocator);
    for (0..40) |_| try data.appendSlice(testing.allocator, "\u{20ac}");
    try data.appendSlice(testing.allocator, "\ntail\n");
    try f.init(data.items);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = try f.read(arena.allocator(), .{}, test_limits);
    try testing.expectEqual(@as(u32, 1), got.long_lines);
    var it = std.mem.splitScalar(u8, got.text[0 .. got.text.len - 1], '\n');
    const first = it.next().?;
    // The limit leaves 63 bytes. It does not split a codepoint.
    try testing.expectEqual(@as(usize, 63), first.len);
    try testing.expect(std.unicode.utf8ValidateSlice(first));
    try testing.expectEqualStrings("tail", it.next().?);
}

test "LocalHost refuses a file it cannot decode as UTF-8" {
    var f: Fixture = undefined;
    try f.init("ok\n\xff\xfe\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidUtf8, f.read(arena.allocator(), .{}, test_limits));
}

test "LocalHost refuses an invalid byte at a cut boundary" {
    var f: Fixture = undefined;
    // Byte 0xff is not the start of a sequence, so a cut there must not make the prefix valid.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(testing.allocator);
    for (0..63) |_| try data.append(testing.allocator, 'z');
    try data.append(testing.allocator, 0xff);
    for (0..10) |_| try data.append(testing.allocator, 'z');
    try data.append(testing.allocator, '\n');
    try f.init(data.items);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidUtf8, f.read(arena.allocator(), .{}, test_limits));
}

test "LocalHost maps a missing path and a directory" {
    var f: Fixture = undefined;
    try f.init("x\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };
    const h = local.host();
    try testing.expectError(error.NotFound, h.readRange(a, "nope.txt", .{}, test_limits));
    try testing.expectError(error.NotAFile, h.readRange(a, ".", .{}, test_limits));
}

test "LocalHost expands a leading tilde against HOME" {
    var f: Fixture = undefined;
    try f.init("hi\n");
    defer f.deinit();

    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", f.root_buf[0..f.root_len]);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var local: LocalHost = .{ .io = testing.io, .root = "/unused", .env = &env };
    const got = try local.host().readRange(arena.allocator(), "~/a.txt", .{}, test_limits);
    try testing.expectEqualStrings("hi\n", got.text);
}

test "LocalHost does not confine reads to the workspace" {
    var f: Fixture = undefined;
    try f.init("inside\n");
    defer f.deinit();
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    try other.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "secret\n" });
    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_root = other_buf[0..try other.dir.realPath(testing.io, &other_buf)];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outside = try std.fs.path.join(a, &.{ other_root, "outside.txt" });
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };
    // An absolute path outside the workspace reads freely (no confinement).
    const got = try local.host().readRange(a, outside, .{}, test_limits);
    try testing.expectEqualStrings("secret\n", got.text);
}
