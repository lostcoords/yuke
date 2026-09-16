//! The native `yuke:exec` module: run one shell command and answer what it printed.
//!
//! A command has a real duration, so it always runs on its own task.
//! The owner continues to paint, and the task writes plain JSON text the owner turns into a result.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const os = @import("../host/operations.zig");
const process = @import("../host/process.zig");
const Job = @import("../host/jobs.zig").Job;
const pending = @import("../pending.zig");
const utf8 = @import("../../utf8.zig");

const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The command deadline. A caller raises it up to `max_timeout_ms`.
pub const default_timeout_ms: u32 = 120_000;
pub const max_timeout_ms: u32 = 600_000;

/// The default and the largest cap for each stream. A command that prints more loses its middle, not its result.
pub const max_stream_bytes: u32 = 64 * 1024;

/// Register `yuke:exec` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:exec", &.{
        .{ .name = "exec", .arity = 2, .call = jsExec },
        .{ .name = "start", .arity = 2, .call = jsStart },
        .{ .name = "stop", .arity = 1, .call = jsStop },
    });
}

/// One command, copied so the task can read it after the call returns.
const Request = struct {
    const ParseError = error{ CommandType, CommandBlank, RootType, CwdType, Timeout, MaxBytes };

    command: []u8,
    root: []u8,
    cwd: ?[]u8,
    timeout_ms: u32,
    max_bytes: u32,
    /// Null unless the caller asked for a log. The owner makes the path, because only the owner touches `Host.logs`.
    log: ?[]u8 = null,

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
        const timeout_ms = integerOption(ctx, options, "timeoutMs", default_timeout_ms, max_timeout_ms) catch return error.Timeout;
        const max_bytes = integerOption(ctx, options, "maxBytes", max_stream_bytes, max_stream_bytes) catch return error.MaxBytes;

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
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    if (args.len == 0) return rejected(ctx, "exec needs a command");

    const options: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const signal = if (ctx.isObject(options)) ctx.getPropertyStr(options, "signal") else quickjs.UNDEFINED;
    defer ctx.freeValue(signal);
    if (ctx.isException(signal)) return rejected(ctx, "the exec signal could not be read");
    if (!ctx.isUndefined(signal) and !host.calls.acceptsSignal(ctx, signal))
        return rejected(ctx, "the exec signal does not belong to an active tool call");

    // The task cannot touch JavaScript, so every argument is copied before it starts.
    const wants_log = boolOption(ctx, options, "log") catch return rejected(ctx, "log must be a boolean");
    var request = Request.parse(ctx, host.gpa, args, options, host.cwd) catch |err| return rejected(ctx, parseMessage(err));
    // A log directory that cannot exist costs the log, not the command.
    if (wants_log) request.log = host.logs.next(host.gpa, host.io, host.execution.env, "exec") catch null;
    return host.startTaskWithSignal(Request, execTask, request, signal);
}

fn parseMessage(err: Request.ParseError) []const u8 {
    return switch (err) {
        error.CommandType => "the command must be a string",
        error.CommandBlank => "the command must not be blank",
        error.RootType => "the workspace root must be a string",
        error.CwdType => "cwd must be a string",
        error.Timeout => "timeoutMs must be a whole number of milliseconds up to 600000",
        error.MaxBytes => "maxBytes must be a whole number of bytes up to 65536",
    };
}

