//! The native `yuke:process` module: child processes whose output tasks read and the owner delivers in `Host.pump`.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const runner = @import("../host/process.zig");
const utf8 = @import("../../utf8.zig");
const Job = @import("jobs.zig").Job;

const Context = quickjs.Context;
const Value = quickjs.Value;
const rejected = pending.rejected;

/// The most live children. A spawn past the limit throws `RangeError`.
pub const max_processes = 64;
/// The most bytes one stream buffers before its reader waits for the owner. The child then blocks on a full pipe.
pub const max_buffered_bytes = 1024 * 1024;
pub const max_write_bytes = 1024 * 1024;
pub const max_writes = 1024;

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:process", &.{
        .{ .name = "spawn", .arity = 4, .call = jsSpawn },
        .{ .name = "write", .arity = 2, .call = jsWrite },
        .{ .name = "closeStdin", .arity = 1, .call = jsCloseStdin },
        .{ .name = "kill", .arity = 1, .call = jsKill },
    });
}

/// One output stream. The reader and the owner share `buffer` and `ended` under `lock`.
const Stream = struct {
    file: ?std.Io.File,
    lock: std.Io.Mutex = .init,
    buffer: std.ArrayList(u8) = .empty,
    /// Only the owner touches this buffer until it swaps it with `buffer` under `lock`.
    spare: std.ArrayList(u8) = .empty,
    /// The reader sets this last, at EOF, at a read error, or at a cancel.
    ended: bool,
    /// A reader sets this after it appends or ends, so `hasWork` needs no lock.
    ready: std.atomic.Value(bool) = .init(false),
    /// The owner sets this after it takes the buffer, so a reader that waits for space resumes.
    space: std.Io.Event = .unset,
    /// Owner only: the stream ended and the owner delivered its last byte.
    finished: bool = false,
};

/// One queued stdin write and the op that settles its promise.
const Write = struct { bytes: []u8, op: *pending.Op };

const Proc = struct {
    id: u32,
    pid: std.posix.pid_t,
    child: std.process.Child,
    streams: [2]Stream,
    /// The output callback, or undefined for a job. It and the `exited` resolvers are roots until the owner frees the process.
    on_output: Value,
    resolve: Value,
    reject: Value,
    /// The job record of a job child. The settle ends it, and `exited` resolves with it.
    job: ?*Job,
    /// Guards the input queue, its byte count, and the input descriptor.
    writes_lock: std.Io.Mutex = .init,
    writes: std.Deque(Write) = .empty,
    write_bytes: usize = 0,
    stdin: ?std.posix.fd_t,
    writing: bool = false,
    close_after: bool = false,
    /// The reaper publishes `outcome` through `reaped`; the supervisor publishes stream completion through `done`.
    outcome: ?runner.Outcome = null,
    reaped: std.atomic.Value(bool) = .init(false),
    stop_requested: std.atomic.Value(bool) = .init(false),
    changed: std.Io.Event = .unset,
    done: std.atomic.Value(bool) = .init(false),
    /// Owner only.
    settled: bool = false,
};

pub const Procs = struct {
    live: std.ArrayList(*Proc) = .empty,
    last_id: u32 = 0,

    /// Answer whether a drain has work: new output, an end, or an exit to settle.
    pub fn hasWork(self: *const Procs) bool {
        for (self.live.items) |proc| {
            if (proc.streams[0].ready.load(.acquire) or proc.streams[1].ready.load(.acquire)) return true;
            if (!proc.settled and proc.done.load(.acquire)) return true;
        }
        return false;
    }

    fn find(self: *const Procs, id: u32) ?*Proc {
        for (self.live.items) |proc| if (proc.id == id) return proc;
        return null;
    }

    /// Deliver output, settle `exited` after the last byte, and free a process with no work left. Answer whether a callback threw.
    pub fn drain(self: *Procs, host: *Host) bool {
        std.debug.assert(host.phase == .open);
        var faulted = false;
        var i: usize = 0;
        // A callback can spawn another process, so the loop reads the length again.
        while (i < self.live.items.len) {
            const proc = self.live.items[i];
            for (&proc.streams, 1..) |*stream, number| {
                if (stream.ready.swap(false, .acquire) and deliver(host, proc, stream, @intCast(number))) faulted = true;
            }
            if (!proc.settled and proc.done.load(.acquire) and proc.streams[0].finished and proc.streams[1].finished) {
                proc.settled = true;
                if (settle(host, proc)) faulted = true;
            }
            if (proc.settled and idle(host.io, proc)) {
                _ = self.live.orderedRemove(i);
                free(host, proc);
                continue;
            }
            i += 1;
        }
        return faulted;
    }

    /// Request every stop before the host joins its tasks, so all grace periods overlap.
    pub fn stopAll(self: *Procs, io: std.Io) void {
        std.debug.assert(self.live.items.len <= max_processes);
        for (self.live.items) |proc| _ = requestStop(io, proc);
    }

    /// Free every process. Every task has returned, so no task holds a pointer.
    pub fn deinit(self: *Procs, host: *Host) void {
        for (self.live.items) |proc| {
            std.debug.assert(proc.done.load(.acquire) and !proc.writing);
            free(host, proc);
        }
        self.live.deinit(host.gpa);
        self.* = .{};
    }
};

