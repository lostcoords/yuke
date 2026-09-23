//! Run one command natively over `std.Io`; the child leads a new session with no controlling terminal, a deadline or cancel kills its process group so a shell descendant does not survive the call, and a descendant that calls `setsid` leaves the group.

const std = @import("std");
const spawn_c = @import("spawn_c");
const utf8 = @import("../../utf8.zig");
const h = @import("operations.zig");
const paths = @import("../../paths.zig");
const execution = @import("../../execution.zig");
const builtin = @import("builtin");

/// One command to run. `cwd` is relative to the workspace root. A null `cwd` uses the root itself.
pub const Spec = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: u32,
    /// The cap for each stream. The runner keeps the head and the tail and reports the cut.
    max_stream_bytes: u32,
    /// An absolute path. The run writes both streams to it and keeps the file only when a stream was cut.
    log: ?[]const u8 = null,
    /// The runner sends each chunk to this sink in drain order.
    live: ?Live = null,
};

/// The live output of one command. Both drains write to it, and each chunk ends on a character boundary except at the end of a stream.
pub const Live = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

/// How one command ended. The union makes an impossible pair unrepresentable.
pub const Outcome = union(enum) {
    /// The command ended on its own with this code.
    exited: u8,
    /// A signal ended the command. The value is the signal number.
    signaled: u8,
    /// The deadline expired. The runner killed the process group.
    timed_out,
};

/// What one command produced. `stdout`, `stderr`, and `log` come from `scratch`.
pub const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    outcome: Outcome,
    /// The bytes each stream dropped between its head and its tail. Zero means nothing was lost.
    stdout_dropped: u64 = 0,
    stderr_dropped: u64 = 0,
    /// The kept log, which holds every byte both streams wrote. Null when nothing was cut or no log was asked.
    log: ?[]const u8 = null,
};

/// The wait between SIGTERM and SIGKILL. A shell runs its SIGTERM trap in this time. A test waits less.
const grace_ns: u64 = if (builtin.is_test) 100 * std.time.ns_per_ms else 2 * std.time.ns_per_s;

/// The probe period while a group ends.
const poll_ms = 10;

/// One log that both drains append to. A drain reserves its offset before it writes, so two chunks never overlap.
const Log = struct {
    file: std.Io.File,
    end: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn append(self: *Log, io: std.Io, bytes: []const u8) void {
        if (self.failed.load(.monotonic)) return;
        const at = self.end.fetchAdd(bytes.len, .monotonic);
        self.file.writePositionalAll(io, bytes, at) catch self.failed.store(true, .monotonic);
    }
};

const notice_format = "\n[The tool dropped {d} bytes here.]\n";

/// One drain leg: it reads one stream to its end and keeps its head and its tail, because a build prints its error last.
const Drain = struct {
    file: std.Io.File,
    limit: u32,
    log: ?*Log,
    live: ?Live,
    head: std.ArrayList(u8) = .empty,
    tail: []u8 = &.{},
    tail_len: usize = 0,
    tail_at: usize = 0,
    dropped: u64 = 0,
    err: ?anyerror = null,

    /// Join the head, one gap notice, and the tail in one `scratch` buffer. The notice also counts the bytes of a cut character.
    fn text(self: *Drain, scratch: std.mem.Allocator) []const u8 {
        if (self.tail_len == 0 and self.dropped == 0) return self.head.items;
        // With no gap the two ends stay adjacent, so the join restores the exact stream.
        const gap = self.dropped != 0;
        const head = if (gap) self.head.items[0..utf8.whole(self.head.items)] else self.head.items;
        // The ring lands after room for the longest notice, then moves back next to the notice.
        const max_notice = std.fmt.count(notice_format, .{std.math.maxInt(u64)});
        const joined = scratch.alloc(u8, head.len + max_notice + self.tail_len) catch unreachable;
        @memcpy(joined[0..head.len], head);
        const ring = joined[head.len + max_notice ..];
        const split = @min(self.tail_len, self.tail.len - self.tail_at);
        @memcpy(ring[0..split], self.tail[self.tail_at..][0..split]);
        @memcpy(ring[split..], self.tail[0 .. self.tail_len - split]);
        // After a gap the tail starts at its first whole line, or at its first whole character with no newline.
        const tail_start = if (!gap) 0 else if (std.mem.indexOfScalar(u8, ring, '\n')) |newline| newline + 1 else utf8.head(ring);
        const tail = ring[tail_start..];
        const trimmed = (self.head.items.len - head.len) + tail_start;
        const notice = if (gap) std.fmt.bufPrint(joined[head.len..][0..max_notice], notice_format, .{self.dropped + trimmed}) catch unreachable else "";
        const tail_at = head.len + notice.len;
        std.mem.copyForwards(u8, joined[tail_at..][0..tail.len], tail);
        return joined[0 .. tail_at + tail.len];
    }
};

