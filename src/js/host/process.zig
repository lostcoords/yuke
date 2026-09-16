//! Run one command natively over `std.Io`. The child leads a new session with no controlling terminal.
//! A deadline or a cancel kills its process group, so a descendant of the shell does not survive the call.
//! A descendant that calls `setsid` leaves the group.

const std = @import("std");
const spawn_c = @import("spawn_c");
const utf8 = @import("../../utf8.zig");
const h = @import("operations.zig");
const paths = @import("../../paths.zig");
const execution = @import("../../execution.zig");

/// One command to run. `cwd` is relative to the workspace root. A null `cwd` uses the root itself.
pub const Spec = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: u32,
    /// The cap for each stream. The runner keeps the head and the tail and reports the cut.
    max_stream_bytes: u32,
    /// An absolute path. The run writes both streams to it and keeps the file only when a stream was cut.
    log: ?[]const u8 = null,
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

/// What one command produced. `stdout` and `stderr` come from `scratch`.
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
const grace_ns: u64 = if (@import("builtin").is_test) 100 * std.time.ns_per_ms else 2 * std.time.ns_per_s;

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

/// One drain leg: it reads one stream to its end and keeps its head and its tail, because a build prints its error last.
const Drain = struct {
    file: std.Io.File,
    limit: u32,
    log: ?*Log,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    dropped: u64 = 0,
    err: ?anyerror = null,

    /// Half the limit for each end.
    fn half(self: *const Drain) usize {
        return @max(1, self.limit / 2);
    }

    /// Join the head and the tail from `scratch`, with one notice at a gap; the notice counts the codepoint the cap cut in half.
    fn text(self: *Drain, scratch: std.mem.Allocator) []const u8 {
        if (self.tail.items.len == 0) return self.head.items;
        // With no gap the two ends stay adjacent, so the join restores the exact stream.
        const gap = self.dropped != 0;
        const head = if (gap) self.head.items[0..utf8.whole(self.head.items)] else self.head.items;
        const tail = if (gap) self.tail.items[utf8.head(self.tail.items)..] else self.tail.items;
        const trimmed = (self.head.items.len - head.len) + (self.tail.items.len - tail.len);
        var joined: std.ArrayList(u8) = .empty;
        joined.appendSlice(scratch, head) catch unreachable;
        if (gap) joined.print(scratch, "\n[The tool dropped {d} bytes here.]\n", .{self.dropped + trimmed}) catch unreachable;
        joined.appendSlice(scratch, tail) catch unreachable;
        return joined.toOwnedSlice(scratch) catch unreachable;
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
    var out: Drain = .{ .file = pipeReader(out_pipe[0]), .limit = spec.max_stream_bytes, .log = if (log) |*l| l else null };
    defer out.file.close(io);
    const err_pipe = pipeAboveStdio() catch |e| {
        _ = std.posix.system.close(out_pipe[1]);
        return e;
    };
    var err: Drain = .{ .file = pipeReader(err_pipe[0]), .limit = spec.max_stream_bytes, .log = if (log) |*l| l else null };
    defer err.file.close(io);

    // The parent closes its write ends after the spawn, so a drain reaches EOF when the last child copy closes.
    var child = spawned: {
        defer _ = std.posix.system.close(out_pipe[1]);
        defer _ = std.posix.system.close(err_pipe[1]);
        break :spawned try spawnSession(scratch, context, spec.command, cwd, out_pipe[1], err_pipe[1]);
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
    // The shell is reaped, and a process it left holds the group id, so this kill reaches no other group.
    if (groupAlive(pid)) endGroups(io, &.{pid});
    const abandoned = try awaitDrains(io, &drains);
    if (out.err) |e| if (!abandoned) return mapDrainError(e);
    if (err.err) |e| if (!abandoned) return mapDrainError(e);

    const cut = out.dropped + err.dropped != 0;
    const kept: ?[]const u8 = if (log) |*l| if (cut and !l.failed.load(.monotonic)) spec.log.? else blk: {
        std.Io.Dir.deleteFileAbsolute(io, spec.log.?) catch {};
        break :blk null;
    } else null;

    return .{
        .stdout = out.text(scratch),
        .stderr = err.text(scratch),
        .outcome = if (timed_out) .timed_out else outcomeOf(term orelse return error.HostFailure),
        .stdout_dropped = out.dropped,
        .stderr_dropped = err.dropped,
        .log = kept,
    };
}

/// Spawn `shell -c command` as the leader of a new session with stdout and stderr on the given descriptors. A program that opens `/dev/tty` then fails at once with no terminal.
/// TODO: use a session flag from `std.process.SpawnOptions` when Zig std gains that flag, then delete `src/c/spawn.h`.
fn spawnSession(scratch: std.mem.Allocator, context: execution.Context, command: []const u8, cwd: []const u8, stdout: std.posix.fd_t, stderr: std.posix.fd_t) h.HostError!std.process.Child {
    std.debug.assert(std.fs.path.isAbsolute(context.shell.path));
    std.debug.assert(std.fs.path.isAbsolute(cwd));
    // A `dup2` onto its own number keeps CLOEXEC, so both sources must sit above the standard streams.
    std.debug.assert(stdout > std.posix.STDERR_FILENO and stderr > std.posix.STDERR_FILENO);
    // The shell reads one language string, which no direct program execution can accept.
    const shell_z = scratch.dupeZ(u8, context.shell.path) catch return error.HostFailure;
    const command_z = scratch.dupeZ(u8, command) catch return error.HostFailure;
    const cwd_z = scratch.dupeZ(u8, cwd) catch return error.HostFailure;
    const argv = [_:null]?[*:0]const u8{ shell_z.ptr, "-c", command_z.ptr };
    // The block replaces the raw process environment, so the child sees the recovered home. It drops `ZIG_PROGRESS` as std does.
    const envp = context.env.createPosixBlock(scratch, .{ .zig_progress_fd = -1 }) catch return error.HostFailure;

    var actions: spawn_c.posix_spawn_file_actions_t = undefined;
    try checkSpawn(spawn_c.posix_spawn_file_actions_init(&actions));
    defer std.debug.assert(spawn_c.posix_spawn_file_actions_destroy(&actions) == 0);
    try checkSpawn(spawn_c.posix_spawn_file_actions_addopen(&actions, std.posix.STDIN_FILENO, "/dev/null", spawn_c.O_RDONLY, 0));
    try checkSpawn(spawn_c.posix_spawn_file_actions_adddup2(&actions, stdout, std.posix.STDOUT_FILENO));
    try checkSpawn(spawn_c.posix_spawn_file_actions_adddup2(&actions, stderr, std.posix.STDERR_FILENO));
    try checkSpawn(spawn_c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z.ptr));

    var attr: spawn_c.posix_spawnattr_t = undefined;
    try checkSpawn(spawn_c.posix_spawnattr_init(&attr));
    defer std.debug.assert(spawn_c.posix_spawnattr_destroy(&attr) == 0);
    // The empty mask keeps a signal the caller blocks from staying blocked in the shell.
    var empty_mask: spawn_c.sigset_t = undefined;
    try checkSpawn(spawn_c.sigemptyset(&empty_mask));
    try checkSpawn(spawn_c.posix_spawnattr_setsigmask(&attr, &empty_mask));
    // SETSID makes pid, pgid and sid equal, so `killGroup(pid)` reaches every process the shell starts.
    const flags: c_short = @intCast(spawn_c.POSIX_SPAWN_SETSID | spawn_c.POSIX_SPAWN_SETSIGMASK);
    try checkSpawn(spawn_c.posix_spawnattr_setflags(&attr, flags));

    // A failed exec returns here as an error with no child left behind, so the caller has nothing to reap.
    var pid: spawn_c.pid_t = undefined;
    try checkSpawn(spawn_c.posix_spawn(&pid, shell_z.ptr, &actions, &attr, @ptrCast(&argv), @ptrCast(envp.slice.ptr)));
    std.debug.assert(pid > 0);
    // The child holds no stream, so `wait` closes nothing and the caller owns every descriptor.
    return .{ .id = pid, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
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

/// Create a CLOEXEC pipe with its write end above the standard streams. The read end may stay low.
fn pipeAboveStdio() h.HostError![2]std.posix.fd_t {
    const fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.HostFailure;
    const write_end = aboveStdio(fds[1]) catch {
        _ = std.posix.system.close(fds[0]);
        return error.HostFailure;
    };
    return .{ fds[0], write_end };
}

/// Start `shell -c command` in a new session with both streams on a new file at `log`. The caller must reap the child with `reapJob`.
pub fn startJob(io: std.Io, root: []const u8, context: execution.Context, scratch: std.mem.Allocator, command: []const u8, cwd: ?[]const u8, log: []const u8) h.HostError!std.process.Child {
    std.debug.assert(std.fs.path.isAbsolute(log));
    const dir = try resolveCwd(scratch, root, context.env, cwd);
    const file = std.Io.Dir.createFileAbsolute(io, log, .{}) catch return error.HostFailure;
    const fd = try aboveStdio(file.handle);
    defer _ = std.posix.system.close(fd);
    return spawnSession(scratch, context, command, dir, fd, fd);
}

/// Reap a job with cancelation blocked, then end what the shell left in its group. It returns only after the shell dies.
pub fn reapJob(io: std.Io, child: *std.process.Child) ?Outcome {
    const pid = child.id.?;
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    const term = child.wait(io) catch null;
    if (groupAlive(pid)) endGroups(io, &.{pid});
    return if (term) |t| outcomeOf(t) else null;
}

fn outcomeOf(term: std.process.Child.Term) Outcome {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signaled = std.math.cast(u8, @intFromEnum(sig)) orelse 0 },
        else => .{ .exited = 0 },
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

/// Give the drains one grace period after the group ends, and answer true when they were cut. A descendant that left the session can hold a pipe open forever.
fn awaitDrains(io: std.Io, drains: *std.Io.Group) h.HostError!bool {
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

/// End process groups: TERM, then KILL after one shared grace period. It returns early when every group is gone, and it blocks cancelation, so a shell always gets its SIGTERM trap time.
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
fn drain(io: std.Io, scratch: std.mem.Allocator, state: *Drain) void {
    var buffer: [4096]u8 = undefined;
    var reader = state.file.reader(io, &buffer);
    const half = state.half();
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => {
                state.err = reader.err orelse error.Unexpected;
                return;
            },
        };
        const to_head = @min(chunk.len, half -| state.head.items.len);
        if (to_head != 0) state.head.appendSlice(scratch, chunk[0..to_head]) catch unreachable;
        if (to_head < chunk.len) keepTail(scratch, state, chunk[to_head..], half);
        if (state.log) |log| log.append(io, chunk);
        reader.interface.toss(chunk.len); // Consume every byte, so the writer never blocks.
        if (state.err != null) return;
    }
}

/// Append to the tail and drop the oldest bytes above `half`. The dropped count names the gap.
fn keepTail(scratch: std.mem.Allocator, state: *Drain, bytes: []const u8, half: usize) void {
    state.tail.appendSlice(scratch, bytes) catch unreachable;
    if (state.tail.items.len <= half) return;
    const excess = state.tail.items.len - half;
    std.mem.copyForwards(u8, state.tail.items, state.tail.items[excess..]);
    state.tail.shrinkRetainingCapacity(half);
    state.dropped += excess;
}

const testing = std.testing;

/// The environment every command test borrows. An empty environment allocates nothing, so no test frees it.
var test_env: std.process.Environ.Map = .init(testing.allocator);

/// A behaviour test replaces the child environment, so it must name the PATH its utilities need.
/// Every release target holds `cat`, `head`, `tr`, `sleep` and `yes` under these two directories.
fn utilityEnv() !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    return env;
}

fn runShell(a: std.mem.Allocator, command: []const u8, timeout_ms: u32) !Result {
    var env = try utilityEnv();
    defer env.deinit();
    return run(testing.io, "/tmp", execution.testContext(&env), a, .{ .command = command, .timeout_ms = timeout_ms, .max_stream_bytes = 256 });
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

test "exec captures stdout, stderr, and the exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ok = try runShell(arena.allocator(), "echo out; echo bad >&2; exit 3", 10_000);
    try testing.expectEqualStrings("out\n", ok.stdout);
    try testing.expectEqualStrings("bad\n", ok.stderr);
    try testing.expect(ok.outcome.exited == 3);
    try testing.expectEqual(@as(u64, 0), ok.stdout_dropped);
}

test "exec runs in the requested working directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "marker.txt", .data = "here\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = try utilityEnv();
    defer env.deinit();
    const res = try run(testing.io, root, execution.testContext(&env), arena.allocator(), .{
        .command = "cat marker.txt",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expectEqualStrings("here\n", res.stdout);
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

    // `runShell` caps at 256 bytes, so each end holds 128 and a length within the cap keeps all.
    for ([_]usize{ 127, 128, 129, 255, 256 }) |len| {
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

    const res = try runShell(arena.allocator(), "head -c 257 /dev/zero | tr '\\0' x", 20_000);
    try testing.expectEqual(@as(u64, 1), res.stdout_dropped);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "dropped 1 bytes") != null);
}

test "the child leads a new session apart from the test runner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = try utilityEnv();
    defer env.deinit();

    const null_file = try std.Io.Dir.createFileAbsolute(testing.io, "/dev/null", .{ .truncate = false });
    const null_fd = try aboveStdio(null_file.handle);
    defer _ = std.posix.system.close(null_fd);
    var child = try spawnSession(arena.allocator(), execution.testContext(&env), "exec sleep 30", "/tmp", null_fd, null_fd);
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

test "exec kills the whole process group at the deadline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The shell waits for its child, so only a group kill at the deadline ends both.
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), "sleep 30 & echo started; wait", 400);
    // A failed group kill waits for the full sleep, so this bound is what proves the kill.
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 10 * std.time.ns_per_s);
    try testing.expect(res.outcome == .timed_out);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "started") != null);
}

