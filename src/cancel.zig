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
    requested: bool = false,
    /// A cancel sets this event, so a waiter never sleeps through a stop.
    event: std.Io.Event = .unset,

    /// Ask this call site to stop, then wake whoever waits on it.
    pub fn request(self: *Cancel, io: std.Io) void {
        self.requested = true;
        self.event.set(io);
    }

    /// Report that the child finished, so the caller stops waiting for it.
    pub fn finish(self: *Cancel, io: std.Io) void {
        self.event.set(io);
    }

    /// Return `error.Canceled` when this call site or the owning task stopped.
    pub fn check(self: *const Cancel, io: std.Io) !void {
        try io.checkCancel();
        if (self.requested) return error.Canceled;
    }

    /// Run `f` in a child task, so a cancel can interrupt a blocked call.
    pub fn runChild(self: *Cancel, io: std.Io, comptime f: anytype, args: anytype) ChildResult {
        self.event.reset(); // A one-shot event. The next child waits again.

        var child = io.concurrent(f, args) catch |err| return .{ .returned = err };
        self.event.wait(io) catch {
            child.cancel(io) catch {}; // Shutdown canceled the owning task. Stop the child.
            return .aborted;
        };

        if (self.requested) {
            child.cancel(io) catch {}; // Interrupt a blocked call, then join the child.
            return .canceled;
        }

        return .{ .returned = child.await(io) };
    }

    /// Hold for `delay_ms` and report whether a cancel arrived. A plain sleep would ignore the event.
    pub fn holdFor(self: *Cancel, io: std.Io, delay_ms: u64) !bool {
        if (self.requested) return true; // A cancel that already landed must not wait out the delay.
        self.event.reset();

        const waited: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(@intCast(delay_ms)), .clock = .awake };
        self.event.waitTimeout(io, .{ .duration = waited }) catch |err| switch (err) {
            error.Timeout => return self.requested, // The delay elapsed. The caller continues.
            else => return err,
        };

        return true; // Only a cancel sets the event.
    }
};