/// Run `spec` and return its output. It returns an error rather than an assertion, because `spec` is validated tool input.
pub fn run(io: std.Io, root: []const u8, context: execution.Context, scratch: std.mem.Allocator, spec: Spec) h.HostError!Result {
    if (spec.timeout_ms == 0 or spec.max_stream_bytes == 0) return error.HostFailure;
    std.debug.assert(std.fs.path.isAbsolute(context.shell.path));
    const cwd = try resolveCwd(scratch, root, context.env, spec.cwd);

    // A log that cannot open costs the log, not the command.
    var log: ?Log = null;
    if (spec.log) |path| if (std.Io.Dir.createFileAbsolute(io, path, .{})) |file| {
        log = .{ .file = file };
    } else |_| {};
    defer if (log) |*l| l.file.close(io);
    errdefer if (log != null) std.Io.Dir.deleteFileAbsolute(io, spec.log.?) catch {};

    // The drains own the read ends from here, so every path closes them after the drains end.
    const out_pipe = try pipeAboveStdio();
    var out: Drain = .{ .file = pipeReader(out_pipe[0]), .limit = spec.max_stream_bytes, .log = if (log) |*l| l else null, .live = spec.live };
    defer out.file.close(io);
    const err_pipe = pipeAboveStdio() catch |e| {
        _ = std.posix.system.close(out_pipe[1]);
        return e;
    };
    var err: Drain = .{ .file = pipeReader(err_pipe[0]), .limit = spec.max_stream_bytes, .log = if (log) |*l| l else null, .live = spec.live };
    defer err.file.close(io);

    // The parent closes its write ends after the spawn, so a drain reaches EOF when the last child copy closes.
    var child = spawned: {
        defer _ = std.posix.system.close(out_pipe[1]);
        defer _ = std.posix.system.close(err_pipe[1]);
        break :spawned try spawnArgv(scratch, context.env, &.{ context.shell.path, "-c", spec.command }, cwd, null, out_pipe[1], err_pipe[1]);
    };
    const pid = child.id.?;

    var term: ?std.process.Child.Term = null;
    var exited: std.Io.Event = .unset;
    var reaper = io.concurrent(reap, .{ io, &child, &term, &exited }) catch {
        killGroup(pid, .KILL);
        reap(io, &child, &term, &exited);
        return error.HostFailure;
    };
    // `Future.await` is uncancelable and the reaper returns only after the shell dies, so every error path below kills first.
    defer _ = reaper.await(io);
    var drains: std.Io.Group = .init;
    errdefer {
        endGroups(io, &.{pid});
        const old = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old);
        drains.cancel(io);
    }

    drains.concurrent(io, drain, .{ io, scratch, &out }) catch return error.HostFailure;
    drains.concurrent(io, drain, .{ io, scratch, &err }) catch return error.HostFailure;

    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromMilliseconds(spec.timeout_ms), .clock = .awake });
    const timed_out = !try waitUntil(io, &exited, deadline);
    if (timed_out) {
        endGroups(io, &.{pid});
        exited.waitUncancelable(io);
    }
    // A reaped PID can be reused; this backend has no process-group lifetime handle.
    if (groupAlive(pid)) endGroups(io, &.{pid});
    const abandoned = try awaitDrains(io, &drains);
    if (out.err) |e| if (!abandoned) return mapDrainError(e);
    if (err.err) |e| if (!abandoned) return mapDrainError(e);

    const cut = out.dropped + err.dropped != 0;
    const kept: ?[]const u8 = if (log) |*l| if (cut and !l.failed.load(.monotonic)) scratch.dupe(u8, spec.log.?) catch unreachable else blk: {
        std.Io.Dir.deleteFileAbsolute(io, spec.log.?) catch {};
        break :blk null;
    } else null;

    return .{
        .stdout = out.text(scratch),
        .stderr = err.text(scratch),
        .outcome = if (timed_out) .timed_out else outcomeOf(term orelse return error.HostFailure) orelse return error.HostFailure,
        .stdout_dropped = out.dropped,
        .stderr_dropped = err.dropped,
        .log = kept,
    };
}

