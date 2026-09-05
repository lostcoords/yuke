//! The native `yuke:exec` module: run one shell command and answer what it printed.
//!
//! A command has a real duration, so it always runs on its own task.
//! The owner continues to paint, and the task writes plain JSON text the owner turns into a result.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const os = @import("../host/operations.zig");
const LocalHost = @import("../host/local.zig").LocalHost;
const pending = @import("../pending.zig");
const utf8 = @import("../../utf8.zig");

const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;

/// The command deadline. A caller raises it up to `max_timeout_ms`.
pub const default_timeout_ms: u32 = 120_000;
pub const max_timeout_ms: u32 = 600_000;

/// The cap for each stream. A command that prints more loses its middle, not its result.
pub const max_stream_bytes: u32 = 64 * 1024;

/// Register the closed `yuke:exec` module and export `exec`.
pub fn install(host: *Host) void {
    std.debug.assert(host.phase == .open);
    const m = host.ctx.newModule("yuke:exec", init).?;
    host.ctx.addModuleExport(m, "exec") catch unreachable;
}

fn init(ctx: Context, m: Module) c_int {
    std.debug.assert(Host.fromContext(ctx).phase == .open);
    ctx.setModuleExport(m, "exec", ctx.newFunction("exec", 2, jsExec)) catch return -1;
    return 0;
}

/// One command, copied so the task can read it after the call returns.
const Request = struct {
    command: []u8,
    root: []u8,
    cwd: ?[]u8,
    timeout_ms: u32,

    pub fn free(self: Request, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
        gpa.free(self.root);
        if (self.cwd) |dir| gpa.free(dir);
    }
};

/// Run one shell command. A refused argument rejects, so a caller reads one failure shape.
fn jsExec(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len == 0) return rejected(ctx, "exec needs a command");

    // The task cannot touch JavaScript, so every argument is copied before it starts.
    const command = ownedString(ctx, host.gpa, args[0]) orelse return rejected(ctx, "the command must be a string");
    // A blank command exits 0 and would tell a caller that it finished work.
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
        host.gpa.free(command);
        return rejected(ctx, "the command must not be blank");
    }

    const options: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const root = ownedString(ctx, host.gpa, if (args.len > 2) args[2] else quickjs.UNDEFINED) orelse host.gpa.dupe(u8, host.cwd) catch {
        host.gpa.free(command);
        return rejected(ctx, "the workspace root must be a string");
    };
    const cwd = optionalString(ctx, host.gpa, options, "cwd") catch {
        host.gpa.free(command);
        host.gpa.free(root);
        return rejected(ctx, "cwd must be a string");
    };
    const timeout_ms = timeoutOf(ctx, options) catch {
        host.gpa.free(command);
        if (cwd) |dir| host.gpa.free(dir);
        host.gpa.free(root);
        return rejected(ctx, "timeoutMs must be a whole number of milliseconds up to 600000");
    };

    return host.startTask(execTask, Request{ .command = command, .root = root, .cwd = cwd, .timeout_ms = timeout_ms });
}

/// Run one command on a task. It writes JSON text into the op and never enters JavaScript.
///
/// `Host.close` cancels this group and WAITS for it.
/// A cancel kills the process group, so the command ends and the task returns.
/// A descendant that calls `setsid` leaves that group.
fn execTask(host: *Host, op: *pending.Op, req: Request) void {
    defer req.free(host.gpa);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = req.root, .env = host.env };

    const result = local.exec(arena.allocator(), .{
        .command = req.command,
        .cwd = req.cwd,
        .timeout_ms = req.timeout_ms,
        .max_stream_bytes = max_stream_bytes,
    }) catch |err| return op.finish(.{ .failed = errorMessage(err) });

    op.finish(.{ .json = encode(host.gpa, arena.allocator(), result) });
}

/// Build the result text. A command prints any bytes, so each stream becomes valid UTF-8 first.
fn encode(gpa: std.mem.Allocator, scratch: std.mem.Allocator, r: os.ExecResult) [:0]u8 {
    const stdout = utf8.sanitize(scratch, r.stdout) catch unreachable;
    const stderr = utf8.sanitize(scratch, r.stderr) catch unreachable;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    write(&aw.writer, stdout, stderr, r) catch unreachable;
    var list = aw.toArrayList();
    // QuickJS reads the JSON text to the sentinel, so the buffer must carry one.
    return list.toOwnedSliceSentinel(gpa, 0) catch unreachable;
}

/// Write one result. `code` and `signal` are null for each outcome that did not produce them.
fn write(w: *std.Io.Writer, stdout: []const u8, stderr: []const u8, r: os.ExecResult) std.Io.Writer.Error!void {
    try w.writeAll("{\"stdout\":");
    try std.json.Stringify.encodeJsonString(stdout, .{}, w);
    try w.writeAll(",\"stderr\":");
    try std.json.Stringify.encodeJsonString(stderr, .{}, w);
    switch (r.outcome) {
        .exited => |code| try w.print(",\"code\":{d},\"signal\":null,\"timedOut\":false", .{code}),
        .signaled => |sig| try w.print(",\"code\":null,\"signal\":{d},\"timedOut\":false", .{sig}),
        .timed_out => try w.writeAll(",\"code\":null,\"signal\":null,\"timedOut\":true"),
    }
    try w.print(",\"stdoutDropped\":{d},\"stderrDropped\":{d}}}", .{ r.stdout_dropped, r.stderr_dropped });
}

