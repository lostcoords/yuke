//! The native `yuke:process` module: long-lived children whose pipes tasks serve and whose output the owner delivers in `Host.pump`.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const runner = @import("../host/process.zig");
const utf8 = @import("../../utf8.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const rejected = pending.rejected;

/// The most live children. A spawn past the limit throws `RangeError`.
pub const max_processes = 64;
/// The most bytes one stream queues before its reader waits for the owner. The child then blocks on a full pipe.
pub const max_queued_bytes = 1024 * 1024;

/// Register `yuke:process` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:process", &.{
        .{ .name = "spawn", .arity = 4, .call = jsSpawn },
        .{ .name = "write", .arity = 2, .call = jsWrite },
        .{ .name = "closeStdin", .arity = 1, .call = jsCloseStdin },
        .{ .name = "kill", .arity = 1, .call = jsKill },
    });
}

/// One output stream. The reader task and the owner share the queue under `lock`.
const Stream = struct {
    file: std.Io.File,
    lock: std.Io.Mutex = .init,
    chunks: std.ArrayList([]u8) = .empty,
    queued: usize = 0,
    /// The reader sets this last, at EOF, at a read error, or at a cancel.
    ended: bool = false,
    /// A reader sets this after it queues a chunk or ends, so the owner knows a drain has work.
    ready: std.atomic.Value(bool) = .init(false),
    /// The owner sets this after a drain, so a reader that waits for queue space resumes.
    space: std.Io.Event = .unset,
    /// The bytes of a character that the last chunk cut. Only the owner touches these.
    carry: [4]u8 = undefined,
    carry_len: u8 = 0,
    flushed: bool = false,
};

/// One queued stdin write and the op that settles its promise.
const Write = struct { bytes: []u8, op: *pending.Op };

const Proc = struct {
    id: u32,
    pid: std.posix.pid_t,
    child: std.process.Child,
    streams: [2]Stream,
    /// The output callback and the `exited` resolvers are GC roots until the owner frees the process.
    on_output: Value,
    resolve: Value,
    reject: Value,
    /// Guards `writes`, `stdin`, `writing`, and `close_after`.
    writes_lock: std.Io.Mutex = .init,
    writes: std.ArrayList(Write) = .empty,
    stdin: ?std.posix.fd_t,
    writing: bool = false,
    close_after: bool = false,
    /// The waiter writes the exit, then sets `done`. The owner reads both only after `done`.
    outcome: ?runner.Outcome = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Owner only: `exited` settled.
    settled: bool = false,
};