/// Spawn `argv` as the leader of a new session with no terminal. A null `stdin` reads `/dev/null`. std has no session flag yet, so libc does it.
fn spawnArgv(scratch: std.mem.Allocator, env: *const std.process.Environ.Map, argv: []const []const u8, cwd: []const u8, stdin: ?std.posix.fd_t, stdout: std.posix.fd_t, stderr: std.posix.fd_t) h.HostError!std.process.Child {
    std.debug.assert(argv.len > 0 and std.fs.path.isAbsolute(argv[0]));
    std.debug.assert(std.fs.path.isAbsolute(cwd));
    // A `dup2` onto its own number keeps CLOEXEC, so every source must sit above the standard streams.
    std.debug.assert(stdout > std.posix.STDERR_FILENO and stderr > std.posix.STDERR_FILENO);
    if (stdin) |fd| std.debug.assert(fd > std.posix.STDERR_FILENO);
    // A C string ends at NUL, so a NUL would cut the program, an argument, or the directory without an error.
    for (argv) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.HostFailure;
    if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.HostFailure;
    const argv_z = scratch.allocSentinel(?[*:0]const u8, argv.len, null) catch return error.HostFailure;
    for (argv, argv_z) |arg, *slot| slot.* = (scratch.dupeZ(u8, arg) catch return error.HostFailure).ptr;
    const cwd_z = scratch.dupeZ(u8, cwd) catch return error.HostFailure;
    // The block replaces the raw process environment, so the child sees the recovered home. It drops `ZIG_PROGRESS` as std does.
    const envp = env.createPosixBlock(scratch, .{ .zig_progress_fd = -1 }) catch return error.HostFailure;

    var actions: spawn_c.posix_spawn_file_actions_t = undefined;
    try checkSpawn(spawn_c.posix_spawn_file_actions_init(&actions));
    defer std.debug.assert(spawn_c.posix_spawn_file_actions_destroy(&actions) == 0);
    if (stdin) |fd| {
        try checkSpawn(spawn_c.posix_spawn_file_actions_adddup2(&actions, fd, std.posix.STDIN_FILENO));
    } else {
        try checkSpawn(spawn_c.posix_spawn_file_actions_addopen(&actions, std.posix.STDIN_FILENO, "/dev/null", spawn_c.O_RDONLY, 0));
    }
    try checkSpawn(spawn_c.posix_spawn_file_actions_adddup2(&actions, stdout, std.posix.STDOUT_FILENO));
    try checkSpawn(spawn_c.posix_spawn_file_actions_adddup2(&actions, stderr, std.posix.STDERR_FILENO));
    try checkSpawn(spawn_c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z.ptr));

    var attr: spawn_c.posix_spawnattr_t = undefined;
    try checkSpawn(spawn_c.posix_spawnattr_init(&attr));
    defer std.debug.assert(spawn_c.posix_spawnattr_destroy(&attr) == 0);
    // The empty mask keeps a signal the caller blocks from staying blocked in the child.
    var empty_mask: spawn_c.sigset_t = undefined;
    try checkSpawn(spawn_c.sigemptyset(&empty_mask));
    try checkSpawn(spawn_c.posix_spawnattr_setsigmask(&attr, &empty_mask));
    // SETSID makes pid, pgid and sid equal, so `killGroup(pid)` reaches every process the child starts.
    const flags: c_short = @intCast(spawn_c.POSIX_SPAWN_SETSID | spawn_c.POSIX_SPAWN_SETSIGMASK);
    try checkSpawn(spawn_c.posix_spawnattr_setflags(&attr, flags));

    // A failed exec returns here as an error with no child left behind, so the caller has nothing to reap.
    var pid: spawn_c.pid_t = undefined;
    try checkSpawn(spawn_c.posix_spawn(&pid, argv_z[0].?, &actions, &attr, @ptrCast(argv_z.ptr), @ptrCast(envp.slice.ptr)));
    std.debug.assert(pid > 0);
    // The child holds no stream, so `wait` closes nothing and the caller owns every descriptor.
    return .{ .id = pid, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
}

/// Where the output of a started program goes.
pub const Output = union(enum) {
    pipes,
    /// Both streams go to a new file at this absolute path, and stdin reads `/dev/null`.
    log: []const u8,
};

/// A started program and the parent ends of its pipes. The caller owns every descriptor and reaps the child with `reapChild`.
pub const Program = struct {
    child: std.process.Child,
    stdin: ?std.posix.fd_t = null,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
};

/// Start `argv` with no shell in a new session. A bare name resolves against `PATH` in `env`, not in this process.
pub fn startProgram(io: std.Io, root: []const u8, env: *const std.process.Environ.Map, scratch: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, output: Output) h.HostError!Program {
    std.debug.assert(argv.len > 0);
    const dir = try resolveCwd(scratch, root, env, cwd);
    var resolved = scratch.dupe([]const u8, argv) catch return error.HostFailure;
    resolved[0] = try resolveProgram(io, scratch, env, dir, argv[0]);

    switch (output) {
        .log => |path| {
            std.debug.assert(std.fs.path.isAbsolute(path));
            const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return error.HostFailure;
            errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
            const fd = try aboveStdio(file.handle);
            defer _ = std.posix.system.close(fd);
            return .{ .child = try spawnArgv(scratch, env, resolved, dir, null, fd, fd) };
        },
        .pipes => {
            const in = try pipeAboveStdio();
            defer _ = std.posix.system.close(in[0]);
            errdefer _ = std.posix.system.close(in[1]);
            const out = try pipeAboveStdio();
            defer _ = std.posix.system.close(out[1]);
            errdefer _ = std.posix.system.close(out[0]);
            const err = try pipeAboveStdio();
            defer _ = std.posix.system.close(err[1]);
            errdefer _ = std.posix.system.close(err[0]);
            const child = try spawnArgv(scratch, env, resolved, dir, in[0], out[1], err[1]);
            return .{ .child = child, .stdin = in[1], .stdout = pipeReader(out[0]), .stderr = pipeReader(err[0]) };
        },
    }
}

