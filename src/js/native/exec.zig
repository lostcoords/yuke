//! The native `yuke:internal/native/exec` module runs one shell command on its own task and answers what it printed as JSON.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const os = @import("../host/operations.zig");
const process = @import("../host/process.zig");
const pending = @import("../pending.zig");
const utf8 = @import("../../utf8.zig");

const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The command deadline. A caller raises it up to `max_timeout_ms`.
const default_timeout_ms: u32 = 120_000;
const max_timeout_ms: u32 = 600_000;

/// The default and the largest cap for each stream. A command that prints more loses its middle, not its result.
const max_stream_bytes: u32 = 64 * 1024;

/// Register `yuke:internal/native/exec` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:internal/native/exec", &.{
        .{ .name = "exec", .arity = 2, .call = jsExec },
    });
}

/// One command, copied so the task can read it after the call returns.
const Request = struct {
    const ParseError = error{ CommandType, CommandBlank, CommandNul, RootType, CwdType, Timeout, MaxBytes };

    command: []u8,
    root: []u8,
    cwd: ?[]u8,
    timeout_ms: u32,
    max_bytes: u32,
    /// Null unless the caller asked for a log. The owner makes the path, because only the owner touches `Host.logs`.
    log: ?[]u8 = null,
    /// True when the caller passed `onOutput`, so each chunk reaches the op as live text.
    live: bool = false,

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
        if (std.mem.indexOfScalar(u8, command, 0) != null) return error.CommandNul;

        const root = module.rootOption(ctx, gpa, options, default_root) orelse return error.RootType;
        errdefer gpa.free(root);

        const cwd = module.optionalString(ctx, gpa, options, "cwd") catch return error.CwdType;
        errdefer if (cwd) |dir| gpa.free(dir);
        const timeout_ms = (module.optionalInteger(ctx, options, "timeoutMs", default_timeout_ms, max_timeout_ms) catch return error.Timeout).?;
        const max_bytes = (module.optionalInteger(ctx, options, "maxBytes", max_stream_bytes, max_stream_bytes) catch return error.MaxBytes).?;

        return .{ .command = command, .root = root, .cwd = cwd, .timeout_ms = timeout_ms, .max_bytes = max_bytes };
    }

    pub fn free(self: Request, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
        gpa.free(self.root);
        if (self.cwd) |dir| gpa.free(dir);
        if (self.log) |path| gpa.free(path);
    }
};

/// Run one shell command. A refused argument rejects, so a caller reads one failure shape.
fn jsExec(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return rejected(ctx, "the host is closed");
    if (args.len == 0) return rejected(ctx, "exec needs a command");

    const options: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const signal = if (ctx.isObject(options)) ctx.getPropertyStr(options, "signal") else quickjs.UNDEFINED;
    defer ctx.freeValue(signal);
    if (ctx.isException(signal)) return rejected(ctx, "the exec signal could not be read");
    const on_output = if (ctx.isObject(options)) ctx.getPropertyStr(options, "onOutput") else quickjs.UNDEFINED;
    defer ctx.freeValue(on_output);
    if (!ctx.isUndefined(on_output) and !ctx.isFunction(on_output)) return rejected(ctx, "onOutput must be a function");

    // The task cannot touch JavaScript, so every argument is copied before it starts.
    const log = if (ctx.isObject(options)) ctx.getPropertyStr(options, "log") else quickjs.UNDEFINED;
    defer ctx.freeValue(log);
    if (!ctx.isUndefined(log) and !ctx.isNull(log) and !ctx.isBool(log)) return rejected(ctx, "log must be a boolean");
    const wants_log = ctx.isBool(log) and (ctx.toBool(log) catch unreachable); // `isBool` holds, so the conversion cannot fail.
    var request = Request.parse(ctx, host.gpa, args, options, host.cwd) catch |err|
        return rejected(ctx, switch (err) {
            error.CommandType => "the command must be a string",
            error.CommandBlank => "the command must not be blank",
            error.CommandNul => "the command must not hold a NUL byte",
            error.RootType => "the workspace root must be an absolute path",
            error.CwdType => "cwd must be a string",
            error.Timeout => "timeoutMs must be a whole number of milliseconds up to 600000",
            error.MaxBytes => "maxBytes must be a whole number of bytes up to 65536",
        });
    // A log directory that cannot exist costs the log, not the command.
    if (wants_log) request.log = host.logs.next(host.gpa, host.io, host.execution.env, "exec") catch null;
    request.live = !ctx.isUndefined(on_output);
    return host.startTask(Request, execTask, request, .{ .signal = signal, .on_text = on_output });
}

const canceled: pending.Result = .{ .failed = .{ .message = "the command was canceled", .code = "CANCELED" } };