fn idle(io: std.Io, proc: *Proc) bool {
    proc.writes_lock.lockUncancelable(io);
    defer proc.writes_lock.unlock(io);
    return !proc.writing and proc.writes.len == 0;
}

fn free(host: *Host, proc: *Proc) void {
    host.ctx.freeValue(proc.on_output);
    host.ctx.freeValue(proc.resolve);
    host.ctx.freeValue(proc.reject);
    if (proc.stdin) |fd| _ = std.posix.system.close(fd);
    // `Ops.deinit` frees the op of a write that a close canceled.
    while (proc.writes.popFront()) |w| host.gpa.free(w.bytes);
    proc.writes.deinit(host.gpa);
    for (&proc.streams) |*stream| {
        stream.buffer.deinit(host.gpa);
        stream.spare.deinit(host.gpa);
    }
    host.gpa.destroy(proc);
}

/// Take the buffered bytes that end on a character boundary and hand them to the callback. The cut character stays for the next read.
fn deliver(host: *Host, proc: *Proc, stream: *Stream, number: i32) bool {
    stream.lock.lockUncancelable(host.io);
    var taken = stream.buffer;
    stream.buffer = stream.spare;
    stream.spare = .empty;
    const cut = if (stream.ended) taken.items.len else utf8.whole(taken.items);
    stream.buffer.appendSlice(host.gpa, taken.items[cut..]) catch unreachable;
    const finished = stream.ended and stream.buffer.items.len == 0;
    stream.lock.unlock(host.io);
    stream.space.set(host.io);
    defer {
        taken.clearRetainingCapacity();
        stream.spare = taken;
    }

    stream.finished = finished;
    if (cut == 0) return false;
    const ctx = host.ctx;
    const bytes = taken.items[0..cut];
    const invalid = !std.unicode.utf8ValidateSlice(bytes);
    const text = if (invalid) utf8.sanitize(host.gpa, bytes) catch unreachable else bytes;
    defer if (invalid) host.gpa.free(text);
    host.enterSlice();
    var argv = [_]Value{ ctx.newInt32(number), ctx.newString(text) };
    defer for (argv) |arg| ctx.freeValue(arg);
    return call(host, proc.on_output, &argv);
}

/// Resolve `exited` with `{ code, signal }`, where exactly one of the two is null. A job resolves with its ended record instead.
fn settle(host: *Host, proc: *Proc) bool {
    const ctx = host.ctx;
    var argv = [_]Value{undefined};
    defer ctx.freeValue(argv[0]);
    if (proc.job) |job| {
        host.jobs.end(host, job, proc.outcome);
        argv[0] = @import("jobs.zig").toValue(ctx, job);
        return call(host, proc.resolve, &argv);
    }
    const outcome = proc.outcome orelse {
        argv[0] = ctx.newString("the host could not reap the process");
        return call(host, proc.reject, &argv);
    };
    argv[0] = ctx.newObject();
    const code: Value, const signal: Value = switch (outcome) {
        .exited => |c| .{ ctx.newInt32(c), quickjs.NULL },
        .signaled => |s| .{ quickjs.NULL, ctx.newInt32(s) },
        .timed_out => unreachable, // A process has no deadline.
    };
    module.set(ctx, argv[0], "code", code);
    module.set(ctx, argv[0], "signal", signal);
    return call(host, proc.resolve, &argv);
}

/// Call `function` and answer whether it threw.
fn call(host: *Host, function: Value, argv: []Value) bool {
    const answer = host.ctx.call(function, quickjs.UNDEFINED, argv);
    defer host.ctx.freeValue(answer);
    if (!host.ctx.isException(answer)) return false;
    host.noteFault();
    return true;
}