/// Find an executable for `name`. A relative name or `PATH` entry resolves against `dir`, as `execvp` resolves it against the working directory.
fn resolveProgram(io: std.Io, scratch: std.mem.Allocator, env: *const std.process.Environ.Map, dir: []const u8, name: []const u8) h.HostError![]const u8 {
    if (name.len == 0) return error.NotFound;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return executable(io, scratch, dir, "", name) orelse error.NotFound;
    var entries = std.mem.splitScalar(u8, env.get("PATH") orelse return error.NotFound, ':');
    while (entries.next()) |entry| if (executable(io, scratch, dir, entry, name)) |path| return path;
    return error.NotFound;
}

/// Answer the absolute path of `name` under `entry` when it is an executable regular file.
fn executable(io: std.Io, scratch: std.mem.Allocator, dir: []const u8, entry: []const u8, name: []const u8) ?[]const u8 {
    const path = std.fs.path.resolve(scratch, &.{ dir, entry, name }) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (stat.kind != .file) return null;
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return null;
    return path;
}

/// Map a libc spawn return code to the host error. Every `posix_spawn` call returns zero or an errno value.
fn checkSpawn(rc: c_int) h.HostError!void {
    if (rc != 0) return error.HostFailure;
}

/// Move a CLOEXEC descriptor above the standard streams, because a launcher that closed one hands out fd 0, 1 or 2. It closes `fd` on a move.
fn aboveStdio(fd: std.posix.fd_t) h.HostError!std.posix.fd_t {
    if (fd > std.posix.STDERR_FILENO) return fd;
    const raised = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, std.posix.STDERR_FILENO + 1));
    _ = std.posix.system.close(fd);
    if (raised < 0) return error.HostFailure;
    std.debug.assert(raised > std.posix.STDERR_FILENO);
    return raised;
}

fn pipeReader(fd: std.posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Create a CLOEXEC pipe with both ends above the standard streams, so either end can become a child stream.
fn pipeAboveStdio() h.HostError![2]std.posix.fd_t {
    const fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.HostFailure;
    const read_end = aboveStdio(fds[0]) catch {
        _ = std.posix.system.close(fds[1]);
        return error.HostFailure;
    };
    const write_end = aboveStdio(fds[1]) catch {
        _ = std.posix.system.close(read_end);
        return error.HostFailure;
    };
    return .{ read_end, write_end };
}

/// Reap a session leader with cancelation blocked; the lifecycle owner handles its process group.
pub fn reapChild(io: std.Io, child: *std.process.Child) ?Outcome {
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    const term = child.wait(io) catch null;
    return if (term) |t| outcomeOf(t) else null;
}

pub fn endRemaining(io: std.Io, pid: std.posix.pid_t) void {
    std.debug.assert(pid > 0);
    if (groupAlive(pid)) endGroups(io, &.{pid});
}

fn outcomeOf(term: std.process.Child.Term) ?Outcome {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signaled = std.math.cast(u8, @intFromEnum(sig)) orelse return null },
        else => null,
    };
}

/// Wait for `event` until `deadline`, and answer false at the deadline. A spurious wake also returns `error.Timeout`, so the loop reads the clock.
fn waitUntil(io: std.Io, event: *std.Io.Event, deadline: std.Io.Clock.Timestamp) error{Canceled}!bool {
    while (true) {
        event.waitTimeout(io, .{ .deadline = deadline }) catch |wait_err| switch (wait_err) {
            error.Canceled => return error.Canceled,
            error.Timeout => {
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                return event.isSet();
            },
        };
        return true;
    }
}

/// Give the drains one grace period, and answer true when they were cut. A descendant that left the session can hold a pipe open.
pub fn awaitDrains(io: std.Io, drains: *std.Io.Group) h.HostError!bool {
    var done: std.Io.Event = .unset;
    var joiner = io.concurrent(joinGroup, .{ io, drains, &done }) catch return error.HostFailure;
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromNanoseconds(grace_ns), .clock = .awake });
    const joined = waitUntil(io, &done, deadline) catch {
        _ = joiner.cancel(io);
        return error.Canceled;
    };
    if (!joined) {
        const old = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old);
        drains.cancel(io);
    }
    _ = joiner.await(io);
    return !joined;
}