/// Run the command in a child, so a call abort cancels it. Every child path writes `result` before the op finishes.
fn execTask(host: *Host, op: *pending.Op, req: Request) void {
    defer req.free(host.gpa);
    std.debug.assert(op.result == null);
    if (op.cancel.isRequested()) return op.finish(canceled);
    var result: pending.Result = canceled;
    switch (op.cancel.runChild(host.io, execWorker, .{ host, op, req, &result })) {
        .returned => |started| started catch return op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } }),
        .canceled, .aborted => {},
    }
    op.finish(result);
}

/// The worker touches no QuickJS values and signals its supervisor before return.
fn execWorker(host: *Host, op: *pending.Op, req: Request, result: *pending.Result) error{}!void {
    host.io.checkCancel() catch return;
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    const ran = process.run(host.io, req.root, host.execution, arena.allocator(), .{
        .command = req.command,
        .cwd = req.cwd,
        .timeout_ms = req.timeout_ms,
        .max_stream_bytes = req.max_bytes,
        .log = req.log,
        .live = if (req.live) .{ .ctx = op, .write = liveWrite } else null,
    }) catch |err| {
        arena.deinit();
        result.* = if (err == error.Canceled) canceled else .{ .failed = .{ .message = errorMessage(err) } };
        return;
    };
    const answer = arena.allocator().create(Answer) catch unreachable;
    answer.* = .of(arena.allocator(), ran);
    // The owner builds the object from the arena, so no JSON text sits between the task and the script.
    result.* = .{ .object = .init(arena, answer) };
}

fn liveWrite(ctx: *anyopaque, bytes: []const u8) void {
    const op: *pending.Op = @ptrCast(@alignCast(ctx));
    op.stream(bytes);
}

/// The object a script reads. `code` and `signal` are null unless that outcome happened.
const Answer = struct {
    stdout: []const u8,
    stderr: []const u8,
    code: ?u8,
    signal: ?u8,
    timed_out: bool,
    stdout_dropped: u64,
    stderr_dropped: u64,
    log: ?[]const u8,

    /// A command prints any bytes, so each stream becomes valid UTF-8 in `scratch` first.
    fn of(scratch: std.mem.Allocator, r: process.Result) Answer {
        return .{
            .stdout = if (std.unicode.utf8ValidateSlice(r.stdout)) r.stdout else utf8.sanitize(scratch, r.stdout) catch unreachable,
            .stderr = if (std.unicode.utf8ValidateSlice(r.stderr)) r.stderr else utf8.sanitize(scratch, r.stderr) catch unreachable,
            .code = if (r.outcome == .exited) r.outcome.exited else null,
            .signal = if (r.outcome == .signaled) r.outcome.signaled else null,
            .timed_out = r.outcome == .timed_out,
            .stdout_dropped = r.stdout_dropped,
            .stderr_dropped = r.stderr_dropped,
            .log = r.log,
        };
    }
};

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

const testing = std.testing;

test "the answer names the outcome that happened and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const exited: Answer = .of(a, .{ .stdout = "out\n", .stderr = "", .outcome = .{ .exited = 3 }, .stdout_dropped = 12, .stderr_dropped = 34 });
    try testing.expectEqual(@as(?u8, 3), exited.code);
    try testing.expectEqual(@as(?u8, null), exited.signal);
    try testing.expect(!exited.timed_out);
    try testing.expectEqual(@as(u64, 12), exited.stdout_dropped);
    try testing.expectEqual(@as(u64, 34), exited.stderr_dropped);
    // A signal and a deadline leave `code` null, so a caller never reads a made-up zero.
    const signaled: Answer = .of(a, .{ .stdout = "", .stderr = "", .outcome = .{ .signaled = 9 } });
    try testing.expectEqual(@as(?u8, null), signaled.code);
    try testing.expectEqual(@as(?u8, 9), signaled.signal);
    const timed_out: Answer = .of(a, .{ .stdout = "", .stderr = "", .outcome = .timed_out });
    try testing.expectEqual(@as(?u8, null), timed_out.code);
    try testing.expectEqual(@as(?u8, null), timed_out.signal);
    try testing.expect(timed_out.timed_out);
}

// A command prints any bytes, but a script reads valid text with its control bytes kept.
test "the answer holds valid text whatever the command printed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const answer: Answer = .of(a, .{ .stdout = "ok\xe6\x96", .stderr = "\x00\x01", .outcome = .{ .exited = 0 } });
    try testing.expectEqualStrings("ok\u{FFFD}\u{FFFD}", answer.stdout);
    try testing.expectEqualStrings("\x00\x01", answer.stderr);
}