test "exec ends a command that ignores SIGTERM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The trap swallows SIGTERM. Only the SIGKILL after the grace period ends this command.
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), "trap '' TERM; sleep 30", 300);
    // A failed escalation waits for the full 30-second sleep.
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 10 * std.time.ns_per_s);
    try testing.expect(res.outcome == .timed_out);
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

test "exec returns when the shell exits and ends the processes it left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The background sleep holds the pipe, so a run that waits for EOF would last until the deadline.
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), "sleep 30 & echo $! ; echo started", 20_000);
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 5 * std.time.ns_per_s);
    try testing.expect(res.outcome == .exited and res.outcome.exited == 0);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "started") != null);
    const left = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, res.stdout[0..std.mem.indexOfScalar(u8, res.stdout, '\n').?], " "), 10);
    // The sleep was reparented, so only a failed group kill leaves it alive.
    try testing.expectError(error.ProcessNotFound, std.posix.kill(left, @enumFromInt(0)));
}

test "exec ends a detached process that redirected its output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // This is the `nohup server >log &` shape: the pipes close at exit, but the server must not survive.
    const res = try runShell(arena.allocator(), "sleep 30 >/dev/null 2>&1 & echo $!", 20_000);
    try testing.expect(res.outcome == .exited);
    const left = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, res.stdout, " \n"), 10);
    try testing.expectError(error.ProcessNotFound, std.posix.kill(left, @enumFromInt(0)));
}

test "a command that leaves nothing behind gains no grace delay" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const started: std.Io.Timestamp = .now(testing.io, .awake);
    for (0..5) |_| _ = try runShell(arena.allocator(), "echo fast", 10_000);
    // Five runs with a full grace period each would take at least 500 ms in tests.
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 400 * std.time.ns_per_ms);
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
    const res = try runShell(arena.allocator(), setsid ++ " sleep 2 & echo started", 20_000);
    try testing.expect(started.durationTo(.now(testing.io, .awake)).toNanoseconds() < 1500 * std.time.ns_per_ms);
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