pub const Procs = struct {
    live: std.ArrayList(*Proc) = .empty,
    last_id: u32 = 0,

    /// Answer whether a drain has work: a queued chunk, an end to flush, or an exit to settle.
    pub fn hasWork(self: *const Procs) bool {
        for (self.live.items) |proc| {
            if (proc.streams[0].ready.load(.monotonic) or proc.streams[1].ready.load(.monotonic)) return true;
            if (!proc.settled and proc.done.load(.monotonic)) return true;
        }
        return false;
    }

    fn find(self: *const Procs, id: u32) ?*Proc {
        for (self.live.items) |proc| if (proc.id == id) return proc;
        return null;
    }

    /// Deliver queued output, settle `exited` after the last chunk, and free a process with no work left. Answer whether a callback threw.
    pub fn drain(self: *Procs, host: *Host) bool {
        std.debug.assert(host.phase == .open);
        var faulted = false;
        var i: usize = 0;
        // A callback can spawn another process, so the loop re-reads the length.
        while (i < self.live.items.len) {
            const proc = self.live.items[i];
            for (&proc.streams, 1..) |*stream, number| {
                if (!stream.ready.swap(false, .monotonic)) continue;
                if (deliver(host, proc, stream, @intCast(number))) faulted = true;
            }
            if (!proc.settled and proc.done.load(.monotonic) and proc.streams[0].flushed and proc.streams[1].flushed) {
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

    /// Write the pid of every running child into `out` and answer the count. `Host.close` ends them before it cancels the tasks.
    pub fn runningPids(self: *const Procs, out: []std.posix.pid_t) usize {
        var count: usize = 0;
        for (self.live.items) |proc| if (!proc.done.load(.monotonic)) {
            out[count] = proc.pid;
            count += 1;
        };
        return count;
    }

    /// Free every process. Every task has returned, so nothing touches a process after this.
    pub fn deinit(self: *Procs, host: *Host) void {
        for (self.live.items) |proc| {
            std.debug.assert(proc.done.load(.monotonic) and !proc.writing);
            free(host, proc);
        }
        self.live.deinit(host.gpa);
        self.* = .{};
    }
};

/// Answer whether no write is queued or running. A writer can still hold the stdin descriptor before this is true.
fn idle(io: std.Io, proc: *Proc) bool {
    proc.writes_lock.lockUncancelable(io);
    defer proc.writes_lock.unlock(io);
    return !proc.writing and proc.writes.items.len == 0;
}

fn free(host: *Host, proc: *Proc) void {
    const ctx = host.ctx;
    ctx.freeValue(proc.on_output);
    ctx.freeValue(proc.resolve);
    ctx.freeValue(proc.reject);
    if (proc.stdin) |fd| _ = std.posix.system.close(fd);
    // A write that a close canceled never ran, and `Ops.deinit` frees its op.
    for (proc.writes.items) |w| host.gpa.free(w.bytes);
    proc.writes.deinit(host.gpa);
    for (&proc.streams) |*stream| {
        for (stream.chunks.items) |chunk| host.gpa.free(chunk);
        stream.chunks.deinit(host.gpa);
    }
    host.gpa.destroy(proc);
}

/// Hand every queued chunk of one stream to the callback, then flush the cut character after the end.
fn deliver(host: *Host, proc: *Proc, stream: *Stream, number: i32) bool {
    stream.lock.lockUncancelable(host.io);
    var taken = stream.chunks;
    stream.chunks = .empty;
    stream.queued = 0;
    const ended = stream.ended;
    stream.lock.unlock(host.io);
    stream.space.set(host.io);
    defer taken.deinit(host.gpa);

    var faulted = false;
    for (taken.items) |chunk| {
        defer host.gpa.free(chunk);
        const joined = std.mem.concat(host.gpa, u8, &.{ stream.carry[0..stream.carry_len], chunk }) catch unreachable;
        defer host.gpa.free(joined);
        const cut = utf8.whole(joined);
        std.debug.assert(joined.len - cut <= stream.carry.len);
        @memcpy(stream.carry[0 .. joined.len - cut], joined[cut..]);
        stream.carry_len = @intCast(joined.len - cut);
        if (cut != 0 and emit(host, proc, number, joined[0..cut])) faulted = true;
    }
    if (ended and !stream.flushed) {
        stream.flushed = true;
        if (stream.carry_len != 0 and emit(host, proc, number, stream.carry[0..stream.carry_len])) faulted = true;
        stream.carry_len = 0;
    }
    return faulted;
}

/// Call the output callback with the stream number and valid text.
fn emit(host: *Host, proc: *Proc, number: i32, bytes: []const u8) bool {
    const ctx = host.ctx;
    const text = utf8.sanitize(host.gpa, bytes) catch unreachable;
    defer host.gpa.free(text);
    host.enterSlice();
    var argv = [_]Value{ ctx.newInt32(number), ctx.newString(text) };
    defer for (argv) |arg| ctx.freeValue(arg);
    const answer = ctx.call(proc.on_output, quickjs.UNDEFINED, &argv);
    defer ctx.freeValue(answer);
    if (!ctx.isException(answer)) return false;
    host.noteFault();
    return true;
}

/// Resolve `exited` with `{ code, signal }`. Exactly one of the two is null.
fn settle(host: *Host, proc: *Proc) bool {
    const ctx = host.ctx;
    const outcome = proc.outcome orelse return call(host, proc.reject, ctx.newString("the host could not reap the process"));
    const result = ctx.newObject();
    switch (outcome) {
        .exited => |code| {
            module.set(ctx, result, "code", ctx.newInt32(code));
            module.set(ctx, result, "signal", quickjs.NULL);
        },
        .signaled => |sig| {
            module.set(ctx, result, "code", quickjs.NULL);
            module.set(ctx, result, "signal", ctx.newString(signalName(sig)));
        },
        .timed_out => unreachable, // A process has no deadline.
    }
    return call(host, proc.resolve, result);
}

fn call(host: *Host, function: Value, value: Value) bool {
    const ctx = host.ctx;
    defer ctx.freeValue(value);
    var argv = [_]Value{value};
    const answer = ctx.call(function, quickjs.UNDEFINED, &argv);
    defer ctx.freeValue(answer);
    if (!ctx.isException(answer)) return false;
    host.noteFault();
    return true;
}

/// Name a signal as Node does, for example `SIGTERM`.
fn signalName(sig: u8) []const u8 {
    const names = .{ .{ 1, "SIGHUP" }, .{ 2, "SIGINT" }, .{ 3, "SIGQUIT" }, .{ 6, "SIGABRT" }, .{ 9, "SIGKILL" }, .{ 13, "SIGPIPE" }, .{ 14, "SIGALRM" }, .{ 15, "SIGTERM" } };
    inline for (names) |pair| if (pair[0] == sig) return pair[1];
    return "SIGUNKNOWN";
}

/// Read one stream until its end. A full queue makes the reader wait, so the child blocks on the pipe and memory stays bounded.
fn readTask(host: *Host, proc: *Proc, which: usize) void {
    const stream = &proc.streams[which];
    defer {
        stream.lock.lockUncancelable(host.io);
        stream.ended = true;
        stream.lock.unlock(host.io);
        stream.ready.store(true, .monotonic);
        host.wake.set(host.io);
    }
    var buffer: [4096]u8 = undefined;
    var reader = stream.file.reader(host.io, &buffer);
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch return;
        waitForSpace(host.io, stream) catch return;
        const copy = host.gpa.dupe(u8, chunk) catch unreachable;
        stream.lock.lockUncancelable(host.io);
        stream.chunks.append(host.gpa, copy) catch unreachable;
        stream.queued += copy.len;
        stream.lock.unlock(host.io);
        reader.interface.toss(chunk.len);
        stream.ready.store(true, .monotonic);
        host.wake.set(host.io);
    }
}

/// Wait until the queue has space. The reader is the only task that waits on `space`, so it may reset it; the check after the reset closes the gap.
fn waitForSpace(io: std.Io, stream: *Stream) error{Canceled}!void {
    while (true) {
        stream.space.reset();
        stream.lock.lockUncancelable(io);
        const full = stream.queued >= max_queued_bytes;
        stream.lock.unlock(io);
        if (!full) return;
        try stream.space.wait(io);
    }
}

/// Read both streams, reap the child, end what it left, and close the read ends. The owner settles `exited` after the last chunk.
fn procTask(host: *Host, proc: *Proc) void {
    var readers: std.Io.Group = .init;
    var spawned: usize = 0;
    for (0..2) |which| {
        readers.concurrent(host.io, readTask, .{ host, proc, which }) catch break;
        spawned += 1;
    }
    if (spawned < 2) {
        // A stream with no reader ends at once, and the child must not wait on a pipe that nobody reads.
        for (spawned..2) |which| {
            proc.streams[which].ended = true;
            proc.streams[which].ready.store(true, .monotonic);
        }
        runner.endGroups(host.io, &.{proc.pid});
    }
    proc.outcome = runner.reapGroup(host.io, &proc.child);
    _ = runner.awaitDrains(host.io, &readers) catch {
        const old = host.io.swapCancelProtection(.blocked);
        defer _ = host.io.swapCancelProtection(old);
        readers.cancel(host.io);
    };
    for (&proc.streams) |*stream| stream.file.close(host.io);
    proc.done.store(true, .monotonic);
    host.wake.set(host.io);
}

/// Write queued input in order. One writer runs for each process, because two writers interleave a write above `PIPE_BUF`.
fn writeTask(host: *Host, proc: *Proc) void {
    while (true) {
        proc.writes_lock.lockUncancelable(host.io);
        if (proc.writes.items.len == 0) {
            proc.writing = false;
            if (proc.close_after) if (proc.stdin) |fd| {
                _ = std.posix.system.close(fd);
                proc.stdin = null;
            };
            proc.writes_lock.unlock(host.io);
            return;
        }
        const w = proc.writes.orderedRemove(0);
        const fd = proc.stdin.?;
        proc.writes_lock.unlock(host.io);

        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        // SIGPIPE is ignored in this process, so a dead reader returns an error here.
        const written = file.writeStreamingAll(host.io, w.bytes);
        host.gpa.free(w.bytes);
        w.op.finish(if (written) |_| .undefined else |_| .{ .failed = .{ .message = "the process closed its input" } });
    }
}

fn killTask(host: *Host, pid: std.posix.pid_t) void {
    runner.endGroups(host.io, &.{pid});
}

/// Start a program with no shell. Argument errors throw, and an operating error rejects `exited`, so a caller always gets a handle.
fn jsSpawn(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return ctx.throwTypeError("the host is closed");
    if (args.len < 3 or !ctx.isFunction(args[2])) return ctx.throwTypeError("spawn needs argv, options, and an output callback");
    if (host.procs.live.items.len >= max_processes) return ctx.throwRangeError("the host runs 64 processes");

    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = stringList(ctx, a, args[0]) orelse return ctx.throwTypeError("argv must be a non-empty array of strings");
    if (argv.len == 0) return ctx.throwTypeError("argv must be a non-empty array of strings");
    const options = args[1];
    const cwd = optionalString(ctx, a, options, "cwd") catch return ctx.throwTypeError("cwd must be a string");
    const pairs = optionalList(ctx, a, options, "env") catch return ctx.throwTypeError("env must hold string values");
    if (pairs.len % 2 != 0) return ctx.throwTypeError("env must hold string values");
    const root: []const u8 = if (args.len > 3 and ctx.isString(args[3]))
        module.owned(ctx, a, args[3]).?
    else
        host.cwd;
    var env = host.execution.env.clone(a) catch unreachable;
    var pair: usize = 0;
    while (pair < pairs.len) : (pair += 2) env.put(pairs[pair], pairs[pair + 1]) catch unreachable;

    var funcs: [2]Value = undefined;
    const exited = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(exited)) return exited;
    const handle = ctx.newObject();
    module.set(ctx, handle, "exited", exited);

    const program = runner.startProgram(host.io, root, &env, a, argv, cwd) catch |err| {
        ctx.freeValue(funcs[0]);
        ctx.freeValue(funcs[1]);
        module.set(ctx, handle, "exited", rejected(ctx, switch (err) {
            error.NotFound => "the program does not exist",
            error.HomeUnavailable => "the environment names no home directory, so a ~ working directory has no meaning",
            else => "the host could not start the program",
        }));
        module.set(ctx, handle, "id", ctx.newInt32(0));
        return handle;
    };

    host.procs.last_id += 1;
    const proc = host.gpa.create(Proc) catch unreachable;
    proc.* = .{
        .id = host.procs.last_id,
        .pid = program.child.id.?,
        .child = program.child,
        .streams = .{ .{ .file = program.stdout }, .{ .file = program.stderr } },
        .on_output = ctx.dupValue(args[2]),
        .resolve = funcs[0],
        .reject = funcs[1],
        .stdin = program.stdin,
    };
    host.procs.live.append(host.gpa, proc) catch unreachable;
    host.tasks.concurrent(host.io, procTask, .{ host, proc }) catch {
        // No waiter can run, so the owner ends and reaps the child, and the next drain rejects `exited`.
        runner.endGroups(host.io, &.{proc.pid});
        _ = runner.reapGroup(host.io, &proc.child);
        for (&proc.streams) |*stream| {
            stream.file.close(host.io);
            stream.ended = true;
            stream.ready.store(true, .monotonic);
        }
        proc.done.store(true, .monotonic);
    };
    module.set(ctx, handle, "id", ctx.newInt32(@intCast(proc.id)));
    return handle;
}

/// Queue text for the child stdin. The promise resolves after the pipe accepts every byte.
fn jsWrite(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return rejected(ctx, "the host is closed");
    const proc = procOf(ctx, host, args) orelse return rejected(ctx, "the process does not exist");
    if (args.len < 2 or !ctx.isString(args[1])) return rejected(ctx, "write needs text");
    const bytes = module.owned(ctx, host.gpa, args[1]).?;

    proc.writes_lock.lockUncancelable(host.io);
    if (proc.stdin == null or proc.close_after or proc.done.load(.monotonic)) {
        proc.writes_lock.unlock(host.io);
        host.gpa.free(bytes);
        return rejected(ctx, "the process input is closed");
    }
    const started = host.ops.start(ctx) orelse {
        proc.writes_lock.unlock(host.io);
        host.gpa.free(bytes);
        return ctx.throw(ctx.getException());
    };
    proc.writes.append(host.gpa, .{ .bytes = bytes, .op = started.op }) catch unreachable;
    const launch = !proc.writing;
    proc.writing = true;
    proc.writes_lock.unlock(host.io);

    if (launch) host.tasks.concurrent(host.io, writeTask, .{ host, proc }) catch {
        proc.writes_lock.lockUncancelable(host.io);
        defer proc.writes_lock.unlock(host.io);
        for (proc.writes.items) |w| {
            host.gpa.free(w.bytes);
            w.op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } });
        }
        proc.writes.clearRetainingCapacity();
        proc.writing = false;
    };
    return started.promise;
}

