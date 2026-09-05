//! Run one command natively over `std.Io`. The child gets its own process group. A deadline or a
//! cancel kills that group, so a descendant of the shell does not survive the call.
//! A descendant that calls `setsid` leaves the group.

const std = @import("std");
const h = @import("operations.zig");
const paths = @import("../../paths.zig");

/// The wait between SIGTERM and SIGKILL. A shell runs its SIGTERM trap in this time.
const grace_ns: u64 = 2 * std.time.ns_per_s;

/// One drain leg. It reads one stream to its end and keeps its head AND its tail. A build prints its
/// error last, so a head-only cap would drop the part the model needs most.
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

    /// Join the head and the tail with one notice between them. The result comes from `scratch`.
    /// Each end stops on a byte, so the notice counts the codepoint the cap cut in half.
    fn text(self: *Drain, scratch: std.mem.Allocator) []const u8 {
        if (self.dropped == 0) {
            if (self.tail.items.len == 0) return self.head.items;
            // No byte went, so the two ends stay adjacent. The join restores the exact stream.
            var whole: std.ArrayList(u8) = .empty;
            whole.appendSlice(scratch, self.head.items) catch unreachable;
            whole.appendSlice(scratch, self.tail.items) catch unreachable;
            return whole.toOwnedSlice(scratch) catch unreachable;
        }
        const head = headFloor(self.head.items);
        const tail = tailCeil(self.tail.items);
        const trimmed = (self.head.items.len - head.len) + (self.tail.items.len - tail.len);
        var joined: std.ArrayList(u8) = .empty;
        joined.appendSlice(scratch, head) catch unreachable;
        joined.print(scratch, "\n[The tool dropped {d} bytes here.]\n", .{self.dropped + trimmed}) catch unreachable;
        joined.appendSlice(scratch, tail) catch unreachable;
        return joined.toOwnedSlice(scratch) catch unreachable;
    }
};

/// Drop the trailing bytes of a codepoint the head cap cut. These helpers remove the half a cap
/// splits; `exec` replaces the bytes that are invalid for any other reason.
fn headFloor(bytes: []const u8) []const u8 {
    var i = bytes.len;
    var back: usize = 0;
    // A codepoint uses at most 4 bytes, so at most 3 continuation bytes follow its start byte.
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        if (bytes[i] & 0xC0 == 0x80) continue;
        const need = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return bytes[0..i];
        return if (bytes.len - i >= need) bytes else bytes[0..i];
    }
    return bytes;
}

/// Drop the leading continuation bytes of a codepoint the tail cap cut.
fn tailCeil(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and i < 4 and bytes[i] & 0xC0 == 0x80) : (i += 1) {}
    return bytes[i..];
}

/// Run `spec` and return its output. The caller must validate `spec`; this function returns an error
/// instead of an assertion, because the function receives validated tool input.
pub fn run(io: std.Io, root: []const u8, env: ?*const std.process.Environ.Map, scratch: std.mem.Allocator, spec: h.ExecSpec) h.HostError!h.ExecResult {
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
    // Every error path below must end the group and reap the child. A missed reap leaves a live
    // process and two open pipe descriptors, because `child.wait` owns that cleanup.
    errdefer terminate(io, &group, &child, pid);

    group.concurrent(io, drain, .{ io, scratch, &out }) catch return error.HostFailure;
    group.concurrent(io, drain, .{ io, scratch, &err }) catch return error.HostFailure;

    // A process exits while its pipes still hold output. Both drains must reach the end before the
    // reap, or the result loses the tail.
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

/// Wait for both drains. Escalate over the group on the deadline. Return true after a deadline.
/// A cancel returns `error.Canceled`, never a deadline, so the model never reads a false timeout.
fn awaitDrains(io: std.Io, group: *std.Io.Group, pid: std.posix.pid_t, timeout_ms: u32) h.HostError!bool {
    var done: std.Io.Event = .unset;
    var waiter = io.concurrent(joinGroup, .{ io, group, &done }) catch return error.HostFailure;
    const deadline: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake };
    done.waitTimeout(io, .{ .duration = deadline }) catch |wait_err| {
        escalate(io, pid);
        done.wait(io) catch {}; // The drains end when the group dies.
        // `Future.await` is uncancelable, so the waiter always joins before the group is cleaned up.
        _ = waiter.await(io);
        return switch (wait_err) {
            error.Timeout => true,
            error.Canceled => error.Canceled,
        };
    };
    _ = waiter.await(io);
    return false;
}

