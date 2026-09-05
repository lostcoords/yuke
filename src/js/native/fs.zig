//! The native `yuke:fs` module: the file-system primitives a tool or a view builds on.
//!
//! Every call answers a Promise, so a caller writes `await` once and never rewrites it. Today the
//! work runs inline and the promise arrives settled; making one operation concurrent later changes
//! no JavaScript. A failure rejects with an Error, so `try`/`catch` reads like any other module.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const os = @import("../host/operations.zig");
const LocalHost = @import("../host/local.zig").LocalHost;
const paths = @import("../../paths.zig");
const pending = @import("../pending.zig");

const resolved = pending.resolved;
const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The most entries one listing returns. A larger directory reports `more` and stops.
pub const max_entries: u32 = 512;

/// The most bytes `readFile` returns. A tool that needs more should read a range.
pub const max_read_bytes: u32 = 10 * 1024 * 1024;

/// Register `yuke:fs` and its one `fs` object.
pub fn install(host: *Host) void {
    module.installObject(host, "yuke:fs", "fs", &.{
        .{ .name = "list", .arity = 1, .call = jsList },
        .{ .name = "readFile", .arity = 1, .call = jsReadFile },
        .{ .name = "readRange", .arity = 2, .call = jsReadRange },
        .{ .name = "writeFile", .arity = 2, .call = jsWriteFile },
        .{ .name = "stat", .arity = 1, .call = jsStat },
    }, null);
}

/// Map a host error to the sentence a script reads. The set is closed, so a new one needs a message.
fn errorMessage(err: os.HostError) []const u8 {
    return switch (err) {
        error.NotFound => "the path does not exist",
        error.NotAFile => "the path names a directory or a special file",
        error.AccessDenied => "the file system denied access to the path",
        error.TooLarge => "the file exceeds the size limit",
        error.InvalidUtf8 => "the file holds invalid UTF-8",
        error.Canceled => "the call was canceled",
        error.HostFailure => "the file system reported a failure",
    };
}

/// Take the path argument, or the directory the process runs in when it is absent.
fn pathArg(ctx: Context, arena: std.mem.Allocator, args: []const Value, idx: usize, root: []const u8) ?[]const u8 {
    if (args.len <= idx or ctx.isUndefined(args[idx]) or ctx.isNull(args[idx])) return root;
    const raw = ctx.toCStringLen(args[idx]) catch return null;
    defer ctx.freeCString(raw.ptr);
    if (raw.len == 0) return root;
    return arena.dupe(u8, raw) catch unreachable;
}

/// One scratch arena and one local host for a single call. The host anchors a relative path.
const Call = struct {
    arena: std.heap.ArenaAllocator,
    local: LocalHost,

    fn open(host: *Host, root: []const u8) Call {
        return .{
            .arena = .init(host.gpa),
            .local = .{ .io = host.io, .root = root, .env = host.env },
        };
    }
    fn close(self: *Call) void {
        self.arena.deinit();
    }
    fn alloc(self: *Call) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// One read, copied so the task can use it after the call returns.
const ReadRequest = struct {
    path: []u8,
    root: []u8,
    range: os.Range = .{},

    pub fn free(self: ReadRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.root);
    }
};

const read_limits: os.ReadLimits = .{
    .max_lines = 2000,
    .max_line_bytes = 8000,
    .max_bytes = 64 * 1024,
};

/// Read a whole file as text on its own task, so the owner keeps painting. A file that is not valid UTF-8 rejects.
fn jsReadFile(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    // The task cannot touch JavaScript, so the path is copied before it starts.
    const root = ownedPath(ctx, host, args, 1) orelse return rejected(ctx, "the workspace root must be a string");
    const path = ownedPath(ctx, host, args, 0) orelse {
        host.gpa.free(root);
        return rejected(ctx, "the path must be a string");
    };
    return host.startTask(ReadRequest, readTask, .{ .path = path, .root = root });
}