/// Start one background job and answer `{ id, log, exited }`. `exited` resolves once with `{ code, signal }`.
fn jsStart(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    if (args.len == 0) return rejected(ctx, "start needs a command");
    const options: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const request = Request.parse(ctx, host.gpa, args, options, host.cwd) catch |err| return rejected(ctx, parseMessage(err));
    defer request.free(host.gpa);
    if (!host.jobs.prune(host.gpa)) return rejected(ctx, "the host already runs 16 jobs, so stop one first");

    // The handle exists before the spawn, so a full QuickJS heap never strands a running job.
    const started = host.ops.start(ctx) orelse return ctx.throw(ctx.getException());
    const handle = ctx.newObject();
    if (ctx.isException(handle)) {
        ctx.freeValue(started.promise);
        started.op.finish(.undefined);
        return rejected(ctx, "the host has no memory for the job handle");
    }
    ctx.setPropertyStr(handle, "exited", started.promise) catch {};

    const log = host.logs.next(host.gpa, host.io, host.execution.env, "job") catch {
        ctx.freeValue(handle);
        started.op.finish(.undefined);
        return rejected(ctx, "the host could not create the log directory");
    };
    defer host.gpa.free(log);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    const child = process.startJob(host.io, request.root, host.execution, arena.allocator(), request.command, request.cwd, log) catch |err| {
        ctx.freeValue(handle);
        started.op.finish(.undefined);
        return rejected(ctx, errorMessage(err));
    };
    const job = host.jobs.add(host.gpa, child);
    host.tasks.concurrent(host.io, jobTask, .{ host, started.op, job }) catch {
        // No waiter can run, so the owner ends and reaps the job itself.
        process.endGroups(host.io, &.{job.pid});
        _ = process.reapGroup(host.io, &job.child);
        job.done.store(true, .monotonic);
        ctx.freeValue(handle);
        started.op.finish(.undefined);
        return rejected(ctx, "the host cannot start another operation");
    };
    ctx.setPropertyStr(handle, "id", ctx.newInt32(@intCast(job.id))) catch {};
    ctx.setPropertyStr(handle, "log", ctx.newString(log)) catch {};
    return pending.resolved(ctx, handle);
}

/// Reap one job and answer its exit. The job is done before the op finishes, so the owner can free it at any later point.
fn jobTask(host: *Host, op: *pending.Op, job: *Job) void {
    const outcome = process.reapGroup(host.io, &job.child);
    job.done.store(true, .monotonic);
    const result: pending.Result = if (outcome) |o| .{
        .json = switch (o) {
            .exited => |code| std.fmt.allocPrintSentinel(host.gpa, "{{\"code\":{d},\"signal\":null}}", .{code}, 0),
            .signaled => |sig| std.fmt.allocPrintSentinel(host.gpa, "{{\"code\":null,\"signal\":{d}}}", .{sig}, 0),
            .timed_out => unreachable, // A job has no deadline.
        } catch unreachable,
    } else .{ .failed = .{ .message = "the host could not reap the job" } };
    op.finish(result);
}

/// The pid a stop task ends. It owns nothing.
const Stop = struct {
    pid: std.posix.pid_t,

    pub fn free(_: Stop, _: std.mem.Allocator) void {}
};

/// Stop one job with TERM, then KILL after the grace period. It resolves true when the job was running and false when it had ended.
fn jsStop(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    const id = if (args.len > 0) module.integer(ctx, args[0], 1, std.math.maxInt(u32)) else null;
    const job = host.jobs.find(@intCast(id orelse return rejected(ctx, "the job id must be a positive whole number"))) orelse
        return pending.resolved(ctx, ctx.newBool(false));
    return host.startTaskWithSignal(Stop, stopTask, .{ .pid = job.pid }, quickjs.UNDEFINED);
}

fn stopTask(host: *Host, op: *pending.Op, stop: Stop) void {
    process.endGroups(host.io, &.{stop.pid});
    op.finish(.{ .boolean = true });
}

const canceled: pending.Result = .{ .failed = .{ .message = "the command was canceled" } };

/// Run the command in a child, so a call abort cancels it. Every child path writes `result` before the op finishes.
fn execTask(host: *Host, op: *pending.Op, req: Request) void {
    defer req.free(host.gpa);
    std.debug.assert(op.result == null);
    if (op.cancel.requested) return op.finish(canceled);
    var result: pending.Result = canceled;
    switch (op.cancel.runChild(host.io, execWorker, .{ host, op, req, &result })) {
        .returned => |started| started catch return op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } }),
        .canceled, .aborted => {},
    }
    op.finish(result);
}

/// The worker touches no QuickJS values and signals its supervisor before return.
fn execWorker(host: *Host, op: *pending.Op, req: Request, result: *pending.Result) error{}!void {
    defer op.cancel.finish(host.io);
    host.io.checkCancel() catch return;
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    const ran = process.run(host.io, req.root, host.execution, arena.allocator(), .{
        .command = req.command,
        .cwd = req.cwd,
        .timeout_ms = req.timeout_ms,
        .max_stream_bytes = req.max_bytes,
        .log = req.log,
    }) catch |err| {
        result.* = .{ .failed = .{ .message = errorMessage(err) } };
        return;
    };
    result.* = .{ .json = encode(host.gpa, arena.allocator(), ran) };
}

