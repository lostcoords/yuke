//! Park the daemon until the operator asks it to stop.

const std = @import("std");
const zio = @import("zio");

/// std.Io has no signal vtable entry, so this module calls zio directly.
pub const Watcher = struct {
    interrupt: zio.Signal,
    terminate: zio.Signal,
    /// A daemon task sets this when it cannot continue, so the park ends without a signal.
    fault: zio.ResetEvent = .init,

    /// Install both handlers. A signal that arrives before `wait` counts, so no request is lost.
    pub fn init() !Watcher {
        var interrupt = try zio.Signal.init(.interrupt);
        errdefer interrupt.deinit();
        return .{ .interrupt = interrupt, .terminate = try zio.Signal.init(.terminate) };
    }

    /// The caller deinits first, so a second signal ends a shutdown that hangs.
    pub fn deinit(self: *Watcher) void {
        self.terminate.deinit();
        self.interrupt.deinit();
    }

    /// End the park from inside the daemon. The caller logs the reason.
    pub fn reportFault(self: *Watcher) void {
        self.fault.set();
    }

    /// Wait for the first signal. Fail when a daemon task reports that it cannot continue.
    pub fn wait(self: *Watcher) !void {
        switch (try zio.select(.{
            .interrupt = &self.interrupt,
            .terminate = &self.terminate,
            .fault = &self.fault,
        })) {
            .interrupt => std.log.info("interrupt received; the daemon stops", .{}),
            .terminate => std.log.info("terminate received; the daemon stops", .{}),
            .fault => return error.DaemonFaulted,
        }
    }
};

test "a signal that arrives before the wait still ends it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var watcher = try Watcher.init();
    defer watcher.deinit();
    // The handler installs before the raise, so the signal never kills the test runner.
    try std.posix.raise(.TERM);
    try watcher.wait();
}

test "a daemon task that cannot continue also ends the wait" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var watcher = try Watcher.init();
    defer watcher.deinit();
    watcher.reportFault();
    // Without the fault arm this parks until a signal arrives.
    try std.testing.expectError(error.DaemonFaulted, watcher.wait());
}
