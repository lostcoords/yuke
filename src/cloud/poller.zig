//! The device-code poll policy. This file holds no clock and performs no input or output.
//! The caller supplies the time and executes the action, so every rule here is directly testable.

const std = @import("std");
const protocol = @import("protocol.zig");

/// RFC 8628 adds this much to the interval after a `slow_down` reply.
const slow_down_step_ms = 5_000;

/// Bound one wait, so a wrong server value cannot stall the login.
const max_interval_ms = 60_000;
const min_interval_ms = 1_000;

/// Bound the retry delay after a transient failure.
const max_backoff_ms = 60_000;

/// Bound the whole login, so a wrong `expires_in` cannot poll for hours.
const max_lifetime_ms = 60 * 60 * 1_000;

/// One classified poll response. The caller maps the transport result onto this set.
pub const Reply = union(enum) {
    approved,
    /// The server waits for the human. The value is the interval that the problem reports.
    pending: ?u64,
    slow_down: ?u64,
    /// The server refused the rate of the requests.
    throttled,
    /// The server hit a temporary conflict.
    retryable,
    /// The request never reached the server, or the server failed.
    unavailable,
    /// The grant is dead. The code explains why.
    terminal: protocol.Code,
};

/// Map one HTTP status and problem document onto a reply.
/// An unknown code never takes a known path: it either retries on a retry status or stops.
pub fn classify(status: u16, problem: protocol.Problem) Reply {
    if (status >= 200 and status < 300) return .approved;
    if (status >= 500) return .unavailable;

    return switch (status) {
        428 => .{ .pending = problem.interval_s },
        429 => if (problem.code == .slow_down) .{ .slow_down = problem.interval_s } else .throttled,
        409 => .retryable,
        else => .{ .terminal = problem.code },
    };
}

pub const Failure = union(enum) {
    /// The grant ran out of time.
    expired,
    /// The control plane stayed unreachable until the deadline.
    offline,
    /// The server ended the grant.
    terminal: protocol.Code,
};

pub const Action = union(enum) {
    /// Wait this long, then poll again.
    wait_ms: u64,
    done,
    failed: Failure,
};

