//! The native `yuke:exec` module: run one shell command and answer what it printed.
//!
//! A command has a real duration, so it always runs on its own task.
//! The owner continues to paint, and the task writes plain JSON text the owner turns into a result.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const os = @import("../host/operations.zig");
const LocalHost = @import("../host/local.zig").LocalHost;
const pending = @import("../pending.zig");
const utf8 = @import("../../utf8.zig");

const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The command deadline. A caller raises it up to `max_timeout_ms`.
pub const default_timeout_ms: u32 = 120_000;
pub const max_timeout_ms: u32 = 600_000;

/// The cap for each stream. A command that prints more loses its middle, not its result.
pub const max_stream_bytes: u32 = 64 * 1024;

/// Register `yuke:exec` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:exec", &.{
        .{ .name = "exec", .arity = 2, .call = jsExec },
    });
}

/// One command, copied so the task can read it after the call returns.
const Request = struct {
    const ParseError = error{ CommandType, CommandBlank, RootType, CwdType, Timeout };

    command: []u8,
    root: []u8,
    cwd: ?[]u8,
    timeout_ms: u32,

    fn parse(
        ctx: Context,
        gpa: std.mem.Allocator,
        args: []const Value,
        options: Value,
        default_root: []const u8,
    ) ParseError!Request {
        std.debug.assert(args.len > 0);

        const command = module.owned(ctx, gpa, args[0]) orelse return error.CommandType;
        errdefer gpa.free(command);
        if (std.mem.trim(u8, command, " \t\r\n").len == 0) return error.CommandBlank;

        const root_arg: Value = if (args.len > 2) args[2] else quickjs.UNDEFINED;
        const root = if (ctx.isUndefined(root_arg) or ctx.isNull(root_arg))
            gpa.dupe(u8, default_root) catch unreachable
        else
            module.owned(ctx, gpa, root_arg) orelse return error.RootType;
        errdefer gpa.free(root);

        const cwd = optionalString(ctx, gpa, options, "cwd") catch return error.CwdType;
        errdefer if (cwd) |dir| gpa.free(dir);
        const timeout_ms = timeoutOf(ctx, options) catch return error.Timeout;

        return .{ .command = command, .root = root, .cwd = cwd, .timeout_ms = timeout_ms };
    }

    pub fn free(self: Request, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
        gpa.free(self.root);
        if (self.cwd) |dir| gpa.free(dir);
    }
};

/// Run one shell command. A refused argument rejects, so a caller reads one failure shape.
fn jsExec(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    if (args.len == 0) return rejected(ctx, "exec needs a command");

    const options: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const signal = if (ctx.isObject(options)) ctx.getPropertyStr(options, "signal") else quickjs.UNDEFINED;
    defer ctx.freeValue(signal);
    if (ctx.isException(signal)) return rejected(ctx, "the exec signal could not be read");
    if (!ctx.isUndefined(signal) and !host.calls.acceptsSignal(ctx, signal))
        return rejected(ctx, "the exec signal does not belong to an active tool call");

    // The task cannot touch JavaScript, so every argument is copied before it starts.
    const request = Request.parse(ctx, host.gpa, args, options, host.cwd) catch |err|
        return rejected(ctx, switch (err) {
            error.CommandType => "the command must be a string",
            error.CommandBlank => "the command must not be blank",
            error.RootType => "the workspace root must be a string",
            error.CwdType => "cwd must be a string",
            error.Timeout => "timeoutMs must be a whole number of milliseconds up to 600000",
        });
    return host.startTaskWithSignal(Request, execTask, request, signal);
}

// TODO: fold this into Cancel.runChild once that helper carries a child result value.
/// Join the command worker before the owner can free its op.
fn execTask(host: *Host, op: *pending.Op, req: Request) void {
    defer req.free(host.gpa);
    std.debug.assert(op.result == null);
    if (op.cancel.requested) return op.finish(.{ .failed = .{ .message = "the command was canceled" } });
    var worker = host.io.concurrent(execWorker, .{ host, op, req }) catch
        return op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } });
    op.cancel.event.wait(host.io) catch {
        const result = worker.cancel(host.io);
        op.finish(result);
        return;
    };
    const result = if (op.cancel.requested) worker.cancel(host.io) else worker.await(host.io);
    op.finish(result);
}

/// The worker touches no QuickJS values and signals its supervisor before return.
fn execWorker(host: *Host, op: *pending.Op, req: Request) pending.Result {
    defer op.cancel.finish(host.io);
    if (op.cancel.requested) return .{ .failed = .{ .message = "the command was canceled" } };
    host.io.checkCancel() catch return .{ .failed = .{ .message = "the command was canceled" } };
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = req.root, .env = host.execution.env };

    const result = local.exec(arena.allocator(), .{
        .command = req.command,
        .cwd = req.cwd,
        .timeout_ms = req.timeout_ms,
        .max_stream_bytes = max_stream_bytes,
    }) catch |err| return .{ .failed = .{ .message = errorMessage(err) } };

    return .{ .json = encode(host.gpa, arena.allocator(), result) };
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
        error.HomeUnavailable => "the environment names no home directory, so a ~ working directory has no meaning",
        error.Canceled => "the command was canceled",
        error.HostFailure => "the host could not run the command",
    };
}

/// Copy one optional string option. An absent option answers null; a wrong type is an error.
fn optionalString(ctx: Context, gpa: std.mem.Allocator, options: Value, name: [:0]const u8) error{InvalidOption}!?[]u8 {
    if (!ctx.isObject(options)) return null;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return null;
    return module.owned(ctx, gpa, value) orelse error.InvalidOption;
}

/// Read `timeoutMs`, or answer the default. The range matches the built-in `exec` tool, and a fraction fails rather than truncates.
fn timeoutOf(ctx: Context, options: Value) error{InvalidOption}!u32 {
    if (!ctx.isObject(options)) return default_timeout_ms;
    const value = ctx.getPropertyStr(options, "timeoutMs");
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return default_timeout_ms;
    return @intCast(module.integer(ctx, value, 1, max_timeout_ms) orelse return error.InvalidOption);
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
    try testing.expectEqualStrings(
        "{\"stdout\":\"head\",\"stderr\":\"tail\",\"code\":0,\"signal\":null,\"timedOut\":false," ++
            "\"stdoutDropped\":12,\"stderrDropped\":34}",
        try encoded(a, .{ .stdout = "head", .stderr = "tail", .outcome = .{ .exited = 0 }, .stdout_dropped = 12, .stderr_dropped = 34 }),
    );
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
