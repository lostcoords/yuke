//! The native `yuke:jobs-native` module: the background job table that the tools, the TUI, and RPC share.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const process = @import("process.zig");
const runner = @import("../host/process.zig");
const LocalHost = @import("../host/local.zig").LocalHost;

const Context = quickjs.Context;
const Value = quickjs.Value;
const rejected = pending.rejected;
const SessionId = proto.ids.SessionId;

/// The most ended jobs the table keeps. The job that ended first leaves first.
pub const max_ended = 32;
/// The largest job read, so one read keeps the owner loop short.
pub const max_read_bytes: u32 = 256 * 1024;

pub const State = enum { running, exited, stopped };

/// One job. The table owns every string, and a record outlives its process.
pub const Job = struct {
    id: u32,
    session_id: ?SessionId,
    command: []u8,
    cwd: []u8,
    log: []u8,
    state: State = .running,
    /// A stop reached the live child, so its end reads as `stopped`.
    stopping: bool = false,
    code: ?u8 = null,
    signal: ?u8 = null,
    started_at_ms: i64,
    ended_at_ms: ?i64 = null,
    /// The end order, so the prune keeps the jobs that ended last.
    end_seq: u64 = 0,
    /// The live process id, or null after the end.
    proc: ?u32,
};

pub const Jobs = struct {
    /// Start order.
    list: std.ArrayList(*Job) = .empty,
    last_id: u32 = 0,
    last_end: u64 = 0,

    pub fn find(self: *const Jobs, id: u32) ?*Job {
        for (self.list.items) |job| if (job.id == id) return job;
        return null;
    }

    /// Record the end of a job. The process settle calls this on the owner, after the log holds its exit line.
    pub fn end(self: *Jobs, host: *Host, job: *Job, outcome: ?runner.Outcome) void {
        std.debug.assert(job.state == .running and job.proc != null);
        job.state = if (job.stopping) .stopped else .exited;
        if (outcome) |o| switch (o) {
            .exited => |c| job.code = c,
            .signaled => |s| job.signal = s,
            .timed_out => unreachable, // A job has no deadline.
        };
        job.ended_at_ms = nowMs(host.io);
        self.last_end += 1;
        job.end_seq = self.last_end;
        job.proc = null;
        self.prune(host.gpa);
        std.debug.assert(self.find(job.id) == job);
    }

    fn prune(self: *Jobs, gpa: std.mem.Allocator) void {
        var ended: usize = 0;
        for (self.list.items) |job| ended += @intFromBool(job.state != .running);
        while (ended > max_ended) : (ended -= 1) {
            var oldest: usize = 0;
            var seq: u64 = std.math.maxInt(u64);
            for (self.list.items, 0..) |job, i| if (job.state != .running and job.end_seq < seq) {
                oldest = i;
                seq = job.end_seq;
            };
            free(gpa, self.list.orderedRemove(oldest));
        }
    }

    /// Free every record. `Host.close` ends and frees every process first, so no process points at a record.
    pub fn deinit(self: *Jobs, gpa: std.mem.Allocator) void {
        for (self.list.items) |job| free(gpa, job);
        self.list.deinit(gpa);
        self.* = .{};
    }
};

fn free(gpa: std.mem.Allocator, job: *Job) void {
    gpa.free(job.command);
    gpa.free(job.cwd);
    gpa.free(job.log);
    gpa.destroy(job);
}

fn nowMs(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
}

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:jobs-native", &.{
        .{ .name = "start", .arity = 3, .call = jsStart },
        .{ .name = "list", .arity = 0, .call = jsList },
        .{ .name = "get", .arity = 1, .call = jsGet },
        .{ .name = "stop", .arity = 1, .call = jsStop },
        .{ .name = "read", .arity = 3, .call = jsRead },
    });
}

