//! Run the built-in file-system primitives natively over `std.Io`; every tool runs here, and there is no path confinement because the local user is trusted, so a tool reaches the whole file system.

const std = @import("std");
const h = @import("operations.zig");
const paths = @import("../../paths.zig");
const blob = @import("../../store/blob.zig");
const utf8 = @import("../../utf8.zig");

const Map = std.process.Environ.Map;

pub const LocalHost = struct {
    io: std.Io,
    root: []const u8, // The canonical workspace root, the base for a relative path.
    env: *const Map, // The environment expands an initial `~`.

    pub fn readRange(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, range: h.Range, limits: h.ReadLimits) h.HostError!h.FileRead {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        const file_size = (try requireRegularFile(self.io, full)).size;
        var file = std.Io.Dir.cwd().openFile(self.io, full, .{}) catch |err| return mapError(err);
        defer file.close(self.io);
        // One buffered line at a time. The scan never holds the whole file, whatever its size.
        const buffer = scratch.alloc(u8, @max(blob.sniff_bytes, limits.max_line_bytes)) catch unreachable;
        var reader = file.reader(self.io, buffer);
        const head = reader.interface.peek(blob.sniff_bytes) catch |err| switch (err) {
            error.EndOfStream => reader.interface.buffered(),
            error.ReadFailed => return if (reader.err) |e| mapError(e) else error.HostFailure,
        };
        if (blob.sniff(head) != null) return .{ .image = full };
        // One byte more than the limit lets a line at the limit find its delimiter.
        const line_buf = scratch.alloc(u8, limits.max_line_bytes + 1) catch unreachable;
        return .{
            .text = scan(scratch, &reader.interface, line_buf, file_size, range, limits) catch |err| switch (err) {
                error.InvalidUtf8 => return error.InvalidUtf8,
                // The open call accepts a directory on POSIX. The first read reports this case.
                error.ReadFailed => return if (reader.err) |e| mapError(e) else error.HostFailure,
            },
        };
    }

    /// Read at most `max_bytes` from `offset` as text, cut at a character boundary. A growing log reads again from `next`.
    pub fn readFrom(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, offset: ?u64, max_bytes: u32, complete: bool) h.HostError!h.BytesRead {
        std.debug.assert(max_bytes > 0);
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        _ = try requireRegularFile(self.io, full);
        var file = std.Io.Dir.cwd().openFile(self.io, full, .{}) catch |err| return mapError(err);
        defer file.close(self.io);
        // The open file gives the size, so a path that changes after the stat cannot mislabel the read.
        const size = (file.stat(self.io) catch |err| return mapError(err)).size;
        if (max_bytes < 4) return error.HostFailure;
        const start = if (offset) |at| @min(at, size) else size -| max_bytes;
        const buffer = scratch.alloc(u8, @intCast(@min(max_bytes, size - start))) catch unreachable;
        const count = file.readPositionalAll(self.io, buffer, start) catch |err| return mapError(err);
        // A writer can stop in the middle of a character, so the cut part waits for the next read.
        const cut = if (complete and start + count == size) count else utf8.whole(buffer[0..count]);
        const bytes = buffer[0..cut];
        const text = if (std.unicode.utf8ValidateSlice(bytes)) bytes else utf8.sanitize(scratch, bytes) catch unreachable;
        return .{ .text = text, .next = start + cut, .size = size, .start = start, .complete = complete and start + cut == size };
    }

    pub fn readAllInto(self: *LocalHost, scratch: std.mem.Allocator, output: std.mem.Allocator, path: []const u8, max_bytes: u32) h.HostError![]u8 {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        _ = try requireRegularFile(self.io, full);
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, full, output, .limited(max_bytes)) catch |err| return mapError(err);
        // A caller may write the returned bytes. The local host validates every byte.
        if (!std.unicode.utf8ValidateSlice(text)) {
            output.free(text);
            return error.InvalidUtf8;
        }
        return text;
    }

    pub fn writeFile(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, content: []const u8) h.HostError!void {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        // The root has no parent and names a directory, so it can never accept a write.
        const parent = std.Io.Dir.path.dirname(full) orelse return error.NotAFile;
        const base = std.Io.Dir.path.basename(full);
        if (base.len == 0) return error.NotAFile;

        var dir = std.Io.Dir.cwd().openDir(self.io, parent, .{}) catch |err| return mapError(err);
        defer dir.close(self.io);
        const permissions = try targetPermissions(dir, self.io, base);

        // `File.Atomic` writes a temporary file beside the target and renames it over; its `deinit` removes the temporary file after a failure.
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

    /// Return the permissions for a replacement, the default for a missing target; reject a symlink, a hard link, or a special file.
    fn targetPermissions(dir: std.Io.Dir, io: std.Io, base: []const u8) h.HostError!std.Io.File.Permissions {
        const info = dir.statFile(io, base, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .default_file,
            else => return mapError(err),
        };
        if (info.kind != .file) return error.NotAFile;
        if (info.nlink > 1) return error.NotAFile; // A rename removes this name. The other links remain.
        return info.permissions;
    }

    /// Remove one regular file, and refuse a directory, a symbolic link, or a special file.
    pub fn removeFile(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) h.HostError!void {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        // The check does not follow a link, so a link to a file never removes the file it names.
        const info = std.Io.Dir.cwd().statFile(self.io, full, .{ .follow_symlinks = false }) catch |err| return mapError(err);
        if (info.kind != .file) return error.NotAFile;
        std.Io.Dir.cwd().deleteFile(self.io, full) catch |err| return mapError(err);
    }

    pub fn stat(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) h.HostError!h.Stat {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        const info = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch |err| return mapError(err);
        return .{ .path = full, .is_directory = info.kind == .directory, .last_modified_ms = millisOf(info.mtime) };
    }

    /// List the first `limit` subdirectories by name. A file never appears.
    pub fn listDir(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8, limit: u32) h.HostError!h.DirPage {
        const full = self.resolve(scratch, path) catch |err| return mapError(err);
        var dir = std.Io.Dir.cwd().openDir(self.io, full, .{ .iterate = true }) catch |err| return mapError(err);
        defer dir.close(self.io);
        var page = try selectPage(self.io, dir, scratch, limit);
        // Check for a repository only in the directories that this page keeps.
        for (page.items.items) |*item| item.is_git_repo = isGitRepo(self.io, dir, item.name);
        return page.result();
    }

    /// Anchor a tool path at the workspace root. `paths.anchorAt` holds the rules for every tool.
    fn resolve(self: *LocalHost, scratch: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        return paths.anchorAt(scratch, self.env, self.root, path);
    }
};