/// Read bounded whole lines. The task owns the path and returns a small JSON range descriptor.
fn jsReadRange(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const root = ownedPath(ctx, host, args, 2) orelse return rejected(ctx, "the workspace root must be a string");
    const path = ownedPath(ctx, host, args, 0) orelse {
        host.gpa.free(root);
        return rejected(ctx, "the path must be a string");
    };
    const range = rangeArg(ctx, args, 1) catch {
        host.gpa.free(path);
        host.gpa.free(root);
        return rejected(ctx, "the read range is invalid");
    };
    return host.startTask(ReadRequest, readRangeTask, .{ .path = path, .root = root, .range = range });
}

/// Read one file on a task. It writes bytes into the op and never enters JavaScript.
///
/// `Host.close` cancels this group and waits for it, so a task must reach a cancellation point; keep it to input and output.
fn readTask(host: *Host, op: *pending.Op, req: ReadRequest) void {
    defer req.free(host.gpa);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = req.root, .env = host.env };

    const text = local.readAll(arena.allocator(), req.path, max_read_bytes) catch |err|
        return op.finish(.{ .failed = errorMessage(err) });
    const owned = host.gpa.dupe(u8, text) catch
        return op.finish(.{ .failed = "out of memory" });
    op.finish(.{ .text = owned });
}

fn readRangeTask(host: *Host, op: *pending.Op, req: ReadRequest) void {
    defer req.free(host.gpa);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = req.root, .env = host.env };
    const got = local.readRange(arena.allocator(), req.path, req.range, read_limits) catch |err|
        return op.finish(.{ .failed = errorMessage(err) });
    const json = encodeRange(host.gpa, got);
    op.finish(.{ .json = json });
}

fn rangeArg(ctx: Context, args: []const Value, idx: usize) error{InvalidOption}!os.Range {
    if (args.len <= idx or !ctx.isObject(args[idx]) or ctx.isArray(args[idx])) return .{};
    return .{ .start = try boundArg(ctx, args[idx], "start"), .end = try boundArg(ctx, args[idx], "end") };
}