pub const Poller = struct {
    interval_ms: u64,
    deadline_ms: u64,
    /// The current transient delay. A valid reply resets it to zero.
    backoff_ms: u64 = 0,
    /// The last reply never reached the server. It selects the failure at the deadline.
    offline: bool = false,

    /// Start the policy from a decoded start response. `now_ms` is a monotonic clock value.
    pub fn init(now_ms: u64, start: protocol.Start) Poller {
        std.debug.assert(start.interval_s > 0); // The decoder rejects a non-positive interval.
        std.debug.assert(start.expires_in_s > 0);

        const lifetime_ms = @min(start.expires_in_s *| 1_000, max_lifetime_ms);
        return .{
            .interval_ms = clampInterval(start.interval_s *| 1_000),
            .deadline_ms = now_ms +| lifetime_ms,
        };
    }

    /// Decide what to do after one poll. `now_ms` uses the same monotonic clock as `init`.
    pub fn step(self: *Poller, reply: Reply, now_ms: u64) Action {
        std.debug.assert(self.interval_ms >= min_interval_ms); // Every path clamps the interval.

        switch (reply) {
            .approved => return .done,
            .terminal => |code| return .{ .failed = .{ .terminal = code } },
            else => {},
        }

        // The grant is dead once the deadline passes. Report why the login never finished.
        if (now_ms >= self.deadline_ms) {
            return .{ .failed = if (self.offline) .offline else .expired };
        }

        const delay_ms = switch (reply) {
            .pending => |server_s| self.adopt(server_s),
            .slow_down => |server_s| blk: {
                _ = self.adopt(server_s);
                self.interval_ms = clampInterval(self.interval_ms +| slow_down_step_ms);
                break :blk self.interval_ms;
            },
            .throttled, .retryable, .unavailable => self.backOff(),
            .approved, .terminal => unreachable, // Both return above.
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
            self.interval_ms = clampInterval(@max(self.interval_ms, seconds *| 1_000));
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

fn clampInterval(value_ms: u64) u64 {
    return std.math.clamp(value_ms, min_interval_ms, max_interval_ms);
}

const testing = std.testing;

const pending_start: protocol.Start = .{
    .device_code = "dc",
    .user_code = "BCDF-GHJK",
    .verification_uri = "https://p/enroll",
    .verification_uri_complete = "https://p/enroll?code=BCDF-GHJK",
    .expires_in_s = 900,
    .interval_s = 5,
};

test "classify maps every documented status" {
    try testing.expect(classify(201, .{}) == .approved);
    try testing.expect(classify(200, .{}) == .approved);
    try testing.expect(classify(428, .{ .code = .authorization_pending, .interval_s = 5 }) == .pending);
    try testing.expect(classify(429, .{ .code = .slow_down }) == .slow_down);
    try testing.expect(classify(429, .{ .code = .rate_limited }) == .throttled);
    try testing.expect(classify(409, .{ .code = .conflict }) == .retryable);
    try testing.expect(classify(503, .{}) == .unavailable);
    try testing.expectEqual(protocol.Code.plan_limit, classify(403, .{ .code = .plan_limit }).terminal);
    try testing.expectEqual(protocol.Code.access_denied, classify(403, .{ .code = .access_denied }).terminal);
    try testing.expectEqual(protocol.Code.expired_token, classify(400, .{ .code = .expired_token }).terminal);
}

test "classify keeps an unknown code off a known path" {
    // An unknown 403 must never read as a human denial.
    try testing.expectEqual(protocol.Code.unknown, classify(403, .{}).terminal);
    try testing.expectEqual(protocol.Code.unknown, classify(451, .{}).terminal);
    // An unknown 429 still throttles, because the status alone says to slow down.
    try testing.expect(classify(429, .{}) == .throttled);
}

test "poller waits the server interval while the login is pending" {
    var p: Poller = .init(0, pending_start);
    try testing.expectEqual(@as(u64, 5_000), p.step(.{ .pending = 5 }, 0).wait_ms);
    try testing.expectEqual(@as(u64, 5_000), p.step(.{ .pending = null }, 5_000).wait_ms);
}

test "poller finishes on approval and stops on a terminal code" {
    var p: Poller = .init(0, pending_start);
    try testing.expect(p.step(.approved, 0) == .done);

    var q: Poller = .init(0, pending_start);
    try testing.expectEqual(protocol.Code.plan_limit, q.step(.{ .terminal = .plan_limit }, 0).failed.terminal);
}

test "slow down adds five seconds and a later reply never lowers it" {
    var p: Poller = .init(0, pending_start);
    try testing.expectEqual(@as(u64, 10_000), p.step(.{ .slow_down = null }, 0).wait_ms);
    try testing.expectEqual(@as(u64, 15_000), p.step(.{ .slow_down = 5 }, 1_000).wait_ms);
    try testing.expectEqual(@as(u64, 15_000), p.step(.{ .pending = 5 }, 2_000).wait_ms);
}

test "a transient failure backs off and a valid reply resets it" {
    var p: Poller = .init(0, pending_start);
    try testing.expectEqual(@as(u64, 5_000), p.step(.unavailable, 0).wait_ms);
    try testing.expectEqual(@as(u64, 10_000), p.step(.unavailable, 1_000).wait_ms);
    try testing.expectEqual(@as(u64, 20_000), p.step(.throttled, 2_000).wait_ms);
    try testing.expectEqual(@as(u64, 5_000), p.step(.{ .pending = 5 }, 3_000).wait_ms);
    try testing.expectEqual(@as(u64, 5_000), p.step(.retryable, 4_000).wait_ms);
}

test "the backoff stops at the cap" {
    var p: Poller = .init(0, pending_start);
    var delay: u64 = 0;
    for (0..12) |i| delay = p.step(.unavailable, i).wait_ms;
    try testing.expectEqual(@as(u64, 60_000), delay);
}

test "the poller never sleeps past the deadline" {
    var p: Poller = .init(0, pending_start);
    // Two seconds remain, so a five-second interval shortens to two.
    try testing.expectEqual(@as(u64, 2_000), p.step(.{ .pending = 5 }, 898_000).wait_ms);
    try testing.expect(p.step(.{ .pending = 5 }, 900_000).failed == .expired);
}

test "the deadline reports an offline failure after an unreachable server" {
    var p: Poller = .init(0, pending_start);
    _ = p.step(.unavailable, 0);
    try testing.expect(p.step(.unavailable, 900_000).failed == .offline);
}

test "the poller caps an absurd lifetime and interval" {
    const p: Poller = .init(0, .{
        .device_code = "dc",
        .user_code = "C",
        .verification_uri = "u",
        .verification_uri_complete = "u",
        .expires_in_s = 86_400,
        .interval_s = 3_600,
    });
    try testing.expectEqual(@as(u64, 60 * 60 * 1_000), p.deadline_ms);
    try testing.expectEqual(@as(u64, 60_000), p.interval_ms);
}