/// Reap the shell with cancelation blocked, because a canceled wait leaves a zombie. It returns only after the shell dies.
fn reap(io: std.Io, child: *std.process.Child, term: *?std.process.Child.Term, exited: *std.Io.Event) void {
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    term.* = child.wait(io) catch null;
    exited.set(io);
}

/// Send TERM to the groups, then KILL after one grace period. It returns early when every group is gone, and it blocks cancelation.
pub fn endGroups(io: std.Io, pids: []const std.posix.pid_t) void {
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    for (pids) |pid| killGroup(pid, .TERM);
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromNanoseconds(grace_ns), .clock = .awake });
    while (deadline.durationFromNow(io).raw.nanoseconds > 0) {
        for (pids) |pid| {
            if (groupAlive(pid)) break;
        } else return;
        std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
    }
    for (pids) |pid| killGroup(pid, .KILL);
}

/// Answer whether any process of the group lives. An unreaped zombie leader still counts.
fn groupAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(-pid, @enumFromInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// Signal a whole process group. A negative pid names the group, so every member receives it.
fn killGroup(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    std.posix.kill(-pid, sig) catch {}; // The group can already be gone.
}

/// Join the group, then set `done`. The caller waits on `done` with a deadline.
fn joinGroup(io: std.Io, group: *std.Io.Group, done: *std.Io.Event) void {
    group.await(io) catch {};
    done.set(io);
}

/// Resolve the working directory. A null `cwd` uses the workspace root itself.
fn resolveCwd(scratch: std.mem.Allocator, root: []const u8, env: *const std.process.Environ.Map, cwd: ?[]const u8) h.HostError![]const u8 {
    const rel = cwd orelse return root;
    return paths.anchorAt(scratch, env, root, rel) catch |err| switch (err) {
        error.HomeUnavailable => error.HomeUnavailable,
        error.OutOfMemory => error.HostFailure,
    };
}

fn mapDrainError(err: anyerror) h.HostError {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.HostFailure,
    };
}

/// Read one stream to its end: fill the head, then keep a moving tail, and never stop at the limit, because a full pipe blocks the writer.
/// The Linux pipe capacity, so one read takes a full pipe and the live sink sees few chunks.
const read_buffer_bytes = 64 * 1024;

fn drain(io: std.Io, scratch: std.mem.Allocator, state: *Drain) void {
    var buffer: [read_buffer_bytes]u8 = undefined;
    var reader = state.file.reader(io, &buffer);
    // The bytes of a cut character wait in the reader until the rest arrives.
    var held: usize = 0;
    while (true) {
        const chunk = reader.interface.peekGreedy(held + 1) catch |err| switch (err) {
            error.EndOfStream => return take(io, scratch, state, reader.interface.buffered()),
            error.ReadFailed => {
                state.err = reader.err orelse error.Unexpected;
                return;
            },
        };
        // A live sink gets whole characters, so the other stream never lands inside one.
        const end = if (state.live != null) utf8.whole(chunk) else chunk.len;
        take(io, scratch, state, chunk[0..end]);
        reader.interface.toss(end); // Consume every byte but a cut character, so the writer never blocks.
        held = chunk.len - end;
        if (state.err != null) return;
    }
}

/// Hand one run of bytes to the head, the tail, the log, and the live sink.
fn take(io: std.Io, scratch: std.mem.Allocator, state: *Drain, bytes: []const u8) void {
    if (bytes.len == 0) return;
    // The head takes the odd byte, so the two ends never hold more than the limit.
    const head_cap = state.limit - state.limit / 2;
    const tail_cap = state.limit / 2;
    const to_head = @min(bytes.len, head_cap -| state.head.items.len);
    if (to_head != 0) state.head.appendSlice(scratch, bytes[0..to_head]) catch unreachable;
    if (to_head < bytes.len) keepTail(scratch, state, bytes[to_head..], tail_cap);
    if (state.log) |log| log.append(io, bytes);
    if (state.live) |live| live.write(live.ctx, bytes);
}

/// Append to the tail and drop the oldest bytes above `cap`. The dropped count names the gap.
fn keepTail(scratch: std.mem.Allocator, state: *Drain, bytes: []const u8, cap: usize) void {
    std.debug.assert(state.tail_len <= cap);
    if (cap == 0) {
        state.dropped += bytes.len;
        return;
    }
    if (state.tail.len == 0) state.tail = scratch.alloc(u8, cap) catch unreachable;
    const excess = (state.tail_len + bytes.len) -| cap;
    state.dropped += excess;
    if (bytes.len >= cap) {
        @memcpy(state.tail, bytes[bytes.len - cap ..]);
        state.tail_len = cap;
        state.tail_at = 0;
        return;
    }
    const end = (state.tail_at + state.tail_len) % cap;
    const split = @min(bytes.len, cap - end);
    @memcpy(state.tail[end..][0..split], bytes[0..split]);
    @memcpy(state.tail[0 .. bytes.len - split], bytes[split..]);
    state.tail_at = (state.tail_at + excess) % cap;
    state.tail_len = @min(cap, state.tail_len + bytes.len);
}

