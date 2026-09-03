//! Run the built-in file-system primitives natively over `std.Io`. Every tool runs here.
//! There is no path confinement. The local user is trusted, so a tool reaches the whole file system.

const std = @import("std");
const h = @import("operations.zig");
const paths = @import("../../paths.zig");
const process = @import("process.zig");

const Map = std.process.Environ.Map;

pub const LocalHost = struct {
    io: std.Io,
    root: []const u8, // The canonical workspace root, the base for a relative path.
    env: ?*const Map, // The environment expands an initial `~`.

    pub fn readRange(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, range: h.Range, limits: h.ReadLimits) h.HostError!h.RangeRead {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        try requireRegularFile(self.io, full);
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

    pub fn readAll(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, max_bytes: u32) h.HostError![]const u8 {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        try requireRegularFile(self.io, full);
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, full, scratch, .limited(max_bytes)) catch |err| return mapError(err);
        // A caller may write the returned bytes. The local host validates every byte.
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return text;
    }

    pub fn writeFile(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, content: []const u8) h.HostError!void {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        // The root has no parent and names a directory, so it can never accept a write.
        const parent = std.fs.path.dirname(full) orelse return error.NotAFile;
        const base = std.fs.path.basename(full);
        if (base.len == 0) return error.NotAFile;

        var dir = std.Io.Dir.cwd().openDir(self.io, parent, .{}) catch |err| return mapError(err);
        defer dir.close(self.io);
        const permissions = try targetPermissions(dir, self.io, base);

        // `File.Atomic` writes a temporary file beside the target, then renames it over the target.
        // Its `deinit` removes that temporary file after a failure.
        var atomic = dir.createFileAtomic(self.io, base, .{ .permissions = permissions, .replace = true }) catch |err| return mapError(err);
        defer atomic.deinit(self.io);
        // `openat` applies the process umask, so restore the permissions on the temporary file itself.
        atomic.file.setPermissions(self.io, permissions) catch |err| return mapError(err);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        writer.interface.writeAll(content) catch return mapError(writer.err orelse error.Unexpected);
        writer.interface.flush() catch return mapError(writer.err orelse error.Unexpected);
        atomic.replace(self.io) catch |err| return mapError(err);
    }

    /// Return the permissions for a replacement. Use the default permissions for a missing target.
    /// Reject a symlink, a hard link, or a special file.
    fn targetPermissions(dir: std.Io.Dir, io: std.Io, base: []const u8) h.HostError!std.Io.File.Permissions {
        const info = dir.statFile(io, base, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .default_file,
            else => return mapError(err),
        };
        if (info.kind != .file) return error.NotAFile;
        if (info.nlink > 1) return error.NotAFile; // A rename removes this name. The other links remain.
        return info.permissions;
    }

    pub fn exec(self: *LocalHost, scratch: std.mem.Allocator, spec: h.ExecSpec) h.HostError!h.ExecResult {
        return process.run(self.io, self.root, self.env, scratch, spec);
    }

    pub fn stat(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) h.HostError!h.Stat {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        const info = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch |err| return mapError(err);
        return .{ .is_dir = info.kind == .directory, .last_modified_ms = millisOf(info.mtime) };
    }

    pub fn listDir(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, options: h.ListOptions) h.HostError!h.DirPage {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        var dir = std.Io.Dir.cwd().openDir(self.io, full, .{ .iterate = true }) catch |err| return mapError(err);
        defer dir.close(self.io);
        var page = try selectPage(self.io, dir, scratch, options);
        // Check for a repository only in the directories that this page keeps.
        for (page.items.items) |*item| if (item.is_dir) {
            item.is_git_repo = isGitRepo(self.io, dir, item.name);
        };
        return page.result();
    }

    /// Anchor a tool path at the workspace root. `paths.anchorAt` holds the rules for every tool.
    fn resolve(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        return paths.anchorAt(scratch, self.env, self.root, path);
    }
};

const ScanError = error{ InvalidUtf8, OutOfMemory, ReadFailed };

/// The next byte after a streamed line.
const NextByte = enum { newline, other, eof };