/// Build the result text. A command prints any bytes, so each stream becomes valid UTF-8 first.
fn encode(gpa: std.mem.Allocator, scratch: std.mem.Allocator, r: process.Result) [:0]u8 {
    const stdout = utf8.sanitize(scratch, r.stdout) catch unreachable;
    const stderr = utf8.sanitize(scratch, r.stderr) catch unreachable;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    write(&aw.writer, stdout, stderr, r) catch unreachable;
    var list = aw.toArrayList();
    // QuickJS reads the JSON text to the sentinel, so the buffer must carry one.
    return list.toOwnedSliceSentinel(gpa, 0) catch unreachable;
}

/// Write one result. `code` and `signal` are null for each outcome that did not produce them.
fn write(w: *std.Io.Writer, stdout: []const u8, stderr: []const u8, r: process.Result) std.Io.Writer.Error!void {
    try w.writeAll("{\"stdout\":");
    try std.json.Stringify.encodeJsonString(stdout, .{}, w);
    try w.writeAll(",\"stderr\":");
    try std.json.Stringify.encodeJsonString(stderr, .{}, w);
    switch (r.outcome) {
        .exited => |code| try w.print(",\"code\":{d},\"signal\":null,\"timedOut\":false", .{code}),
        .signaled => |sig| try w.print(",\"code\":null,\"signal\":{d},\"timedOut\":false", .{sig}),
        .timed_out => try w.writeAll(",\"code\":null,\"signal\":null,\"timedOut\":true"),
    }
    try w.print(",\"stdoutDropped\":{d},\"stderrDropped\":{d},\"log\":", .{ r.stdout_dropped, r.stderr_dropped });
    if (r.log) |path| try std.json.Stringify.encodeJsonString(path, .{}, w) else try w.writeAll("null");
    try w.writeAll("}");
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

/// Read a whole-number option from 1 to `max`, or answer `default`. A fraction fails rather than truncates.
fn integerOption(ctx: Context, options: Value, name: [:0]const u8, default: u32, max: u32) error{InvalidOption}!u32 {
    if (!ctx.isObject(options)) return default;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return default;
    return @intCast(module.integer(ctx, value, 1, max) orelse return error.InvalidOption);
}

/// Read a boolean option. An absent option is false.
fn boolOption(ctx: Context, options: Value, name: [:0]const u8) error{InvalidOption}!bool {
    if (!ctx.isObject(options)) return false;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return false;
    if (!ctx.isBool(value)) return error.InvalidOption;
    return ctx.toBool(value) catch error.InvalidOption;
}

const testing = std.testing;

fn encoded(a: std.mem.Allocator, r: process.Result) ![]const u8 {
    return encode(a, a, r);
}

test "the result names the outcome that happened and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "{\"stdout\":\"out\\n\",\"stderr\":\"\",\"code\":3,\"signal\":null,\"timedOut\":false," ++
            "\"stdoutDropped\":0,\"stderrDropped\":0,\"log\":null}",
        try encoded(a, .{ .stdout = "out\n", .stderr = "", .outcome = .{ .exited = 3 } }),
    );
    // A signal and a deadline leave `code` null, so a caller never reads a made-up zero.
    try testing.expectEqualStrings(
        "{\"stdout\":\"\",\"stderr\":\"\",\"code\":null,\"signal\":9,\"timedOut\":false," ++
            "\"stdoutDropped\":0,\"stderrDropped\":0,\"log\":null}",
        try encoded(a, .{ .stdout = "", .stderr = "", .outcome = .{ .signaled = 9 } }),
    );
    try testing.expectEqualStrings(
        "{\"stdout\":\"\",\"stderr\":\"\",\"code\":null,\"signal\":null,\"timedOut\":true," ++
            "\"stdoutDropped\":0,\"stderrDropped\":0,\"log\":null}",
        try encoded(a, .{ .stdout = "", .stderr = "", .outcome = .timed_out }),
    );
    try testing.expectEqualStrings(
        "{\"stdout\":\"head\",\"stderr\":\"tail\",\"code\":0,\"signal\":null,\"timedOut\":false," ++
            "\"stdoutDropped\":12,\"stderrDropped\":34,\"log\":null}",
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