/// Build the JavaScript view of a job. Each call builds a new object, so a caller never edits the table.
pub fn toValue(ctx: Context, job: *const Job) Value {
    const obj = ctx.newObject();
    module.set(ctx, obj, "id", ctx.newInt32(@intCast(job.id)));
    module.set(ctx, obj, "sessionId", if (job.session_id) |id| ctx.newString(&std.fmt.bytesToHex(id.raw, .lower)) else quickjs.NULL);
    module.set(ctx, obj, "command", ctx.newString(job.command));
    module.set(ctx, obj, "cwd", ctx.newString(job.cwd));
    module.set(ctx, obj, "log", ctx.newString(job.log));
    module.set(ctx, obj, "state", ctx.newString(@tagName(job.state)));
    module.set(ctx, obj, "code", if (job.code) |c| ctx.newInt32(c) else quickjs.NULL);
    module.set(ctx, obj, "signal", if (job.signal) |s| ctx.newInt32(s) else quickjs.NULL);
    module.set(ctx, obj, "startedAt", ctx.newFloat64(@floatFromInt(job.started_at_ms)));
    module.set(ctx, obj, "endedAt", if (job.ended_at_ms) |ms| ctx.newFloat64(@floatFromInt(ms)) else quickjs.NULL);
    return obj;
}

/// Start a shell line as a job with both streams on a private log. It resolves `{ job, ended }`, and `ended` resolves with the final job.
fn jsStart(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const command = if (args.len > 0) module.owned(ctx, a, args[0]) else null;
    if (command == null or std.mem.trim(u8, command.?, " \t\r\n").len == 0) return rejected(ctx, "the command must be a non-blank string");
    if (std.mem.indexOfScalar(u8, command.?, 0) != null) return rejected(ctx, "the command must not hold a NUL byte");
    const session_value: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    var session_id: ?SessionId = null;
    if (!ctx.isUndefined(session_value) and !ctx.isNull(session_value)) {
        const text = module.owned(ctx, a, session_value) orelse "";
        if (!SessionId.validText(text)) return rejected(ctx, "the session id must be 32 lowercase hex digits");
        var raw: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, text) catch unreachable;
        session_id = .bytes(raw);
    }
    const root = module.rootArg(ctx, a, if (args.len > 2) args[2] else quickjs.UNDEFINED, host.cwd) orelse
        return rejected(ctx, "the workspace root must be an absolute path");
    if (host.procs.live.items.len >= process.max_processes) return rejected(ctx, "the host runs 64 processes");

    // A job writes to a file, and Python buffers a file in blocks, so the variable keeps its output live.
    var env = host.execution.env.clone(a) catch unreachable;
    env.put("PYTHONUNBUFFERED", "1") catch unreachable;
    const log = host.logs.next(host.gpa, host.io, host.execution.env, "job") catch return rejected(ctx, "the host could not create the log directory");
    const argv: []const []const u8 = &.{ host.execution.shell.path, "-c", command.? };
    const program = runner.startProgram(host.io, root, &env, a, argv, null, .{ .log = log }) catch |err| {
        host.gpa.free(log);
        return rejected(ctx, process.startMessage(err));
    };

    var funcs: [2]Value = undefined;
    const ended = ctx.newPromiseCapability(&funcs);
    const jobs = &host.jobs;
    jobs.last_id += 1;
    const job = host.gpa.create(Job) catch unreachable;
    job.* = .{
        .id = jobs.last_id,
        .session_id = session_id,
        .command = host.gpa.dupe(u8, command.?) catch unreachable,
        .cwd = host.gpa.dupe(u8, root) catch unreachable,
        .log = host.gpa.dupe(u8, log) catch unreachable,
        .started_at_ms = nowMs(host.io),
        .proc = null,
    };
    jobs.list.append(host.gpa, job) catch unreachable;
    job.proc = process.launch(host, program, quickjs.UNDEFINED, funcs, log, job).id;

    const result = ctx.newObject();
    module.set(ctx, result, "job", toValue(ctx, job));
    module.set(ctx, result, "ended", ended);
    return pending.resolved(ctx, result);
}