const testing = std.testing;

/// The environment every command test borrows. An empty environment allocates nothing, so no test frees it.
var test_env: std.process.Environ.Map = .init(testing.allocator);

/// A behaviour test replaces the child environment, so it must name the PATH its utilities need; every release target holds `cat`, `head`, `tr`, `sleep` and `yes` under these two directories.
fn utilityEnv() !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    return env;
}

fn runShell(a: std.mem.Allocator, command: []const u8, timeout_ms: u32) !Result {
    var env = try utilityEnv();
    defer env.deinit();
    return run(testing.io, "/tmp", execution.testContext(&env), a, .{ .command = command, .timeout_ms = timeout_ms, .max_stream_bytes = 255 });
}

test "the runner spawns the shell it receives and gives it the command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    // A fixture stands in for a shell, so this proves the argument vector without naming a real one.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fake-shell", .data = "#!/bin/sh\necho \"ran $0 with $1 $2\"\n" });
    try tmp.dir.setFilePermissions(testing.io, "fake-shell", .fromMode(0o755), .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fake = try std.fs.path.join(a, &.{ root, "fake-shell" });
    const res = try run(testing.io, root, .{ .env = &test_env, .shell = .{ .path = fake } }, a, .{
        .command = "MARKER",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expect(std.mem.indexOf(u8, res.stdout, fake) != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "with -c MARKER") != null);
}

test "the child reads the environment Yuke resolved, not the one Yuke inherited" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The real process environment holds a different HOME, so only the map can produce this one.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/sentinel/home");
    const with_home = try run(testing.io, "/tmp", execution.testContext(&env), a, .{
        .command = "printf '%s' \"$HOME\"",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expectEqualStrings("/sentinel/home", with_home.stdout);

    // A map with no home directory gives the child none, so Git finds no global configuration.
    const without = try run(testing.io, "/tmp", execution.testContext(&test_env), a, .{
        .command = "printf '%s' \"${HOME-unset}\"",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expectEqualStrings("unset", without.stdout);
}

test "git reads the global configuration from the home directory Yuke resolved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".gitconfig",
        .data = "[user]\n\tname = Yuke Fixture\n\temail = fixture@example.invalid\n",
    });

    var env = try utilityEnv();
    defer env.deinit();
    try env.put("HOME", home);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // This is the reported bug: without the explicit map the child kept the parent home and found nothing.
    const name = try run(testing.io, "/tmp", execution.testContext(&env), a, .{
        .command = "git config --global user.name",
        .timeout_ms = 20_000,
        .max_stream_bytes = 4096,
    });
    if (name.outcome != .exited or name.outcome.exited != 0) return error.SkipZigTest; // no git here
    try testing.expectEqualStrings("Yuke Fixture\n", name.stdout);
}

test "exec keeps the head and the tail of a long stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const res = try runShell(arena.allocator(), "yes abcdefgh | head -c 100000", 20_000);
    try testing.expect(res.stdout_dropped > 0);
    // The command must finish. A drain that stops reading fills the pipe and blocks the writer.
    try testing.expect(res.outcome == .exited);
    // The result keeps both ends, so a failure printed last still reaches the model.
    try testing.expect(std.mem.startsWith(u8, res.stdout, "abcdefgh"));
    // Real content must follow the gap marker. A head-only cap would end the result at the marker.
    const marker = std.mem.indexOf(u8, res.stdout, "dropped").?;
    const tail = res.stdout[marker..];
    try testing.expect(std.mem.indexOf(u8, tail, "abcdefgh") != null);
}

test "a stream at or below the cap keeps every byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `runShell` caps at an odd 255 bytes: 128 fills the head, 129 starts the tail, and 255 fills both.
    for ([_]usize{ 128, 129, 255 }) |len| {
        const command = try std.fmt.allocPrint(arena.allocator(), "head -c {d} /dev/zero | tr '\\0' x", .{len});
        const res = try runShell(arena.allocator(), command, 20_000);
        try testing.expectEqual(@as(u64, 0), res.stdout_dropped);
        try testing.expectEqual(len, res.stdout.len);
        try testing.expect(std.mem.indexOfNone(u8, res.stdout, "x") == null);
    }
}

test "a stream one byte above the cap reports the gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const res = try runShell(arena.allocator(), "head -c 256 /dev/zero | tr '\\0' x", 20_000);
    try testing.expectEqual(@as(u64, 1), res.stdout_dropped);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "dropped 1 bytes") != null);
}

