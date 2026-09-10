//! Run one command natively over `std.Io`. The child gets its own process group. A deadline or a
//! cancel kills that group, so a descendant of the shell does not survive the call.
//! A descendant that calls `setsid` leaves the group.

const std = @import("std");
const utf8 = @import("../../utf8.zig");
const h = @import("operations.zig");
const paths = @import("../../paths.zig");

/// The wait between SIGTERM and SIGKILL. A shell runs its SIGTERM trap in this time.
const grace_ns: u64 = 2 * std.time.ns_per_s;

/// One drain leg: it reads one stream to its end and keeps its head and its tail, because a build prints its error last.
const Drain = struct {
    file: std.Io.File,
    limit: u32,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    dropped: u64 = 0,
    err: ?anyerror = null,

    /// Half the limit for each end.
    fn half(self: *const Drain) usize {
        return @max(1, self.limit / 2);
    }

    /// Join the head and the tail with one notice between them, from `scratch`; the notice counts the codepoint the cap cut in half.
    fn text(self: *Drain, scratch: std.mem.Allocator) []const u8 {
        if (self.dropped == 0) {
            if (self.tail.items.len == 0) return self.head.items;
            // No byte went, so the two ends stay adjacent. The join restores the exact stream.
            var whole: std.ArrayList(u8) = .empty;
            whole.appendSlice(scratch, self.head.items) catch unreachable;
            whole.appendSlice(scratch, self.tail.items) catch unreachable;
            return whole.toOwnedSlice(scratch) catch unreachable;
        }
        const head = self.head.items[0..utf8.whole(self.head.items)];
        const tail = self.tail.items[utf8.head(self.tail.items)..];
        const trimmed = (self.head.items.len - head.len) + (self.tail.items.len - tail.len);
        var joined: std.ArrayList(u8) = .empty;
        joined.appendSlice(scratch, head) catch unreachable;
        joined.print(scratch, "\n[The tool dropped {d} bytes here.]\n", .{self.dropped + trimmed}) catch unreachable;
        joined.appendSlice(scratch, tail) catch unreachable;
        return joined.toOwnedSlice(scratch) catch unreachable;
    }
};

/// Run `spec` and return its output. It returns an error rather than an assertion, because `spec` is validated tool input.
pub fn run(io: std.Io, root: []const u8, env: *const std.process.Environ.Map, scratch: std.mem.Allocator, spec: h.ExecSpec) h.HostError!h.ExecResult {
    if (spec.timeout_ms == 0 or spec.max_stream_bytes == 0) return error.HostFailure;
    const cwd = try resolveCwd(scratch, root, env, spec.cwd);
    const argv = [_][]const u8{ "/bin/sh", "-c", spec.command };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // A zero makes the child its own group leader. Its process group id then equals its pid.
        .pgid = 0,
    }) catch return error.HostFailure;
    const pid = child.id.?;

    var out: Drain = .{ .file = child.stdout.?, .limit = spec.max_stream_bytes };
    var err: Drain = .{ .file = child.stderr.?, .limit = spec.max_stream_bytes };
    var group: std.Io.Group = .init;
    // Every error path below must end the group and reap the child, because `child.wait` owns the pipe cleanup.
    errdefer terminate(io, &group, &child, pid);

    group.concurrent(io, drain, .{ io, scratch, &out }) catch return error.HostFailure;
    group.concurrent(io, drain, .{ io, scratch, &err }) catch return error.HostFailure;

    // A process exits while its pipes still hold output, so both drains must reach the end before the reap.
    const timed_out = try awaitDrains(io, &group, pid, spec.timeout_ms);
    if (out.err) |e| return mapDrainError(e);
    if (err.err) |e| return mapDrainError(e);

    const term = child.wait(io) catch return error.HostFailure;
    return .{
        .stdout = out.text(scratch),
        .stderr = err.text(scratch),
        .outcome = if (timed_out)
            .timed_out
        else switch (term) {
            .exited => |code| .{ .exited = code },
            .signal => |sig| .{ .signaled = std.math.cast(u8, @intFromEnum(sig)) orelse 0 },
            else => .{ .exited = 0 },
        },
        .stdout_dropped = out.dropped,
        .stderr_dropped = err.dropped,
    };
}

/// Wait for both drains and escalate over the group at the deadline; true after a deadline, while a cancel is `error.Canceled` and never a false timeout.
fn awaitDrains(io: std.Io, group: *std.Io.Group, pid: std.posix.pid_t, timeout_ms: u32) h.HostError!bool {
    var done: std.Io.Event = .unset;
    var waiter = io.concurrent(joinGroup, .{ io, group, &done }) catch return error.HostFailure;
    const deadline: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake };
    done.waitTimeout(io, .{ .duration = deadline }) catch |wait_err| {
        if (wait_err == error.Canceled) {
            _ = waiter.cancel(io);
            return error.Canceled;
        }
        escalate(io, pid);
        done.wait(io) catch {}; // The drains end when the group dies.
        // `Future.await` is uncancelable, so the waiter always joins before the group is cleaned up.
        _ = waiter.await(io);
        return true;
    };
    _ = waiter.await(io);
    return false;
}

/// Kill the whole process group. The grace period blocks cancelation, so a canceled run still gives the shell its SIGTERM trap time.
fn escalate(io: std.Io, pid: std.posix.pid_t) void {
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    killGroup(pid, .TERM);
    std.Io.sleep(io, .fromNanoseconds(grace_ns), .awake) catch {};
    killGroup(pid, .KILL);
}

/// End the command and release every resource it holds. It blocks cancelation, because a missed reap leaks a process and two pipes.
fn terminate(io: std.Io, group: *std.Io.Group, child: *std.process.Child, pid: std.posix.pid_t) void {
    escalate(io, pid);
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    group.cancel(io);
    _ = child.wait(io) catch {}; // `wait` closes the pipe descriptors.
}

/// Signal a whole process group. A negative pid names the group, so every member receives it.
fn killGroup(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    std.posix.kill(-pid, sig) catch |err| switch (err) {
        error.ProcessNotFound => {}, // The group already ended.
        else => {},
    };
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

fn runShell(a: std.mem.Allocator, command: []const u8, timeout_ms: u32) !h.ExecResult {
    return run(testing.io, "/tmp", &test_env, a, .{ .command = command, .timeout_ms = timeout_ms, .max_stream_bytes = 256 });
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
    const res = try run(testing.io, root, &test_env, arena.allocator(), .{
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

test "exec kills the whole process group at the deadline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The shell exits at once, but the grandchild holds the pipe open, so only a group kill lets the drain reach the end.
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    const res = try runShell(arena.allocator(), "sleep 30 & echo started; exit 0", 400);
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
        try testing.expectError(error.HomeUnavailable, run(testing.io, "/tmp", &test_env, arena.allocator(), .{
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
    const res = try run(testing.io, "/tmp", &env, arena.allocator(), .{
        .command = "cat marker.txt",
        .cwd = "~",
        .timeout_ms = 10_000,
        .max_stream_bytes = 4096,
    });
    try testing.expectEqualStrings("found\n", res.stdout);
}