const ScanError = error{ InvalidUtf8, ReadFailed };

/// The next byte after a streamed line.
const NextByte = enum { newline, other, eof };

/// Stream the requested lines and stop at the first limit. `line_buf` holds one line, so memory follows the limits, not the file size.
fn scan(scratch: std.mem.Allocator, reader: *std.Io.Reader, line_buf: []u8, file_size: u64, range: h.Range, limits: h.ReadLimits) ScanError!h.RangeRead {
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

    // The text fits the smaller of the byte cap and the file, so one allocation holds it.
    var text: std.ArrayList(u8) = std.ArrayList(u8).initCapacity(scratch, @intCast(@min(limits.max_bytes, file_size))) catch unreachable;
    var writer: std.Io.Writer = .fixed(line_buf);
    var long_lines: u32 = 0;
    var kept: u32 = 0;
    while (true) {
        if (range.end) |last| if (line_no > last) break;
        const line = (try takeLine(reader, &writer, limits.max_line_bytes, &long_lines)) orelse break;
        // The scan reads the line before it tests a limit, so a limit never reports a line the file does not hold.
        if (kept == limits.max_lines or text.items.len + line.len + 1 > limits.max_bytes) {
            return .{ .text = text.items, .next_line = std.math.cast(u32, line_no), .long_lines = long_lines };
        }
        // `line` borrows `line_buf`. Copy it before the next call reuses that buffer.
        text.appendSlice(scratch, line) catch unreachable;
        text.append(scratch, '\n') catch unreachable;
        std.debug.assert(text.items.len <= limits.max_bytes);
        kept += 1;
        line_no += 1;
    }
    return .{ .text = text.items, .long_lines = long_lines };
}

/// Take one line without its newline, cut above `max_bytes`, or null at the end of the file. The result borrows the writer buffer until the next call.
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