test "the live sink gets every byte of both streams, uncut by the result cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Sink = struct {
        lock: std.Io.Mutex = .init,
        bytes: std.ArrayList(u8) = .empty,
        fn write(ctx: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.lock.lockUncancelable(testing.io);
            defer self.lock.unlock(testing.io);
            self.bytes.appendSlice(testing.allocator, chunk) catch unreachable;
        }
    };
    var sink: Sink = .{};
    defer sink.bytes.deinit(testing.allocator);
    var env = try utilityEnv();
    defer env.deinit();

    const res = try run(testing.io, "/tmp", execution.testContext(&env), arena.allocator(), .{
        .command = "head -c 1000 /dev/zero | tr '\\0' x; sleep 0.1; echo err 1>&2",
        .timeout_ms = 20_000,
        .max_stream_bytes = 255,
        .live = .{ .ctx = &sink, .write = Sink.write },
    });
    try testing.expectEqual(@as(u64, 745), res.stdout_dropped);
    try testing.expectEqual(@as(usize, 1004), sink.bytes.items.len);
    try testing.expect(std.mem.indexOfNone(u8, sink.bytes.items[0..1000], "x") == null);
    try testing.expectEqualStrings("err\n", sink.bytes.items[1000..]);

    // The stdout drain holds a cut character, so the stderr line never lands inside it.
    sink.bytes.clearRetainingCapacity();
    _ = try run(testing.io, "/tmp", execution.testContext(&env), arena.allocator(), .{
        .command = "printf '\\344\\270'; sleep 0.2; echo x 1>&2; sleep 0.2; printf '\\226\\344'",
        .timeout_ms = 20_000,
        .max_stream_bytes = 255,
        .live = .{ .ctx = &sink, .write = Sink.write },
    });
    try testing.expectEqualStrings("x\n\u{4e16}\xe4", sink.bytes.items);
}

test "the gap notice counts the halves of the characters the cap cut at both ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The 255-byte cap keeps a 128-byte head that ends inside an "é" and a 127-byte tail that starts inside one.
    const res = try runShell(a, "printf a; i=0; while [ $i -lt 200 ]; do printf '\\303\\251'; i=$((i+1)); done", 20_000);
    const e63 = "é" ** 63;
    try testing.expectEqualStrings("a" ++ e63 ++ "\n[The tool dropped 148 bytes here.]\n" ++ e63, res.stdout);
    try testing.expectEqual(@as(u64, 146), res.stdout_dropped);
}

test "the child leads a new session apart from the test runner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = try utilityEnv();
    defer env.deinit();

    const null_file = try std.Io.Dir.createFileAbsolute(testing.io, "/dev/null", .{ .truncate = false });
    const null_fd = try aboveStdio(null_file.handle);
    defer _ = std.posix.system.close(null_fd);
    var child = try spawnArgv(arena.allocator(), &env, &.{ execution.fallback_shell, "-c", "exec sleep 30" }, "/tmp", null, null_fd, null_fd);
    const pid = child.id.?;
    // A group kill ends the sleep, so the wait below returns at once and the runner never inherits a stray child.
    defer {
        killGroup(pid, .KILL);
        _ = child.wait(testing.io) catch {};
    }
    try testing.expectEqual(pid, spawn_c.getsid(pid));
    try testing.expectEqual(pid, spawn_c.getpgid(pid));
    // Without SETSID the child would share the session. With SETSID the shell has no controlling terminal.
    try testing.expect(spawn_c.getsid(pid) != spawn_c.getsid(0));
}

test "a command that opens the terminal is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The runner may have no terminal. The session test above proves the detach. This test documents the command result.
    const res = try runShell(arena.allocator(), "( : </dev/tty ) 2>/dev/null && echo opened || echo refused", 10_000);
    try testing.expectEqualStrings("refused\n", res.stdout);
}

test "a missing shell fails the call with HostFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.HostFailure, run(testing.io, "/tmp", .{ .env = &test_env, .shell = .{ .path = "/nonexistent/shell" } }, arena.allocator(), .{
        .command = "echo ran",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    }));
}