/// Read one stream until its end. A full buffer makes the reader wait, so the child blocks on the pipe and memory stays bounded.
fn readTask(host: *Host, stream: *Stream) void {
    defer {
        stream.lock.lockUncancelable(host.io);
        stream.ended = true;
        stream.lock.unlock(host.io);
        stream.ready.store(true, .release);
        host.wake.set(host.io);
    }
    var buffer: [4096]u8 = undefined;
    var reader = stream.file.?.reader(host.io, &buffer);
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch return;
        // The reader is the only task that waits on `space`, so it may reset it, and the check after the reset closes the gap.
        while (true) {
            stream.space.reset();
            stream.lock.lockUncancelable(host.io);
            const full = stream.buffer.items.len >= max_buffered_bytes;
            if (!full) {
                const n = @min(chunk.len, max_buffered_bytes - stream.buffer.items.len);
                stream.buffer.appendSlice(host.gpa, chunk[0..n]) catch unreachable;
                reader.interface.toss(n);
            }
            stream.lock.unlock(host.io);
            if (!full) break;
            stream.space.wait(host.io) catch return;
        }
        stream.ready.store(true, .release);
        host.wake.set(host.io);
    }
}

/// Read the pipes, reap the child, end what it left, and close the read ends. The owner settles `exited` after the last byte.
fn procTask(host: *Host, proc: *Proc) void {
    var readers: std.Io.Group = .init;
    for (&proc.streams) |*stream| {
        if (stream.file == null) continue;
        readers.concurrent(host.io, readTask, .{ host, stream }) catch {
            // A stream with no reader must not block the child on a full pipe.
            runner.endGroups(host.io, &.{proc.pid});
            stream.lock.lockUncancelable(host.io);
            stream.ended = true;
            stream.lock.unlock(host.io);
            stream.ready.store(true, .release);
        };
    }
    const protection = host.io.swapCancelProtection(.blocked);
    defer _ = host.io.swapCancelProtection(protection);
    if (host.io.concurrent(reapTask, .{ host, proc })) |future| {
        var reaper = future;
        proc.changed.waitUncancelable(host.io);
        if (proc.stop_requested.load(.acquire) and !proc.reaped.load(.acquire)) runner.endGroups(host.io, &.{proc.pid});
        _ = reaper.await(host.io);
        runner.endRemaining(host.io, proc.pid);
    } else |_| {
        runner.endGroups(host.io, &.{proc.pid});
        reapTask(host, proc);
    }
    _ = runner.awaitDrains(host.io, &readers) catch {
        const old = host.io.swapCancelProtection(.blocked);
        defer _ = host.io.swapCancelProtection(old);
        readers.cancel(host.io);
    };
    for (&proc.streams) |*stream| if (stream.file) |file| file.close(host.io);
    proc.done.store(true, .release);
    host.wake.set(host.io);
}

fn reapTask(host: *Host, proc: *Proc) void {
    std.debug.assert(proc.child.id != null);
    std.debug.assert(!proc.reaped.load(.acquire) and !proc.done.load(.acquire));
    proc.outcome = runner.reapChild(host.io, &proc.child);
    proc.reaped.store(true, .release);
    proc.changed.set(host.io);
}

/// Write queued input in order. One writer runs for each process, because two writers interleave a write above `PIPE_BUF`.
fn writeTask(host: *Host, proc: *Proc) void {
    while (true) {
        proc.writes_lock.lockUncancelable(host.io);
        if (proc.writes.len == 0) {
            proc.writing = false;
            if (proc.close_after) closeInput(proc);
            proc.writes_lock.unlock(host.io);
            return;
        }
        const w = proc.writes.popFront().?;
        const file: std.Io.File = .{ .handle = proc.stdin.?, .flags = .{ .nonblocking = false } };
        proc.writes_lock.unlock(host.io);

        // SIGPIPE is ignored in this process, so a dead reader returns an error here.
        const written = file.writeStreamingAll(host.io, w.bytes);
        proc.writes_lock.lockUncancelable(host.io);
        std.debug.assert(proc.write_bytes >= w.bytes.len);
        proc.write_bytes -= w.bytes.len;
        proc.writes_lock.unlock(host.io);
        host.gpa.free(w.bytes);
        w.op.finish(if (written) |_| .undefined else |_| .{ .failed = .{ .message = "the process closed its input" } });
    }
}

/// Close stdin. The caller holds `writes_lock`.
fn closeInput(proc: *Proc) void {
    const fd = proc.stdin orelse return;
    _ = std.posix.system.close(fd);
    proc.stdin = null;
}