/// Stream the requested lines. Stop at the first limit. `line_buf` holds one line, so memory stays
/// bounded by the limits and not by the file size.
fn scan(scratch: std.mem.Allocator, reader: *std.Io.Reader, line_buf: []u8, range: h.Range, limits: h.ReadLimits) ScanError!h.RangeRead {
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

/// Every native error the local host can raise. `mapError` covers this set, not `anyerror`.
const FsError = ExpandError || std.mem.Allocator.Error || std.Io.File.OpenError;
const NativeError = FsError || std.Io.Dir.ReadFileAllocError || std.Io.Dir.StatFileError ||
    std.Io.Dir.OpenError || std.Io.Dir.CreateFileAtomicError || std.Io.File.Writer.Error ||
    std.Io.File.SetPermissionsError || std.Io.Dir.RenameError;

/// Map a native file-system error to `HostError`. Map an unlisted error to `HostFailure`. The open
/// call accepts a directory on POSIX. The first read reports that case.
fn mapError(err: NativeError) h.HostError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.IsDir => error.NotAFile,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        // `readFileAlloc` reports the byte limit this way. The caller must see the size, not a fault.
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.HostFailure,
    };
}

/// Reject a path that does not name a regular file. A read of a FIFO or a device blocks forever, so
/// every read must check first. A read follows a symlink; a write must not.
fn requireRegularFile(io: std.Io, path: []const u8) h.HostError!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return mapError(err);
    if (stat.kind != .file) return error.NotAFile;
}

/// Convert a filesystem timestamp to epoch milliseconds. A time before the epoch reads as zero.
fn millisOf(ts: std.Io.Timestamp) u64 {
    const ms = @divFloor(ts.nanoseconds, std.time.ns_per_ms);
    return if (ms <= 0) 0 else @intCast(ms);
}

/// Report whether `name` inside `dir` contains a `.git` entry.
fn isGitRepo(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    var sub = dir.openDir(io, name, .{}) catch return false;
    defer sub.close(io);
    _ = sub.statFile(io, ".git", .{}) catch return false;
    return true;
}

/// Report whether one entry is a directory. A link or an unknown kind needs one more call.
fn entryIsDir(io: std.Io, dir: std.Io.Dir, entry: std.Io.Dir.Entry) bool {
    return switch (entry.kind) {
        .directory => true,
        .sym_link, .unknown => blk: {
            const info = dir.statFile(io, entry.name, .{}) catch break :blk false;
            break :blk info.kind == .directory;
        },
        else => false,
    };
}

/// Hold the smallest `limit` names of one directory. A page owns its slots, so memory stays bounded.
const PageBuilder = struct {
    items: std.ArrayList(h.DirItem),
    slots: [][std.Io.Dir.max_name_bytes]u8,
    used: usize = 0,
    limit: u32,
    dropped: bool = false,

    fn init(scratch: std.mem.Allocator, limit: u32) std.mem.Allocator.Error!PageBuilder {
        std.debug.assert(limit > 0);
        return .{
            .items = try .initCapacity(scratch, limit),
            .slots = try scratch.alloc([std.Io.Dir.max_name_bytes]u8, limit),
            .limit = limit,
        };
    }

    /// Copy `name` into a free slot. An eviction returns its slot, so `used` never passes `limit`.
    fn store(self: *PageBuilder, name: []const u8, evicted: ?[]const u8) []const u8 {
        const slot: usize = if (evicted) |old_name| self.slotOf(old_name) else blk: {
            defer self.used += 1;
            break :blk self.used;
        };
        std.debug.assert(slot < self.slots.len);
        @memcpy(self.slots[slot][0..name.len], name);
        return self.slots[slot][0..name.len];
    }

    fn slotOf(self: *const PageBuilder, name: []const u8) usize {
        const offset = @intFromPtr(name.ptr) - @intFromPtr(self.slots.ptr);
        return offset / std.Io.Dir.max_name_bytes;
    }

    /// Keep `item` when it sorts inside the page. A name too long for one slot never fits a page.
    fn offer(self: *PageBuilder, item: h.DirItem) void {
        std.debug.assert(self.items.items.len <= self.limit);
        if (item.name.len > std.Io.Dir.max_name_bytes) return;
        var at: usize = 0;
        while (at < self.items.items.len and std.mem.lessThan(u8, self.items.items[at].name, item.name)) at += 1;
        if (at == self.limit) {
            self.dropped = true;
            return;
        }
        const full = self.items.items.len == self.limit;
        const evicted = if (full) self.items.pop().?.name else null;
        self.dropped = self.dropped or full;
        var copy = item;
        copy.name = self.store(item.name, evicted);
        self.items.insertAssumeCapacity(at, copy);
        std.debug.assert(self.items.items.len <= self.limit);
    }

    fn result(self: *const PageBuilder) h.DirPage {
        std.debug.assert(self.items.items.len <= self.limit);
        if (self.dropped) std.debug.assert(self.items.items.len == self.limit);
        const last = if (self.dropped) self.items.items[self.items.items.len - 1].name else null;
        return .{ .items = self.items.items, .next_after = last };
    }
};