test "the child starts with an empty signal mask" {
    // `sh` (dash) clears the inherited mask on start, so only Bash can carry the mask into the proof.
    std.Io.Dir.accessAbsolute(testing.io, "/bin/bash", .{}) catch return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = try utilityEnv();
    defer env.deinit();

    // `posix_spawn` runs on this thread, so the child would inherit this blocked SIGTERM without SETSIGMASK.
    var blocked = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked, .TERM);
    var saved: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &saved);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &saved, null);

    // With an empty mask the SIGTERM ends Bash before the echo. A blocked SIGTERM stays pending and the echo runs.
    const res = try run(testing.io, "/tmp", .{ .env = &env, .shell = .{ .path = "/bin/bash" } }, arena.allocator(), .{
        .command = "kill -TERM $$; echo survived",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expect(res.outcome == .signaled);
    try testing.expectEqual(@as(u8, @intFromEnum(std.posix.SIG.TERM)), res.outcome.signaled);
    try testing.expectEqualStrings("", res.stdout);
}

test "exec ends the whole group at the deadline, with KILL for a shell that ignores TERM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A failed group kill or a failed escalation waits for the full sleep, so this bound proves both.
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), "trap '' TERM; sleep 30 & echo started; wait", 300);
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 10 * std.time.ns_per_s);
    try testing.expect(res.outcome == .timed_out);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "started") != null);
}

test "a tilde cwd without a home directory fails instead of running somewhere else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `test_env` names no home, so the anchor cannot resolve `~` and the command must never start.
    for ([_][]const u8{ "~", "~/child" }) |cwd| {
        try testing.expectError(error.HomeUnavailable, run(testing.io, "/tmp", execution.testContext(&test_env), arena.allocator(), .{
            .command = "echo ran",
            .cwd = cwd,
            .timeout_ms = 10_000,
            .max_stream_bytes = 4096,
        }));
    }
}

test "exec expands a leading tilde in cwd like the file tools" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "marker.txt", .data = "found\n" });

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The workspace root is elsewhere, so only the expansion can reach the file.
    const res = try run(testing.io, "/tmp", execution.testContext(&env), arena.allocator(), .{
        .command = "cat marker.txt",
        .cwd = "~",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expectEqualStrings("found\n", res.stdout);
}

test "exec returns at shell exit and ends what the shell left, with or without its pipes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The first sleep holds the pipe, so a run that waits for EOF lasts until the deadline; the second is the `nohup server >log &` shape.
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), "sleep 30 & echo $!; sleep 30 >/dev/null 2>&1 & echo $!", 20_000);
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 5 * std.time.ns_per_s);
    try testing.expect(res.outcome == .exited and res.outcome.exited == 0);
    var pids = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    for (0..2) |_| try testing.expectError(error.ProcessNotFound, std.posix.kill(try std.fmt.parseInt(std.posix.pid_t, pids.next().?, 10), @enumFromInt(0)));
}

test "exec ends a process that left the session after one grace period" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = try utilityEnv();
    defer env.deinit();
    // `setsid` leaves the group, so no kill reaches it, and the run must still return.
    const setsid = "/usr/bin/setsid";
    std.Io.Dir.accessAbsolute(testing.io, setsid, .{}) catch return error.SkipZigTest;
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), setsid ++ " sleep 10 & echo started", 20_000);
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 5 * std.time.ns_per_s);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "started") != null);
}

test "a cut stream keeps the whole output in the log, and an uncut run deletes it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try utilityEnv();
    defer env.deinit();

    const cut_path = try std.fs.path.join(a, &.{ root, "cut.log" });
    const cut = try run(testing.io, root, execution.testContext(&env), a, .{ .command = "head -c 1000 /dev/zero | tr '\\0' x; echo tail 1>&2", .timeout_ms = 10_000, .max_stream_bytes = 64, .log = cut_path });
    try testing.expect(cut.stdout_dropped > 0);
    try testing.expectEqualStrings(cut_path, cut.log.?);
    const logged = try tmp.dir.readFileAlloc(testing.io, "cut.log", a, .limited(4096));
    try testing.expectEqual(@as(usize, 1005), logged.len);
    try testing.expect(std.mem.indexOf(u8, logged, "tail\n") != null);

    const whole_path = try std.fs.path.join(a, &.{ root, "whole.log" });
    const whole = try run(testing.io, root, execution.testContext(&env), a, .{ .command = "echo short", .timeout_ms = 10_000, .max_stream_bytes = 64, .log = whole_path });
    try testing.expect(whole.log == null);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "whole.log", .{}));
}

test "the tail keeps the exact suffix across wrap, oversize chunks, and zero capacity" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "abcdefghijklmnopqrstuvwxyz0123456789";
    for ([_]usize{ 0, 1, 2, 7, 16, 35, 36, 64 }) |cap| {
        for ([_]usize{ 1, 3, 8, 36 }) |chunk| {
            var state: Drain = .{ .file = undefined, .limit = @intCast(cap), .log = null, .live = null };
            var at: usize = 0;
            while (at < input.len) {
                const end = @min(input.len, at + chunk);
                keepTail(a, &state, input[at..end], cap);
                at = end;
                const kept = @min(cap, at);
                try testing.expectEqual(kept, state.tail_len);
                try testing.expectEqual(at - kept, state.dropped);
                for (0..kept) |i| try testing.expectEqual(input[at - kept + i], state.tail[(state.tail_at + i) % cap]);
            }
        }
    }
}