/// Start `argv` with no shell over pipes. Argument errors throw; an operating error rejects `exited`.
fn jsSpawn(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return ctx.throwTypeError("the host is closed");
    if (host.procs.live.items.len >= max_processes) return ctx.throwRangeError("the host runs 64 processes");

    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = if (args.len > 0) stringList(ctx, a, args[0]) orelse &.{} else &.{};
    if (argv.len == 0) return ctx.throwTypeError("argv must be a non-empty array of strings");
    const options: Value = if (args.len > 1) args[1] else quickjs.UNDEFINED;
    const cwd = module.optionalString(ctx, a, options, "cwd") catch return ctx.throwTypeError("cwd must be a string");
    const env_value: Value = if (ctx.isObject(options)) ctx.getPropertyStr(options, "env") else quickjs.UNDEFINED;
    defer ctx.freeValue(env_value);
    const pairs = if (ctx.isUndefined(env_value)) &.{} else stringList(ctx, a, env_value) orelse
        return ctx.throwTypeError("env must be an array of key and value strings");
    if (pairs.len % 2 != 0) return ctx.throwTypeError("env must be an array of key and value strings");
    const on_output: Value = if (args.len > 2) args[2] else quickjs.UNDEFINED;
    if (!ctx.isFunction(on_output)) return ctx.throwTypeError("spawn needs an output callback");
    const root = module.rootArg(ctx, a, if (args.len > 3) args[3] else quickjs.UNDEFINED, host.cwd) orelse
        return ctx.throwTypeError("the workspace root must be an absolute path");
    var env: std.process.Environ.Map = if (pairs.len > 0) host.execution.env.clone(a) catch unreachable else undefined;
    var pair: usize = 0;
    while (pair < pairs.len) : (pair += 2) {
        if (!std.process.Environ.Map.validateKeyForPut(pairs[pair]) or std.mem.indexOfScalar(u8, pairs[pair + 1], 0) != null)
            return ctx.throwTypeError("an env key must be non-empty and hold no '=', and no env string may hold a NUL byte");
        env.put(pairs[pair], pairs[pair + 1]) catch unreachable;
    }

    var funcs: [2]Value = undefined;
    const exited = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(exited)) return exited;
    const handle = ctx.newObject();
    module.set(ctx, handle, "exited", exited);
    const program = runner.startProgram(host.io, root, if (pairs.len > 0) &env else host.execution.env, a, argv, cwd, .pipes) catch |err|
        return failStart(ctx, handle, &funcs, startMessage(err));
    const proc = launch(host, program, on_output, funcs, null);
    module.set(ctx, handle, "id", ctx.newInt32(@intCast(proc.id)));
    return handle;
}

/// The sentence a script reads for a child that could not start.
pub fn startMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "the program does not exist",
        error.HomeUnavailable => "the environment names no home directory, so a ~ working directory has no meaning",
        else => "the host could not start the program",
    };
}

/// Take a started program into the table and start its waiter. The process owns `funcs` and a copy of `on_output`.
pub fn launch(host: *Host, program: runner.Program, on_output: Value, funcs: [2]Value, job: ?*Job) *Proc {
    std.debug.assert(host.procs.live.items.len < max_processes);
    host.procs.last_id += 1;
    const proc = host.gpa.create(Proc) catch unreachable;
    proc.* = .{
        .id = host.procs.last_id,
        .pid = program.child.id.?,
        .child = program.child,
        .streams = .{ .{ .file = program.stdout, .ended = program.stdout == null }, .{ .file = program.stderr, .ended = program.stderr == null } },
        .on_output = host.ctx.dupValue(on_output),
        .resolve = funcs[0],
        .reject = funcs[1],
        .stdin = program.stdin,
        .job = job,
    };
    for (&proc.streams) |*stream| stream.ready.store(stream.ended, .release);
    host.procs.live.append(host.gpa, proc) catch unreachable;
    host.tasks.concurrent(host.io, procTask, .{ host, proc }) catch {
        // No waiter can run, so the owner ends and reaps the child, and the next drain settles it.
        runner.endGroups(host.io, &.{proc.pid});
        proc.outcome = runner.reapChild(host.io, &proc.child);
        proc.reaped.store(true, .release);
        for (&proc.streams) |*stream| {
            if (stream.file) |file| file.close(host.io);
            stream.ended = true;
            stream.ready.store(true, .release);
        }
        proc.done.store(true, .release);
    };
    return proc;
}

/// Reject `exited` of a handle whose child never started.
fn failStart(ctx: Context, handle: Value, funcs: *[2]Value, message: []const u8) Value {
    ctx.freeValue(funcs[0]);
    ctx.freeValue(funcs[1]);
    module.set(ctx, handle, "exited", rejected(ctx, message));
    module.set(ctx, handle, "id", ctx.newInt32(0));
    return handle;
}

