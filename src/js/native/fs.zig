//! File-system primitives return promises; read tasks perform I/O outside the JavaScript owner.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const os = @import("../host/operations.zig");
const LocalHost = @import("../host/local.zig").LocalHost;
const pending = @import("../pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The most bytes `readFile` returns. A tool that needs more should read a range.
const max_read_bytes: u32 = 10 * 1024 * 1024;

/// Register `yuke:internal/native/fs` and its one `fs` object.
pub fn install(host: *Host) void {
    module.installObject(host, "yuke:internal/native/fs", "fs", &.{
        .{ .name = "readFile", .arity = 1, .call = jsReadFile },
        .{ .name = "readRange", .arity = 2, .call = jsReadRange },
        .{ .name = "writeFile", .arity = 2, .call = jsWriteFile },
        .{ .name = "stat", .arity = 1, .call = jsStat },
        .{ .name = "removeFile", .arity = 1, .call = jsRemoveFile },
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
        error.HomeUnavailable => "the environment names no home directory, so a ~ path has no meaning",
        error.Canceled => "the call was canceled",
        error.HostFailure => "the file system reported a failure",
    };
}

/// Copy the path argument at `idx`, or answer null when it is not a non-empty string without a NUL byte.
fn ownedPath(ctx: Context, gpa: std.mem.Allocator, args: []const Value, idx: usize) ?[]u8 {
    if (args.len <= idx) return null;
    const raw = module.string(ctx, args[idx]) orelse return null;
    defer ctx.freeCString(raw.ptr);
    // The OS stops at a NUL byte, so the check rejects a different file name.
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) return null;
    return gpa.dupe(u8, raw) catch unreachable;
}

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
    // The 48 KiB cap leaves room for the continuation note under the 50 KiB engine cap.
    .max_bytes = 48 * 1024,
};

/// Read a whole file as text on its own task, so the owner keeps painting. A file that is not valid UTF-8 rejects.
fn jsReadFile(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    // The task cannot touch JavaScript, so the path is copied before it starts.
    const root = module.rootOption(ctx, host.gpa, if (args.len > 1) args[1] else quickjs.UNDEFINED, host.cwd) orelse return pending.rejected(ctx, module.root_option_message);
    const path = ownedPath(ctx, host.gpa, args, 0) orelse {
        host.gpa.free(root);
        return pending.rejected(ctx, "the path must be a non-empty string with no NUL byte");
    };
    return host.startTask(ReadRequest, readTask, .{ .path = path, .root = root }, .{});
}

/// Read bounded whole lines. The task owns the path and returns a small JSON range descriptor.
fn jsReadRange(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const root = module.rootOption(ctx, host.gpa, if (args.len > 1) args[1] else quickjs.UNDEFINED, host.cwd) orelse return pending.rejected(ctx, module.root_option_message);
    const path = ownedPath(ctx, host.gpa, args, 0) orelse {
        host.gpa.free(root);
        return pending.rejected(ctx, "the path must be a non-empty string with no NUL byte");
    };
    const range = rangeArg(ctx, args, 1) catch {
        host.gpa.free(path);
        host.gpa.free(root);
        return pending.rejected(ctx, "the read range is invalid");
    };
    return host.startTask(ReadRequest, readRangeTask, .{ .path = path, .root = root, .range = range }, .{});
}

/// Read one file on a task; it writes bytes into the op and never enters JavaScript; `Host.close` cancels this group and waits for it, so a task must reach a cancellation point, and the task must stay within input and output.
fn readTask(host: *Host, op: *pending.Op, req: ReadRequest) void {
    defer req.free(host.gpa);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = req.root, .env = host.execution.env };
    const text = local.readAllInto(arena.allocator(), host.gpa, req.path, max_read_bytes) catch |err|
        return op.finish(.{ .failed = .{ .message = errorMessage(err) } });
    op.finish(.{ .text = text });
}

fn readRangeTask(host: *Host, op: *pending.Op, req: ReadRequest) void {
    defer req.free(host.gpa);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    var local: LocalHost = .{ .io = host.io, .root = req.root, .env = host.execution.env };
    const got = local.readRange(arena.allocator(), req.path, req.range, read_limits) catch |err| {
        arena.deinit();
        return op.finish(.{ .failed = .{ .message = errorMessage(err) } });
    };
    const answer = arena.allocator().create(RangeAnswer) catch unreachable;
    answer.* = switch (got) {
        .text => |range| .{ .text = .{ .text = range.text, .next = range.next_line, .long_lines = range.long_lines } },
        .image => |path| .{ .image = .{ .image_path = path } },
    };
    // The result takes the arena, so the text reaches the script with no copy on the task.
    op.finish(.{ .object = .init(arena, answer) });
}