/// Scan the whole directory and keep the first page of names after `options.after`.
fn selectPage(io: std.Io, dir: std.Io.Dir, scratch: std.mem.Allocator, options: h.ListOptions) h.HostError!PageBuilder {
    var builder = try PageBuilder.init(scratch, options.limit);
    var it = dir.iterate();
    while (it.next(io) catch |err| return mapError(err)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        // A wire name is a JSON string, so a name that is not UTF-8 has no valid encoding.
        if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
        if (options.after) |after| if (!std.mem.lessThan(u8, after, entry.name)) continue;
        const is_dir = entryIsDir(io, dir, entry);
        if (!is_dir and !options.include_files) continue;
        builder.offer(.{ .name = entry.name, .is_dir = is_dir });
    }
    return builder;
}

const testing = std.testing;

const test_limits: h.ReadLimits = .{ .max_lines = 2000, .max_line_bytes = 64, .max_bytes = 4096 };

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
    fn read(self: *Fixture, a: std.mem.Allocator, range: h.Range, limits: h.ReadLimits) h.HostError!h.RangeRead {
        var local: LocalHost = .{ .io = testing.io, .root = self.root_buf[0..self.root_len], .env = null };
        return local.readRange(a, "a.txt", range, limits);
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
    try testing.expectError(error.NotFound, local.readRange(a, "nope.txt", .{}, test_limits));
    try testing.expectError(error.NotAFile, local.readRange(a, ".", .{}, test_limits));
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
    const got = try local.readRange(arena.allocator(), "~/a.txt", .{}, test_limits);
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
    const got = try local.readRange(a, outside, .{}, test_limits);
    try testing.expectEqualStrings("secret\n", got.text);
}

test "LocalHost readAll returns exact bytes and reports the size limit" {
    var f: Fixture = undefined;
    try f.init("one\ntwo");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };

    // The bytes must be exact. `readRange` cuts long lines, so a write-back needs this path.
    try testing.expectEqualStrings("one\ntwo", try local.readAll(a, "a.txt", 1024));
    // `readFileAlloc` reports the limit as StreamTooLong. The caller must see the size.
    try testing.expectError(error.TooLarge, local.readAll(a, "a.txt", 3));
    try testing.expectError(error.NotFound, local.readAll(a, "nope.txt", 1024));
    try testing.expectError(error.NotAFile, local.readAll(a, ".", 1024));
}