/// Kill the whole process group. The grace period blocks cancelation, so a canceled run still gives
/// the shell its full time to run a SIGTERM trap.
fn escalate(io: std.Io, pid: std.posix.pid_t) void {
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);
    killGroup(pid, .TERM);
    std.Io.sleep(io, .fromNanoseconds(grace_ns), .awake) catch {};
    killGroup(pid, .KILL);
}

/// End the command and release every resource it holds. This runs on an error path, so it blocks
/// cancelation. Without the reap the engine keeps a live process and two pipe descriptors.
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
fn resolveCwd(scratch: std.mem.Allocator, root: []const u8, env: ?*const std.process.Environ.Map, cwd: ?[]const u8) h.HostError![]const u8 {
    const rel = cwd orelse return root;
    return paths.anchorAt(scratch, env, root, rel) catch unreachable;
}

fn mapDrainError(err: anyerror) h.HostError {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.HostFailure,
    };
}

/// Read one stream to its end. Fill the head, then keep a moving tail. The read must continue past
/// the limit. A full pipe blocks the writer, and the command never reaches its end.
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

fn runShell(a: std.mem.Allocator, command: []const u8, timeout_ms: u32) !h.ExecResult {
    return run(testing.io, "/tmp", null, a, .{ .command = command, .timeout_ms = timeout_ms, .max_stream_bytes = 256 });
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
    const res = try run(testing.io, root, null, arena.allocator(), .{
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

test "a cap that splits a codepoint drops the half instead of the whole end" {
    // The head stops inside a three-byte codepoint, so only that codepoint goes.
    try testing.expectEqualStrings("ok", headFloor("ok\xe6\x96"));
    try testing.expectEqualStrings("ok\u{65b0}", headFloor("ok\u{65b0}"));
    // A trailing byte that starts nothing valid also goes.
    try testing.expectEqualStrings("ok", headFloor("ok\xff"));

    // The tail starts on continuation bytes, so those bytes go.
    try testing.expectEqualStrings("ok", tailCeil("\x96\xb0ok"));
    try testing.expectEqualStrings("\u{65b0}ok", tailCeil("\u{65b0}ok"));

    // An empty end and a whole ASCII end both stay as they are.
    try testing.expectEqualStrings("", headFloor(""));
    try testing.expectEqualStrings("", tailCeil(""));
    try testing.expectEqualStrings("plain", tailCeil("plain"));

    // A complete sequence stays whole even when it is invalid, because `exec` replaces it.
    try testing.expectEqualStrings("\xed\xa0\x80", headFloor("\xed\xa0\x80")); // a surrogate
    try testing.expectEqualStrings("\xf5ok", tailCeil("\xf5ok")); // past U+10FFFF

    // A four-byte codepoint sits at the scan bound on both ends.
    try testing.expectEqualStrings("a", headFloor("a\xf0\x9f\x98")); // cut before its last byte
    try testing.expectEqualStrings("a\u{1f600}", headFloor("a\u{1f600}"));
    try testing.expectEqualStrings("ok", tailCeil("\x9f\x98\x80ok"));
}

test "exec kills the whole process group at the deadline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The shell exits at once, but the grandchild holds the pipe open. Only a group kill ends this.
    // A single-child kill would leave the grandchild alive and the drain would never reach the end.
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