/// Return the longest prefix that ends on a codepoint boundary, or null when the trailing bytes are invalid rather than cut.
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
    std.Io.File.SetPermissionsError || std.Io.Dir.RenameError || std.Io.Dir.DeleteFileError ||
    std.Io.File.StatError || std.Io.File.ReadPositionalError;

/// Map a native file-system error to `HostError`, an unlisted one to `HostFailure`. An opened directory reports on the first read.
fn mapError(err: NativeError) h.HostError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.IsDir => error.NotAFile,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        // `readFileAlloc` reports the byte limit this way. The caller must see the size, not a fault.
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        error.HomeUnavailable => error.HomeUnavailable,
        error.Canceled => error.Canceled,
        else => error.HostFailure,
    };
}

/// Reject a path that is not a regular file, because a FIFO or a device blocks a read forever. A read follows a symlink, a write must not.
/// Stat the path before the open to reject a special file, and return the stat of a regular file.
fn requireRegularFile(io: std.Io, path: []const u8) h.HostError!std.Io.File.Stat {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return mapError(err);
    if (stat.kind != .file) return error.NotAFile;
    return stat;
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
        return .{ .items = self.items.items, .more = self.dropped };
    }
};

/// Scan the whole directory and keep the `limit` subdirectories that sort first.
fn selectPage(io: std.Io, dir: std.Io.Dir, scratch: std.mem.Allocator, limit: u32) h.HostError!PageBuilder {
    var builder = PageBuilder.init(scratch, limit) catch unreachable;
    var it = dir.iterate();
    while (it.next(io) catch |err| return mapError(err)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        // A wire name is a JSON string, so a name that is not UTF-8 has no valid encoding.
        if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
        if (!entryIsDir(io, dir, entry)) continue;
        builder.offer(.{ .name = entry.name });
    }
    return builder;
}

const testing = std.testing;

/// The local host tests borrow this empty environment.
const test_env: Map = .init(testing.allocator);

const test_limits: h.ReadLimits = .{ .max_lines = 2000, .max_line_bytes = 64, .max_bytes = 4096 };

/// The fixture writes `data` to a temporary file. It reads a range through `LocalHost`.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init(self: *Fixture, data: []const u8) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator) };
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = data });
        self.root_len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }
    fn read(self: *Fixture, range: h.Range, limits: h.ReadLimits) h.HostError!h.RangeRead {
        var local: LocalHost = .{ .io = testing.io, .root = self.root_buf[0..self.root_len], .env = &test_env };
        return (try local.readRange(self.arena.allocator(), "a.txt", range, limits)).text;
    }
};

test "LocalHost detects image headers before a range and without a file extension" {
    for ([_][]const u8{ blob.png_1x1, "GIF89a", "\xff\xd8\xff", "RIFF\x04\x00\x00\x00WEBP" }) |data| {
        var f: Fixture = undefined;
        try f.init(data);
        defer f.deinit();
        var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
        const got = try local.readRange(f.arena.allocator(), "a.txt", .{ .start = 2, .end = 2 }, test_limits);
        try testing.expectEqualStrings(try std.Io.Dir.path.join(f.arena.allocator(), &.{ local.root, "a.txt" }), got.image);
    }
}

test "LocalHost reads simple ranges" {
    const Case = struct {
        data: []const u8,
        range: h.Range,
        limits: h.ReadLimits,
        want_text: []const u8,
        want_next: ?u32,
    };
    const cases = [_]Case{
        .{ .data = "one\ntwo\nthree\n", .range = .{}, .limits = test_limits, .want_text = "one\ntwo\nthree\n", .want_next = null },
        .{ .data = "one\ntwo\nthree\n", .range = .{ .start = 2, .end = 3 }, .limits = test_limits, .want_text = "two\nthree\n", .want_next = null },
        .{ .data = "x\ny", .range = .{ .start = 2, .end = 2 }, .limits = test_limits, .want_text = "y\n", .want_next = null },
        .{ .data = "x\ny", .range = .{ .start = 10 }, .limits = test_limits, .want_text = "", .want_next = null },
        .{ .data = "1\n2\n3\n4\n5\n", .range = .{}, .limits = .{ .max_lines = 2, .max_line_bytes = 64, .max_bytes = 4096 }, .want_text = "1\n2\n", .want_next = 3 },
        .{ .data = "1\n2\n", .range = .{}, .limits = .{ .max_lines = 2, .max_line_bytes = 64, .max_bytes = 4096 }, .want_text = "1\n2\n", .want_next = null },
    };
    for (cases) |case| {
        var f: Fixture = undefined;
        try f.init(case.data);
        defer f.deinit();
        const got = try f.read(case.range, case.limits);
        try testing.expectEqualStrings(case.want_text, got.text);
        try testing.expectEqual(case.want_next, got.next_line);
    }
}