test "LocalHost readAll refuses a file it cannot decode as UTF-8" {
    var f: Fixture = undefined;
    try f.init("\xff\xfe\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };
    try testing.expectError(error.InvalidUtf8, local.readAll(arena.allocator(), "a.txt", 1024));
}

test "LocalHost writeFile replaces a file and keeps its permissions" {
    var f: Fixture = undefined;
    try f.init("old\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mark the file executable. A replacement must keep that bit through the umask.
    var handle = try f.tmp.dir.openFile(testing.io, "a.txt", .{ .mode = .read_write });
    try handle.setPermissions(testing.io, .executable_file);
    handle.close(testing.io);

    const before = (try f.tmp.dir.statFile(testing.io, "a.txt", .{})).permissions;

    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };
    try local.writeFile(a, "a.txt", "new content\n");
    try testing.expectEqualStrings("new content\n", try local.readAll(a, "a.txt", 1024));

    // The replacement keeps the old permissions. `openat` applies the umask, so the write restores them.
    const after = (try f.tmp.dir.statFile(testing.io, "a.txt", .{})).permissions;
    try testing.expectEqual(before, after);
}

test "LocalHost writeFile creates a file that does not exist" {
    var f: Fixture = undefined;
    try f.init("unused\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };
    try local.writeFile(a, "fresh.txt", "hello\n");
    try testing.expectEqualStrings("hello\n", try local.readAll(a, "fresh.txt", 1024));
}

test "LocalHost writeFile refuses a target that is not a regular file" {
    var f: Fixture = undefined;
    try f.init("target\n");
    defer f.deinit();
    try f.tmp.dir.symLink(testing.io, "a.txt", "link.txt", .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };
    // A rename replaces the link itself, so a write through a symlink would change the wrong object.
    try testing.expectError(error.NotAFile, local.writeFile(a, "link.txt", "x"));
    try testing.expectError(error.NotAFile, local.writeFile(a, ".", "x"));
    try testing.expectError(error.NotAFile, local.writeFile(a, "/", "x"));
    // The target keeps its content.
    try testing.expectEqualStrings("target\n", try local.readAll(a, "a.txt", 1024));
}

/// Build a directory tree for the directory-page tests. The fixture holds the root path.
const TreeFixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init(self: *TreeFixture, dirs: []const []const u8, files: []const []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        for (dirs) |name| try self.tmp.dir.createDir(testing.io, name, .default_dir);
        for (files) |name| try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x" });
        self.root_len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
    }
    fn deinit(self: *TreeFixture) void {
        self.tmp.cleanup();
    }
    fn list(self: *TreeFixture, a: std.mem.Allocator, options: h.ListOptions) h.HostError!h.DirPage {
        var local: LocalHost = .{ .io = testing.io, .root = self.root_buf[0..self.root_len], .env = null };
        return local.listDir(a, ".", options);
    }
};

test "listDir sorts by name and drops files by default" {
    var f: TreeFixture = undefined;
    try f.init(&.{ "beta", "alpha" }, &.{"note.txt"});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const page = try f.list(a, .{ .limit = 10 });
    try testing.expectEqual(@as(usize, 2), page.items.len);
    try testing.expectEqualStrings("alpha", page.items[0].name);
    try testing.expectEqualStrings("beta", page.items[1].name);
    try testing.expect(page.items[0].is_dir and !page.items[0].is_git_repo);
    try testing.expect(page.next_after == null); // The page holds the whole directory.

    const with_files = try f.list(a, .{ .limit = 10, .include_files = true });
    try testing.expectEqual(@as(usize, 3), with_files.items.len);
    try testing.expectEqualStrings("note.txt", with_files.items[2].name);
    try testing.expect(!with_files.items[2].is_dir);
}

test "listDir pages after a name and reports the end" {
    var f: TreeFixture = undefined;
    try f.init(&.{ "a", "b", "c", "d" }, &.{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try f.list(a, .{ .limit = 2 });
    try testing.expectEqual(@as(usize, 2), first.items.len);
    try testing.expectEqualStrings("a", first.items[0].name);
    try testing.expectEqualStrings("b", first.items[1].name);
    try testing.expectEqualStrings("b", first.next_after.?);

    const second = try f.list(a, .{ .limit = 2, .after = first.next_after });
    try testing.expectEqualStrings("c", second.items[0].name);
    try testing.expectEqualStrings("d", second.items[1].name);
    // The scan found no name after "d", so this page is final.
    try testing.expect(second.next_after == null);
}

test "listDir marks a directory that holds .git" {
    var f: TreeFixture = undefined;
    try f.init(&.{ "repo", "plain" }, &.{});
    defer f.deinit();
    try f.tmp.dir.createDir(testing.io, "repo/.git", .default_dir);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const page = try f.list(arena.allocator(), .{ .limit = 10 });
    try testing.expectEqualStrings("plain", page.items[0].name);
    try testing.expect(!page.items[0].is_git_repo);
    try testing.expectEqualStrings("repo", page.items[1].name);
    try testing.expect(page.items[1].is_git_repo);
}

test "stat reports a directory, a file, and a missing path" {
    var f: TreeFixture = undefined;
    try f.init(&.{"sub"}, &.{"a.txt"});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = null };

    const dir = try local.stat(a, "sub");
    try testing.expect(dir.is_dir);
    const file = try local.stat(a, "a.txt");
    try testing.expect(!file.is_dir);
    try testing.expect(file.last_modified_ms > 0);
    try testing.expectError(error.NotFound, local.stat(a, "gone"));
}