/// Close the child stdin after every queued write, so the child reads EOF.
fn jsCloseStdin(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return quickjs.UNDEFINED;
    const proc = procOf(ctx, host, args) orelse return quickjs.UNDEFINED;
    proc.writes_lock.lockUncancelable(host.io);
    defer proc.writes_lock.unlock(host.io);
    if (proc.writing) {
        proc.close_after = true;
    } else if (proc.stdin) |fd| {
        _ = std.posix.system.close(fd);
        proc.stdin = null;
    }
    return quickjs.UNDEFINED;
}

/// End the child group with TERM, then KILL after the grace period. The owner never sleeps for the grace period.
fn jsKill(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return quickjs.UNDEFINED;
    const proc = procOf(ctx, host, args) orelse return quickjs.UNDEFINED;
    if (proc.done.load(.monotonic)) return quickjs.UNDEFINED;
    host.tasks.concurrent(host.io, killTask, .{ host, proc.pid }) catch runner.endGroups(host.io, &.{proc.pid});
    return quickjs.UNDEFINED;
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
    }
    return list;
}

fn optionalString(ctx: Context, a: std.mem.Allocator, options: Value, name: [:0]const u8) error{InvalidOption}!?[]const u8 {
    if (!ctx.isObject(options)) return null;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return null;
    return module.owned(ctx, a, value) orelse error.InvalidOption;
}

fn optionalList(ctx: Context, a: std.mem.Allocator, options: Value, name: [:0]const u8) error{InvalidOption}![]const []const u8 {
    if (!ctx.isObject(options)) return &.{};
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return &.{};
    return stringList(ctx, a, value) orelse error.InvalidOption;
}