test "LocalHost reads bytes from an offset and keeps a cut character for the next read" {
    var f: Fixture = undefined;
    try f.init("ab\xe6\x97\xa5c");
    defer f.deinit();
    const a = f.arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };

    const first = try local.readFrom(a, "a.txt", 0, 4, false);
    try testing.expectEqualStrings("ab", first.text);
    try testing.expectEqual(@as(u64, 2), first.next);
    const rest = try local.readFrom(a, "a.txt", first.next, 64, false);
    try testing.expectEqualStrings("\xe6\x97\xa5c", rest.text);
    try testing.expectEqual(@as(u64, 6), rest.next);
    // An offset past the end answers the size, so a caller can start at the tail.
    const past = try local.readFrom(a, "a.txt", 1 << 40, 4, false);
    try testing.expectEqualStrings("", past.text);
    try testing.expectEqual(past.size, past.next);
}

test "LocalHost stops at the byte limit with complete lines" {
    var f: Fixture = undefined;
    try f.init("aaaa\nbbbb\ncccc\n");
    defer f.deinit();
    var narrow = test_limits;
    narrow.max_line_bytes = 8; // a line must always fit inside the byte limit
    narrow.max_bytes = 12; // two five-byte lines fit. The third line does not fit.
    const got = try f.read(.{}, narrow);
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
    const got = try f.read(.{}, test_limits);
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
    const got = try f.read(.{}, test_limits);
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
    try testing.expectError(error.InvalidUtf8, f.read(.{}, test_limits));
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
    try testing.expectError(error.InvalidUtf8, f.read(.{}, test_limits));
}

test "LocalHost maps a missing path and a directory" {
    var f: Fixture = undefined;
    try f.init("x\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
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
    try testing.expectEqualStrings("hi\n", got.text.text);
}

test "LocalHost refuses a tilde path when the environment names no home directory" {
    var f: Fixture = undefined;
    try f.init("hi\n");
    defer f.deinit();
    var relative = Map.init(testing.allocator);
    defer relative.deinit();
    try relative.put("HOME", "relative/home");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // An absent home and a relative home both refuse; neither may read `<root>/~/a.txt`.
    for ([_]*const Map{ &test_env, &relative }) |env| {
        var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = env };
        try testing.expectError(error.HomeUnavailable, local.readRange(arena.allocator(), "~/a.txt", .{}, test_limits));
    }
}

test "LocalHost does not confine reads to the workspace" {
    var f: Fixture = undefined;
    try f.init("inside\n");
    defer f.deinit();
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    try other.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "secret\n" });
    var other_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const other_root = other_buf[0..try other.dir.realPath(testing.io, &other_buf)];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outside = try std.Io.Dir.path.join(a, &.{ other_root, "outside.txt" });
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
    // An absolute path outside the workspace reads freely (no confinement).
    const got = try local.readRange(a, outside, .{}, test_limits);
    try testing.expectEqualStrings("secret\n", got.text.text);
}

test "LocalHost readAllInto returns exact bytes and reports the size limit" {
    var f: Fixture = undefined;
    try f.init("one\ntwo");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };

    // The bytes must be exact. `readRange` cuts long lines, so a write-back needs this path.
    try testing.expectEqualStrings("one\ntwo", try local.readAllInto(a, a, "a.txt", 1024));
    // `readFileAlloc` reports the limit as StreamTooLong. The caller must see the size.
    try testing.expectError(error.TooLarge, local.readAllInto(a, a, "a.txt", 3));
    try testing.expectError(error.NotFound, local.readAllInto(a, a, "nope.txt", 1024));
    try testing.expectError(error.NotAFile, local.readAllInto(a, a, ".", 1024));
}