/// Map a host error to the sentence a script reads. The set is closed, so a new one needs a message.
fn errorMessage(err: os.HostError) []const u8 {
    return switch (err) {
        error.NotFound => "the working directory does not exist",
        error.NotAFile => "the working directory is not a directory",
        error.AccessDenied => "the file system denied access to the working directory",
        error.TooLarge => "the command produced more than the host accepts",
        error.InvalidUtf8 => "the working directory name holds invalid UTF-8",
        error.Canceled => "the command was canceled",
        error.HostFailure => "the host could not run the command",
    };
}

/// Copy one string argument. A value that is not a string answers null.
fn ownedString(ctx: Context, gpa: std.mem.Allocator, value: Value) ?[]u8 {
    if (!ctx.isString(value)) return null;
    const raw = ctx.toCStringLen(value) catch return null;
    defer ctx.freeCString(raw.ptr);
    return gpa.dupe(u8, raw) catch null;
}

/// Copy one optional string option. An absent option answers null; a wrong type is an error.
fn optionalString(ctx: Context, gpa: std.mem.Allocator, options: Value, name: [:0]const u8) error{InvalidOption}!?[]u8 {
    if (!ctx.isObject(options)) return null;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return null;
    return ownedString(ctx, gpa, value) orelse error.InvalidOption;
}

/// Read `timeoutMs`, or answer the default. The range matches the built-in `exec` tool.
/// A number reaches JavaScript as a double, so a fraction must fail rather than truncate.
fn timeoutOf(ctx: Context, options: Value) error{InvalidOption}!u32 {
    if (!ctx.isObject(options)) return default_timeout_ms;
    const value = ctx.getPropertyStr(options, "timeoutMs");
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return default_timeout_ms;
    if (!ctx.isNumber(value)) return error.InvalidOption;
    const ms = ctx.toFloat64(value) catch return error.InvalidOption;
    if (!(ms >= 1 and ms <= max_timeout_ms) or @floor(ms) != ms) return error.InvalidOption;
    return @intFromFloat(ms);
}

const testing = std.testing;

fn encoded(a: std.mem.Allocator, r: os.ExecResult) ![]const u8 {
    return encode(a, a, r);
}

test "the result names the outcome that happened and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "{\"stdout\":\"out\\n\",\"stderr\":\"\",\"code\":3,\"signal\":null,\"timedOut\":false," ++
            "\"stdoutDropped\":0,\"stderrDropped\":0}",
        try encoded(a, .{ .stdout = "out\n", .stderr = "", .outcome = .{ .exited = 3 } }),
    );
    // A signal and a deadline leave `code` null, so a caller never reads a made-up zero.
    try testing.expectEqualStrings(
        "{\"stdout\":\"\",\"stderr\":\"\",\"code\":null,\"signal\":9,\"timedOut\":false," ++
            "\"stdoutDropped\":0,\"stderrDropped\":0}",
        try encoded(a, .{ .stdout = "", .stderr = "", .outcome = .{ .signaled = 9 } }),
    );
    try testing.expectEqualStrings(
        "{\"stdout\":\"\",\"stderr\":\"\",\"code\":null,\"signal\":null,\"timedOut\":true," ++
            "\"stdoutDropped\":0,\"stderrDropped\":0}",
        try encoded(a, .{ .stdout = "", .stderr = "", .outcome = .timed_out }),
    );
}

test "the result reports the bytes each stream dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const json = try encoded(arena.allocator(), .{
        .stdout = "head",
        .stderr = "tail",
        .outcome = .{ .exited = 0 },
        .stdout_dropped = 12,
        .stderr_dropped = 34,
    });
    try testing.expect(std.mem.indexOf(u8, json, "\"stdoutDropped\":12") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"stderrDropped\":34") != null);
}

// A command prints any bytes, but the result must be a JSON string the parser accepts.
test "the result holds valid text whatever the command printed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json = try encoded(a, .{ .stdout = "ok\xe6\x96", .stderr = "\x00\x01", .outcome = .{ .exited = 0 } });
    try testing.expect(std.unicode.utf8ValidateSlice(json));
    try testing.expect(std.mem.indexOf(u8, json, "ok\u{FFFD}\u{FFFD}") != null);

    // The text must parse back to what a script reads, control bytes included.
    const Shape = struct { stdout: []const u8, stderr: []const u8 };
    const parsed = try std.json.parseFromSliceLeaky(Shape, a, json, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("ok\u{FFFD}\u{FFFD}", parsed.stdout);
    try testing.expectEqualStrings("\x00\x01", parsed.stderr);
}

test "the encoded text ends with a sentinel QuickJS can read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const json = encode(arena.allocator(), arena.allocator(), .{
        .stdout = "x",
        .stderr = "",
        .outcome = .{ .exited = 0 },
    });
    try testing.expectEqual(@as(u8, 0), json.ptr[json.len]);
}