/// Queue text for stdin. The promise resolves after the pipe accepts every byte.
fn jsWrite(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    const proc = procOf(ctx, host, args) orelse return rejected(ctx, "the process does not exist");
    if (args.len < 2 or !ctx.isString(args[1])) return rejected(ctx, "write needs text");

    proc.writes_lock.lockUncancelable(host.io);
    defer proc.writes_lock.unlock(host.io);
    if (proc.stdin == null or proc.close_after or proc.done.load(.acquire)) return rejected(ctx, "the process input is closed");
    const text = ctx.toCStringLen(args[1]) catch return rejected(ctx, "the process input could not be read");
    defer ctx.freeCString(text.ptr);
    if (text.len > max_write_bytes - proc.write_bytes or proc.writes.len >= max_writes)
        return rejected(ctx, "the process input queue is full; await write before retry");
    const started = host.ops.start(ctx) orelse return ctx.throw(ctx.getException());
    proc.writes.pushBack(host.gpa, .{ .bytes = host.gpa.dupe(u8, text) catch unreachable, .op = started.op }) catch unreachable;
    proc.write_bytes += text.len;
    if (proc.writing) return started.promise;
    proc.writing = true;
    host.tasks.concurrent(host.io, writeTask, .{ host, proc }) catch {
        while (proc.writes.popFront()) |w| {
            host.gpa.free(w.bytes);
            w.op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } });
        }
        proc.write_bytes = 0;
        proc.writing = false;
    };
    return started.promise;
}

/// Close stdin after every queued write, so the child reads EOF.
fn jsCloseStdin(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return quickjs.UNDEFINED;
    const proc = procOf(ctx, host, args) orelse return quickjs.UNDEFINED;
    proc.writes_lock.lockUncancelable(host.io);
    defer proc.writes_lock.unlock(host.io);
    if (proc.writing) proc.close_after = true else closeInput(proc);
    return quickjs.UNDEFINED;
}

/// End the child group with TERM, then KILL after the grace period, on a task. Answer false when the child had already exited.
fn jsKill(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return quickjs.FALSE;
    if (args.len == 0) return quickjs.FALSE;
    const id = module.integer(ctx, args[0], 1, std.math.maxInt(u32)) orelse return quickjs.FALSE;
    return ctx.newBool(kill(host, @intCast(id)));
}

/// Request a stop from the lifecycle task; repeated requests share that task.
pub fn kill(host: *Host, id: u32) bool {
    const proc = host.procs.find(id) orelse return false;
    return requestStop(host.io, proc);
}

fn requestStop(io: std.Io, proc: *Proc) bool {
    std.debug.assert(proc.pid > 0 and proc.id > 0);
    if (proc.reaped.load(.acquire)) return false;
    if (!proc.stop_requested.swap(true, .acq_rel)) proc.changed.set(io);
    return true;
}

fn procOf(ctx: Context, host: *Host, args: []const Value) ?*Proc {
    if (args.len == 0) return null;
    const id = module.integer(ctx, args[0], 1, std.math.maxInt(u32)) orelse return null;
    return host.procs.find(@intCast(id));
}

/// Copy a JavaScript array of strings. Another shape answers null.
fn stringList(ctx: Context, a: std.mem.Allocator, value: Value) ?[]const []const u8 {
    if (!ctx.isArray(value)) return null;
    const len = ctx.getLength(value) catch return null;
    if (len < 0 or len > 4096) return null;
    const list = a.alloc([]const u8, @intCast(len)) catch unreachable;
    for (list, 0..) |*slot, i| {
        const item = ctx.getPropertyUint32(value, @intCast(i));
        defer ctx.freeValue(item);
        slot.* = module.owned(ctx, a, item) orelse return null;
        // A C string ends at NUL, so a NUL would cut the argument without an error.
        if (std.mem.indexOfScalar(u8, slot.*, 0) != null) return null;
    }
    return list;
}

test "a failed task admission preserves the child exit and releases its handle" {
    const testing = std.testing;
    const support = @import("../test_support.zig");
    const Fail = struct {
        fn concurrent(_: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    };
    const host = support.createHost();
    defer support.destroyHost(host);
    var vtable = host.io.vtable.*;
    vtable.groupConcurrent = Fail.concurrent;
    host.io.vtable = &vtable;
    try host.evalModule(
        \\import { spawn } from "yuke:spawn";
        \\globalThis.exitKept = false;
        \\spawn(["/bin/sh", "-c", "exit 7"], { workspaceRoot: "/tmp" }).exited.then(
        \\  end => { exitKept = end.code !== null || end.signal !== null; }
        \\);
    , "admission.js");
    try support.pumpUntilTrue(host, "exitKept");
    try testing.expectEqual(@as(usize, 0), host.procs.live.items.len);
}