fn boundArg(ctx: Context, obj: Value, name: [:0]const u8) error{InvalidOption}!?u32 {
    const value = ctx.getPropertyStr(obj, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return null;
    return @intCast(module.integer(ctx, value, 1, std.math.maxInt(u32)) orelse return error.InvalidOption);
}

fn encodeRange(gpa: std.mem.Allocator, got: os.RangeRead) [:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    std.json.Stringify.value(.{
        .text = got.text,
        .next = got.next_line,
        .longLines = got.long_lines,
    }, .{ .emit_null_optional_fields = true }, &aw.writer) catch unreachable;
    var list = aw.toArrayList();
    return list.toOwnedSliceSentinel(gpa, 0) catch unreachable;
}

/// Copy one path argument so a task can read it after the call returns. An absent or empty one is the cwd.
fn ownedPath(ctx: Context, host: *Host, args: []const Value, idx: usize) ?[]u8 {
    if (args.len <= idx or ctx.isUndefined(args[idx]) or ctx.isNull(args[idx])) return host.gpa.dupe(u8, host.cwd) catch unreachable;
    if (!ctx.isString(args[idx])) return null;
    const raw = ctx.toCStringLen(args[idx]) catch return null;
    defer ctx.freeCString(raw.ptr);
    return host.gpa.dupe(u8, if (raw.len == 0) host.cwd else raw) catch unreachable;
}

/// Replace a file's whole content. It answers the byte count it wrote.
fn jsWriteFile(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const root = ownedPath(ctx, host, args, 2) orelse return rejected(ctx, "the workspace root must be a string");
    defer host.gpa.free(root);
    var call = Call.open(host, root);
    defer call.close();

    if (args.len < 2) return rejected(ctx, "writeFile needs a path and content");
    const path = pathArg(ctx, call.alloc(), args, 0, root) orelse return rejected(ctx, "the path must be a string");
    if (!ctx.isString(args[1])) return rejected(ctx, "the content must be a string");
    const raw = ctx.toCStringLen(args[1]) catch return rejected(ctx, "the content must be a string");
    defer ctx.freeCString(raw.ptr);

    call.local.writeFile(call.alloc(), path, raw) catch |err| return rejected(ctx, errorMessage(err));
    return resolved(ctx, ctx.newInt64(@intCast(raw.len)));
}

/// Describe one path, or answer null when nothing is there.
fn jsStat(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    var call = Call.open(host, host.cwd);
    defer call.close();

    const path = pathArg(ctx, call.alloc(), args, 0, host.cwd) orelse return rejected(ctx, "the path must be a string");
    const info = call.local.stat(call.alloc(), path) catch |err| switch (err) {
        error.NotFound => return resolved(ctx, quickjs.NULL),
        else => return rejected(ctx, errorMessage(err)),
    };
    const out = ctx.newObject();
    ctx.setPropertyStr(out, "isDirectory", ctx.newBool(info.is_dir)) catch {};
    ctx.setPropertyStr(out, "lastModifiedMs", ctx.newInt64(@intCast(info.last_modified_ms))) catch {};
    // A full QuickJS heap throws at the caller, because no promise can be built for it either.
    if (ctx.hasException()) {
        ctx.freeValue(out);
        return module.throwPending(ctx);
    }
    return resolved(ctx, out);
}

/// List the directories inside one path as a `Page`; a null or absent path is the directory the TUI runs in, and an unreadable one rejects.
fn jsList(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    var call = Call.open(host, host.cwd);
    defer call.close();
    const arena = call.alloc();

    const requested = pathArg(ctx, arena, args, 0, host.cwd) orelse return rejected(ctx, "the path must be a string");
    const path = paths.canonicalizeWorkspace(arena, host.env, requested) catch
        return rejected(ctx, "the path is not a directory this process can read");
    const page = call.local.listDir(arena, path, .{ .limit = max_entries, .include_files = false }) catch |err|
        return rejected(ctx, errorMessage(err));

    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    defer aw.deinit();
    std.json.Stringify.value(pageOf(arena, path, page), .{}, &aw.writer) catch unreachable;
    // The page is our own JSON, so the parse fails only once the QuickJS heap is full.
    const value = ctx.parseJSON(aw.written(), "yuke:fs");
    if (ctx.isException(value)) return module.throwPending(ctx);
    return resolved(ctx, value);
}

/// Build the answer. Each entry carries its whole path, so the caller never joins one itself.
fn pageOf(arena: std.mem.Allocator, path: []const u8, page: os.DirPage) Page {
    const entries = arena.alloc(Page.Entry, page.items.len) catch unreachable;
    for (page.items, entries) |item, *entry| entry.* = .{
        .name = item.name,
        .path = std.fs.path.join(arena, &.{ path, item.name }) catch unreachable,
        .is_git_repo = item.is_git_repo,
    };
    return .{
        .path = path,
        .parent = std.fs.path.dirname(path),
        .entries = entries,
        .more = page.next_after != null,
    };
}

/// One directory listing, as the explorer reads it.
const Page = struct {
    /// The canonical directory this page lists.
    path: []const u8,
    /// The parent directory, or null at the file-system root.
    parent: ?[]const u8,
    entries: []const Entry,
    /// True when the directory holds more names than one page returns.
    more: bool,

    const Entry = struct {
        name: []const u8,
        path: []const u8,
        is_git_repo: bool,
    };
};

const testing = std.testing;

test "list answers the directories of a real path and marks a repository" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "alpha");
    try tmp.dir.createDirPath(testing.io, "beta/.git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "x" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var local: LocalHost = .{ .io = testing.io, .root = root, .env = null };
    const page = try local.listDir(arena, root, .{ .limit = max_entries, .include_files = false });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(pageOf(arena, root, page), .{}, &aw.writer);

    const parsed = try std.json.parseFromSlice(Page, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    // `note.txt` is a file, so the directory-only listing drops it.
    try testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try testing.expectEqualStrings("alpha", parsed.value.entries[0].name);
    try testing.expect(!parsed.value.entries[0].is_git_repo);
    try testing.expectEqualStrings("beta", parsed.value.entries[1].name);
    try testing.expect(parsed.value.entries[1].is_git_repo);
    try testing.expect(!parsed.value.more);
    try testing.expectEqualStrings(root, parsed.value.path);
}

test "every host error maps to a sentence a script can read" {
    // The set is closed, so a new error must gain a message here rather than reach JavaScript bare.
    inline for (@typeInfo(os.HostError).error_set.?) |e| {
        const message = errorMessage(@field(os.HostError, e.name));
        try testing.expect(message.len != 0);
        try testing.expect(std.ascii.isLower(message[0])); // the message continues a sentence
    }
}