/// The object `readRange` answers: `{ text, next, longLines }` or `{ imagePath }`.
const RangeAnswer = union(enum) {
    text: struct { text: []const u8, next: ?u32, long_lines: u32 },
    image: struct { image_path: []const u8 },
};

fn rangeArg(ctx: Context, args: []const Value, idx: usize) error{InvalidOption}!os.Range {
    // `rootOption` already rejected bad options, so the argument is undefined or an object.
    if (args.len <= idx or ctx.isUndefined(args[idx])) return .{};
    const numbered = ctx.getPropertyStr(args[idx], "lineNumbers");
    defer ctx.freeValue(numbered);
    if (!ctx.isUndefined(numbered) and !ctx.isBool(numbered)) return error.InvalidOption;
    return .{
        .start = try boundArg(ctx, args[idx], "start"),
        .end = try boundArg(ctx, args[idx], "end"),
        .numbered = ctx.isBool(numbered) and (ctx.toBool(numbered) catch unreachable), // `isBool` holds, so the conversion cannot fail
    };
}

fn boundArg(ctx: Context, obj: Value, name: [:0]const u8) error{InvalidOption}!?u32 {
    const value = ctx.getPropertyStr(obj, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value)) return null;
    return @intCast(module.integer(ctx, value, 1, std.math.maxInt(u32)) orelse return error.InvalidOption);
}

/// Replace a file's whole content. It answers the byte count it wrote.
fn jsWriteFile(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const root = module.rootOption(ctx, host.gpa, if (args.len > 2) args[2] else quickjs.UNDEFINED, host.cwd) orelse return pending.rejected(ctx, module.root_option_message);
    defer host.gpa.free(root);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = root, .env = host.execution.env };

    if (args.len < 2) return pending.rejected(ctx, "writeFile needs a path and content");
    const path = ownedPath(ctx, arena.allocator(), args, 0) orelse return pending.rejected(ctx, "the path must be a non-empty string with no NUL byte");
    const raw = module.string(ctx, args[1]) orelse return pending.rejected(ctx, "the content must be a string");
    defer ctx.freeCString(raw.ptr);

    local.writeFile(arena.allocator(), path, raw) catch |err| return pending.rejected(ctx, errorMessage(err));
    return pending.resolved(ctx, ctx.newInt64(@intCast(raw.len)));
}

/// Describe one path, or answer null when nothing is there. The answer names the anchored path.
fn jsStat(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const root = module.rootOption(ctx, host.gpa, if (args.len > 1) args[1] else quickjs.UNDEFINED, host.cwd) orelse return pending.rejected(ctx, module.root_option_message);
    defer host.gpa.free(root);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = root, .env = host.execution.env };

    const path = ownedPath(ctx, arena.allocator(), args, 0) orelse return pending.rejected(ctx, "the path must be a non-empty string with no NUL byte");
    const info = local.stat(arena.allocator(), path) catch |err| switch (err) {
        error.NotFound => return pending.resolved(ctx, quickjs.NULL),
        else => return pending.rejected(ctx, errorMessage(err)),
    };
    return pending.resolved(ctx, module.toJs(ctx, info));
}

/// Remove one regular file, and resolve false for a missing path, so a cleanup needs no `stat` first.
fn jsRemoveFile(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const root = module.rootOption(ctx, host.gpa, if (args.len > 1) args[1] else quickjs.UNDEFINED, host.cwd) orelse return pending.rejected(ctx, module.root_option_message);
    defer host.gpa.free(root);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = root, .env = host.execution.env };

    const path = ownedPath(ctx, arena.allocator(), args, 0) orelse return pending.rejected(ctx, "the path must be a non-empty string with no NUL byte");
    local.removeFile(arena.allocator(), path) catch |err| switch (err) {
        error.NotFound => return pending.resolved(ctx, ctx.newBool(false)),
        else => return pending.rejected(ctx, errorMessage(err)),
    };
    return pending.resolved(ctx, ctx.newBool(true));
}

const testing = std.testing;

test "every host error maps to a sentence a script can read" {
    // The set is closed, so a new error must gain a message here rather than reach JavaScript bare.
    inline for (@typeInfo(os.HostError).error_set.?) |e| {
        const message = errorMessage(@field(os.HostError, e.name));
        try testing.expect(message.len != 0);
        try testing.expect(std.ascii.isLower(message[0])); // the message continues a sentence
    }
}
