//! Park the daemon until the operator asks it to stop.

const std = @import("std");
const zio = @import("zio");

/// std.Io has no signal vtable entry, so this module calls zio directly.
pub const Watcher = struct {
    interrupt: zio.Signal,
    terminate: zio.Signal,

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

    /// Wait for the first interrupt or terminate signal.
    pub fn wait(self: *Watcher) !void {
        switch (try zio.select(.{ .interrupt = &self.interrupt, .terminate = &self.terminate })) {
            .interrupt => std.log.info("interrupt received; the daemon stops", .{}),
            .terminate => std.log.info("terminate received; the daemon stops", .{}),
        }
    }
};

test "a signal that arrives before the wait still ends it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    try raiseThenWait();
}

/// The handler installs before the raise, so the signal never kills the test runner.
fn raiseThenWait() !void {
    var watcher = try Watcher.init();
    defer watcher.deinit();
    try std.posix.raise(.TERM);
    try watcher.wait();
}