test "LocalHost readAllInto refuses a file it cannot decode as UTF-8" {
    var f: Fixture = undefined;
    try f.init("\xff\xfe\n");
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
    try testing.expectError(error.InvalidUtf8, local.readAllInto(arena.allocator(), arena.allocator(), "a.txt", 1024));
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

    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
    try local.writeFile(a, "a.txt", "new content\n");
    try testing.expectEqualStrings("new content\n", try local.readAllInto(a, a, "a.txt", 1024));

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

    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
    try local.writeFile(a, "fresh.txt", "hello\n");
    try testing.expectEqualStrings("hello\n", try local.readAllInto(a, a, "fresh.txt", 1024));
}

test "LocalHost writeFile and removeFile refuse a target that is not a regular file" {
    var f: Fixture = undefined;
    try f.init("target\n");
    defer f.deinit();
    try f.tmp.dir.symLink(testing.io, "a.txt", "link.txt", .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
    // A rename replaces the link itself, so a write through a symlink would change the wrong object.
    try testing.expectError(error.NotAFile, local.writeFile(a, "link.txt", "x"));
    try testing.expectError(error.NotAFile, local.writeFile(a, ".", "x"));
    try testing.expectError(error.NotAFile, local.writeFile(a, "/", "x"));
    // removeFile refuses the link, so the file that the link names stays.
    try testing.expectError(error.NotAFile, local.removeFile(a, "link.txt"));
    // The target keeps its content.
    try testing.expectEqualStrings("target\n", try local.readAllInto(a, a, "a.txt", 1024));
}

/// Build a directory tree for the directory-page tests. The fixture holds the root path.
const TreeFixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
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
    fn list(self: *TreeFixture, a: std.mem.Allocator, limit: u32) h.HostError!h.DirPage {
        var local: LocalHost = .{ .io = testing.io, .root = self.root_buf[0..self.root_len], .env = &test_env };
        return local.listDir(a, ".", limit);
    }
};

test "listDir sorts directories by name, drops files, and reports a full page" {
    var f: TreeFixture = undefined;
    try f.init(&.{ "beta", "alpha" }, &.{"note.txt"});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const page = try f.list(a, 10);
    try testing.expectEqual(@as(usize, 2), page.items.len);
    try testing.expectEqualStrings("alpha", page.items[0].name);
    try testing.expectEqualStrings("beta", page.items[1].name);
    try testing.expect(!page.items[0].is_git_repo and !page.more);

    const first = try f.list(a, 1);
    try testing.expectEqualStrings("alpha", first.items[0].name);
    try testing.expect(first.more);
}

test "listDir marks a directory that holds .git" {
    var f: TreeFixture = undefined;
    try f.init(&.{ "repo", "plain" }, &.{});
    defer f.deinit();
    try f.tmp.dir.createDir(testing.io, "repo/.git", .default_dir);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const page = try f.list(arena.allocator(), 10);
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
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };

    const dir = try local.stat(a, "sub");
    try testing.expect(dir.is_directory);
    const file = try local.stat(a, "a.txt");
    try testing.expect(!file.is_directory);
    try testing.expect(file.last_modified_ms > 0);
    try testing.expectError(error.NotFound, local.stat(a, "gone"));
}

test "a final byte read consumes invalid UTF-8 and a tail needs no size probe" {
    var f: Fixture = undefined;
    try f.init("abc\xe6\x97");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local: LocalHost = .{ .io = testing.io, .root = f.root_buf[0..f.root_len], .env = &test_env };
    const live = try local.readFrom(a, "a.txt", 0, 64, false);
    try testing.expectEqualStrings("abc", live.text);
    try testing.expect(!live.complete);
    const end = try local.readFrom(a, "a.txt", live.next, 4, true);
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", end.text);
    try testing.expect(end.complete and end.next == end.size);
    const tail = try local.readFrom(a, "a.txt", null, 4, true);
    try testing.expectEqual(@as(u64, 1), tail.start);
    try testing.expectEqualStrings("bc\u{FFFD}\u{FFFD}", tail.text);
    try testing.expectError(error.HostFailure, local.readFrom(a, "a.txt", 0, 1, false));
}
