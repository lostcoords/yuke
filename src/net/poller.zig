//! The device-code poll policy. This file holds no clock and performs no input or output.
//! The caller supplies the time and executes the action, so every rule here is directly testable.

const std = @import("std");

/// RFC 8628 adds this much to the interval after a `slow_down` reply.
const slow_down_step_ms = 5_000;

/// Hold one floor under the wait. RFC 8628 section 3.5 leaves the cadence itself to the server,
/// and the deadline already bounds the login, so no ceiling belongs here.
const min_interval_ms = 1_000;

/// Bound the retry delay after a transient failure.
const max_backoff_ms = 60_000;

/// Bound the whole login. RFC 8628 accepts a day, so a shorter cap would end a valid grant.
const max_lifetime_ms = 24 * 60 * 60 * 1_000;

/// One classified poll response. The caller maps its own protocol onto this set.
pub const Reply = union(enum) {
    /// The server waits for the human. The value is the interval that the server reports.
    pending: ?u64,
    slow_down: ?u64,
    /// The request never reached the server, or the server failed.
    unavailable,
};

pub const Failure = union(enum) {
    /// The grant ran out of time.
    expired,
    /// The control plane stayed unreachable until the deadline.
    offline,
};

pub const Action = union(enum) {
    /// Wait this long, then poll again.
    wait_ms: u64,
    failed: Failure,
};

pub const Poller = struct {
    interval_ms: u64,
    deadline_ms: u64,
    /// The current transient delay. A valid reply resets it to zero.
    backoff_ms: u64 = 0,
    /// The last reply never reached the server. It selects the failure at the deadline.
    offline: bool = false,

    /// Start the policy. `now_ms` is a monotonic clock value, and the caller supplies both bounds.
    pub fn init(now_ms: u64, interval_ms: u64, lifetime_ms: u64) Poller {
        return .{
            .interval_ms = atLeastInterval(interval_ms),
            .deadline_ms = now_ms +| @min(lifetime_ms, max_lifetime_ms),
        };
    }

    /// RFC 8628 section 3.5 requires one whole interval before the first token request.
    pub fn firstWaitMs(self: Poller) u64 {
        return self.interval_ms;
    }

    /// Decide what to do after one poll. `now_ms` uses the same monotonic clock as `init`.
    pub fn step(self: *Poller, reply: Reply, now_ms: u64) Action {
        std.debug.assert(self.interval_ms >= min_interval_ms); // Every path clamps the interval.

        // The grant is dead once the deadline passes. Report why the login never finished.
        if (now_ms >= self.deadline_ms) {
            return .{ .failed = if (self.offline) .offline else .expired };
        }

        const delay_ms = switch (reply) {
            .pending => |server_s| self.adopt(server_s),
            .slow_down => |server_s| blk: {
                _ = self.adopt(server_s);
                self.interval_ms = atLeastInterval(self.interval_ms +| slow_down_step_ms);
                break :blk self.interval_ms;
            },
            .unavailable => self.backOff(),
        };

        self.offline = reply == .unavailable;

        // Never sleep past the deadline. The next poll then reports the server's own verdict.
        const remaining_ms = self.deadline_ms - now_ms;
        return .{ .wait_ms = @min(delay_ms, remaining_ms) };
    }

    /// Take a server interval and reset the transient delay. An interval never falls,
    /// so a later reply cannot undo a `slow_down` increase.
    fn adopt(self: *Poller, server_s: ?u64) u64 {
        if (server_s) |seconds| {
            self.interval_ms = atLeastInterval(@max(self.interval_ms, seconds *| 1_000));
        }
        self.backoff_ms = 0;
        return self.interval_ms;
    }

    /// Grow the transient delay. It starts at the interval and doubles up to the cap.
    fn backOff(self: *Poller) u64 {
        self.backoff_ms = if (self.backoff_ms == 0)
            self.interval_ms
        else
            @min(self.backoff_ms *| 2, max_backoff_ms);
        return self.backoff_ms;
    }
};

fn atLeastInterval(value_ms: u64) u64 {
    return @max(value_ms, min_interval_ms);
}

const testing = std.testing;

/// Fifteen minutes at five seconds, the cadence a device flow usually asks for.
fn pending() Poller {
    return .init(0, 5_000, 900_000);
}

test "the first request waits one whole interval" {
    try testing.expectEqual(@as(u64, 5_000), pending().firstWaitMs());
}

test "poller waits the server interval while the login is pending" {
    var p = pending();
    try testing.expectEqual(@as(u64, 5_000), p.step(.{ .pending = 5 }, 0).wait_ms);
    try testing.expectEqual(@as(u64, 5_000), p.step(.{ .pending = null }, 5_000).wait_ms);
}

test "slow down adds five seconds and a later reply never lowers it" {
    var p = pending();
    try testing.expectEqual(@as(u64, 10_000), p.step(.{ .slow_down = null }, 0).wait_ms);
    try testing.expectEqual(@as(u64, 15_000), p.step(.{ .slow_down = 5 }, 1_000).wait_ms);
    try testing.expectEqual(@as(u64, 15_000), p.step(.{ .pending = 5 }, 2_000).wait_ms);
}

test "a transient failure backs off and a valid reply resets it" {
    var p = pending();
    try testing.expectEqual(@as(u64, 5_000), p.step(.unavailable, 0).wait_ms);
    try testing.expectEqual(@as(u64, 10_000), p.step(.unavailable, 1_000).wait_ms);
    try testing.expectEqual(@as(u64, 20_000), p.step(.unavailable, 2_000).wait_ms);
    try testing.expectEqual(@as(u64, 5_000), p.step(.{ .pending = 5 }, 3_000).wait_ms);
    try testing.expectEqual(@as(u64, 5_000), p.step(.unavailable, 4_000).wait_ms);
}

test "the backoff stops at the cap" {
    var p = pending();
    var delay: u64 = 0;
    for (0..12) |i| delay = p.step(.unavailable, i).wait_ms;
    try testing.expectEqual(@as(u64, 60_000), delay);
}

test "the poller never sleeps past the deadline" {
    var p = pending();
    // Two seconds remain, so a five-second interval shortens to two.
    try testing.expectEqual(@as(u64, 2_000), p.step(.{ .pending = 5 }, 898_000).wait_ms);
    try testing.expect(p.step(.{ .pending = 5 }, 900_000).failed == .expired);
}

test "the deadline reports an offline failure after an unreachable server" {
    var p = pending();
    _ = p.step(.unavailable, 0);
    try testing.expect(p.step(.unavailable, 900_000).failed == .offline);
}

test "the server keeps its cadence and a full day of lifetime survives" {
    const p: Poller = .init(0, 3_600_000, 86_400_000);
    // RFC 8628 accepts a day, so the whole lifetime must remain.
    try testing.expectEqual(@as(u64, 86_400_000), p.deadline_ms);
    // Section 3.5 leaves the interval to the server. A ceiling here would poll faster than it asked.
    try testing.expectEqual(@as(u64, 3_600_000), p.interval_ms);
    // The floor stands, because a zero interval would spin.
    try testing.expectEqual(@as(u64, min_interval_ms), (Poller.init(0, 0, 1_000)).interval_ms);
}
