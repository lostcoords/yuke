//! One cancelable call site. A child task runs the blocking work, so a stop can interrupt it.

const std = @import("std");

/// What one child task returned to the caller that waited for it.
pub const ChildResult = union(enum) {
    returned: anyerror!void,
    /// A cancel reached this call site. The child stopped.
    canceled,
    /// A cancel stopped the owning task, so the caller must unwind.
    aborted,
};

/// The stop flag and the wake event one call site shares with whoever cancels it.
pub const Cancel = struct {
    requested: std.atomic.Value(bool) = .init(false),
    /// A cancel sets this event, so a waiter never sleeps through a stop.
    event: std.Io.Event = .unset,

    pub fn isRequested(self: *const Cancel) bool {
        return self.requested.load(.acquire);
    }

    /// Ask this call site to stop, then wake whoever waits on it.
    pub fn request(self: *Cancel, io: std.Io) void {
        self.requested.store(true, .release);
        self.event.set(io);
    }

    /// Report that the child finished, so the caller stops waiting for it.
    pub fn finish(self: *Cancel, io: std.Io) void {
        self.event.set(io);
    }

    /// Return `error.Canceled` when this call site or the owning task stopped.
    pub fn check(self: *const Cancel, io: std.Io) !void {
        try io.checkCancel();
        if (self.isRequested()) return error.Canceled;
    }

    /// Run `f` in a child task, so a cancel can interrupt a blocked call.
    pub fn runChild(self: *Cancel, io: std.Io, comptime f: anytype, args: anytype) ChildResult {
        return self.runChildTimeout(io, .none, f, args) catch unreachable;
    }

    /// A deadline cancels and joins the child before it returns Timeout.
    pub fn runChildTimeout(self: *Cancel, io: std.Io, timeout: std.Io.Timeout, comptime f: anytype, args: anytype) error{Timeout}!ChildResult {
        self.event.reset();

        var child = io.concurrent(f, args) catch |err| return .{ .returned = err };
        const deadline = timeout.toDeadline(io);
        while (!self.isRequested()) {
            self.event.waitTimeout(io, deadline) catch |err| {
                if (err == error.Timeout) {
                    if (deadline == .none) continue;
                    const due = deadline.deadline;
                    if (std.Io.Timestamp.now(io, due.clock).nanoseconds < due.raw.nanoseconds) continue;
                    child.cancel(io) catch {};
                    return error.Timeout;
                }
                child.cancel(io) catch {};
                return .aborted;
            };
            break;
        }

        if (self.isRequested()) {
            child.cancel(io) catch {}; // Interrupt a blocked call, then join the child.
            return .canceled;
        }

        return .{ .returned = child.await(io) };
    }

    /// Hold for `delay_ms` and report whether a cancel arrived. A plain sleep would ignore the event.
    pub fn holdFor(self: *Cancel, io: std.Io, delay_ms: u64) !bool {
        self.event.reset();
        if (self.isRequested()) return true;

        const waited: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(@intCast(delay_ms)), .clock = .awake };
        self.event.waitTimeout(io, .{ .duration = waited }) catch |err| switch (err) {
            error.Timeout => return self.isRequested(), // The delay elapsed. The caller continues.
            else => return err,
        };

        return true; // Only a cancel sets the event.
    }
};

test "a prior cancel survives a child reset and a retry delay" {
    const testing = std.testing;
    var cancel: Cancel = .{};
    cancel.request(testing.io);
    var interrupted = false;
    const Child = struct {
        fn run(token: *Cancel, was_interrupted: *bool) error{}!void {
            defer token.finish(std.testing.io);
            std.Io.sleep(std.testing.io, .fromSeconds(2), .awake) catch {
                was_interrupted.* = true;
            };
        }
    };
    try testing.expect(cancel.runChild(testing.io, Child.run, .{ &cancel, &interrupted }) == .canceled);
    try testing.expect(interrupted);
    try testing.expect(try cancel.holdFor(testing.io, 60_000));
}