/// Answer every job, newest first.
fn jsList(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    const out = ctx.newArray();
    const items = host.jobs.list.items;
    for (items, 0..) |_, i| ctx.setPropertyUint32(out, @intCast(i), toValue(ctx, items[items.len - 1 - i])) catch {};
    return out;
}

fn jsGet(ctx: Context, _: Value, args: []const Value) Value {
    const job = jobOf(ctx, args) orelse return quickjs.NULL;
    return toValue(ctx, job);
}

/// Stop a running job and answer its record as it is now. The end arrives through `ended`, and a job reaped before the stop keeps its real exit.
fn jsStop(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const job = jobOf(ctx, args) orelse return quickjs.NULL;
    if (host.phase == .open and job.state == .running and !job.stopping and process.kill(host, job.proc.?)) job.stopping = true;
    return toValue(ctx, job);
}

/// One job log read, copied so the task can read it after the call returns.
const Read = struct {
    log: []u8,
    offset: u64,
    max_bytes: u32,

    pub fn free(self: Read, gpa: std.mem.Allocator) void {
        gpa.free(self.log);
    }
};

/// Read job output from a byte offset. It answers `{ text, next, size }`, so a caller follows a growing log.
fn jsRead(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    const job = jobOf(ctx, args) orelse return rejected(ctx, "the job does not exist");
    const offset = if (args.len > 1) module.integer(ctx, args[1], 0, (1 << 53) - 1) else null;
    const max_bytes = if (args.len > 2) module.integer(ctx, args[2], 1, max_read_bytes) else null;
    if (offset == null or max_bytes == null) return rejected(ctx, "read needs a byte offset and a byte count from 1 to 262144");
    return host.startTask(Read, readTask, .{ .log = host.gpa.dupe(u8, job.log) catch unreachable, .offset = offset.?, .max_bytes = @intCast(max_bytes.?) });
}

fn readTask(host: *Host, op: *pending.Op, req: Read) void {
    defer req.free(host.gpa);
    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var local: LocalHost = .{ .io = host.io, .root = "/", .env = host.execution.env };
    const got = local.readFrom(arena.allocator(), req.log, req.offset, req.max_bytes) catch
        return op.finish(.{ .failed = .{ .message = "the host could not read the job log" } });
    var aw: std.Io.Writer.Allocating = .init(host.gpa);
    std.json.Stringify.value(got, .{}, &aw.writer) catch unreachable;
    var list = aw.toArrayList();
    op.finish(.{ .json = list.toOwnedSliceSentinel(host.gpa, 0) catch unreachable });
}

fn jobOf(ctx: Context, args: []const Value) ?*Job {
    if (args.len == 0) return null;
    const id = module.integer(ctx, args[0], 1, std.math.maxInt(u32)) orelse return null;
    return Host.fromContext(ctx).jobs.find(@intCast(id));
}

const testing = std.testing;

test "the prune keeps the jobs that ended last, whatever their start order" {
    var jobs: Jobs = .{};
    defer jobs.deinit(testing.allocator);
    // Job 1 starts first and ends last, so it must stay while the jobs that ended before it leave.
    for (1..max_ended + 3) |i| {
        const job = try testing.allocator.create(Job);
        job.* = .{ .id = @intCast(i), .session_id = null, .command = try testing.allocator.dupe(u8, "c"), .cwd = try testing.allocator.dupe(u8, "/"), .log = try testing.allocator.dupe(u8, "/l"), .started_at_ms = 0, .proc = null, .state = .exited, .end_seq = if (i == 1) max_ended + 3 else i };
        try jobs.list.append(testing.allocator, job);
    }
    jobs.prune(testing.allocator);
    try testing.expectEqual(@as(usize, max_ended), jobs.list.items.len);
    try testing.expect(jobs.find(1) != null);
    try testing.expect(jobs.find(2) == null and jobs.find(3) == null);
}
