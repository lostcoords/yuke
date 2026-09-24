//! One cancelable call site. A child task runs the blocking work, so a stop can interrupt it.

const std = @import("std");
const util = @import("util.zig");

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

    /// Return `error.Canceled` when this call site or the owning task stopped.
    pub fn check(self: *const Cancel, io: std.Io) !void {
        try io.checkCancel();
        if (self.isRequested()) return error.Canceled;
    }

    /// Run `f` in a child task, so a cancel can interrupt a blocked call; the end of `f` wakes the caller.
    pub fn runChild(self: *Cancel, io: std.Io, comptime f: anytype, args: anytype) ChildResult {
        return self.runChildTimeout(io, .none, f, args) catch unreachable;
    }

    /// A deadline cancels and joins the child before it returns Timeout.
    pub fn runChildTimeout(self: *Cancel, io: std.Io, timeout: std.Io.Timeout, comptime f: anytype, args: anytype) error{Timeout}!ChildResult {
        self.event.reset();
        const Child = struct {
            fn run(cancel: *Cancel, child_io: std.Io, child_args: @TypeOf(args)) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
                defer cancel.event.set(child_io);
                return @call(.auto, f, child_args);
            }
        };
        var child = io.concurrent(Child.run, .{ self, io, args }) catch |err| return .{ .returned = err };
        if (!self.isRequested()) {
            const woke = util.waitEvent(io, &self.event, timeout) catch {
                child.cancel(io) catch {};
                return .aborted;
            };
            if (!woke) {
                child.cancel(io) catch {};
                return error.Timeout;
            }
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
        // Only a cancel sets the event. A delay that elapsed lets the caller continue.
        return try util.waitEvent(io, &self.event, .{ .duration = waited }) or self.isRequested();
    }
};

test "a prior cancel survives a child reset and a retry delay" {
    const testing = std.testing;
    var cancel: Cancel = .{};
    cancel.request(testing.io);
    var interrupted = false;
    const Child = struct {
        fn run(was_interrupted: *bool) error{}!void {
            std.Io.sleep(std.testing.io, .fromSeconds(2), .awake) catch {
                was_interrupted.* = true;
            };
        }
    };
    try testing.expect(cancel.runChild(testing.io, Child.run, .{&interrupted}) == .canceled);
    try testing.expect(interrupted);
    try testing.expect(try cancel.holdFor(testing.io, 60_000));
}
