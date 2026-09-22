//! Decide whether a failed provider attempt may repeat. The decision is pure: no I/O and no state.

const std = @import("std");
const failure = @import("failure.zig");
const transport = @import("transport.zig");

pub const Policy = struct {
    max_attempts: u8 = 5,
    base_ms: u64 = 500,
    /// The cap for a computed delay. A server delay uses `retry_after_cap_ms`.
    cap_ms: u64 = 8_000,
    /// Above this server delay the run stops, so a provider outage never becomes a retry storm.
    retry_after_cap_ms: u64 = 120_000,
};

/// One failed attempt. The caller collects these facts; this module only decides.
pub const Attempt = struct {
    err: anyerror,
    /// What the transport learned during the attempt: the retry headers and the delivery state.
    info: transport.AttemptInfo = .{},
    /// The stream published a semantic event before it failed. A repeat would duplicate it.
    saw_semantic: bool = false,
    /// The 1-based number of the attempt that just failed.
    number: u8,
    /// The retry permits the run has left.
    budget_left: u8,
};

/// Return the delay in milliseconds before the next attempt, or null when the run must stop.
pub fn decide(policy: Policy, attempt: Attempt, jitter: f64) ?u64 {
    std.debug.assert(policy.max_attempts >= 1);
    std.debug.assert(policy.base_ms <= policy.cap_ms);
    std.debug.assert(attempt.number >= 1);
    std.debug.assert(jitter >= 0.0 and jitter < 1.0);

    if (attempt.saw_semantic) return null;
    if (attempt.info.no_retry) return null;
    const class = failure.classify(attempt.err).class;
    if (class == .permanent) return null;
    // A provider answer proves the request arrived. The gate covers a transport fault only.
    if (class == .transport and attempt.info.delivery == .possibly_sent) return null;
    if (attempt.number >= policy.max_attempts) return null;
    if (attempt.budget_left == 0) return null;

    const computed = backoff(policy, attempt.number, jitter);
    const asked = attempt.info.retry_after_ms orelse return computed;
    if (asked > policy.retry_after_cap_ms) return null;
    return @max(asked, computed); // A server delay is a floor, so `retry-after: 0` cannot skip the backoff.
}

fn backoff(policy: Policy, number: u8, jitter: f64) u64 {
    const shift: u6 = @intCast(@min(number - 1, 16));
    const raw = policy.base_ms *| (@as(u64, 1) << shift);
    const capped: f64 = @floatFromInt(@min(raw, policy.cap_ms));
    // The SDK form: keep 75% to 100% of the delay. This is NOT the AWS `random(0, cap)` form.
    return @intFromFloat(capped * (1.0 - jitter * 0.25));
}

const testing = std.testing;
const http = @import("transport/http.zig"); // The tests name concrete provider errors.
const default: Policy = .{};

fn failed(err: anyerror, number: u8) Attempt {
    return .{ .err = err, .number = number, .budget_left = 8 };
}

test "a temporary provider answer repeats with a computed delay" {
    try testing.expectEqual(@as(?u64, 500), decide(default, failed(http.Error.RateLimited, 1), 0.0));
    try testing.expectEqual(@as(?u64, 1000), decide(default, failed(http.Error.ServerError, 2), 0.0));
    // The jitter removes at most a quarter, so a full draw leaves 750 of 1000.
    try testing.expectEqual(@as(?u64, 750), decide(default, failed(http.Error.ServerError, 2), 0.999));
}

test "the computed delay stops at the cap" {
    // Attempt 8 would ask for 64000 ms without the cap.
    try testing.expectEqual(@as(u64, 8000), backoff(default, 8, 0.0));
    try testing.expectEqual(@as(u64, 8000), backoff(default, 40, 0.0));
}

test "a published event stops the retry even when the server allows one" {
    var a = failed(http.Error.RateLimited, 1);
    a.saw_semantic = true;
    a.info.retry_after_ms = 10;
    try testing.expectEqual(@as(?u64, null), decide(default, a, 0.0));
}

test "a permanent class and the server veto stop the retry" {
    try testing.expectEqual(@as(?u64, null), decide(default, failed(http.Error.AuthFailed, 1), 0.0));
    var vetoed = failed(http.Error.ServerError, 1);
    vetoed.info.no_retry = true;
    try testing.expectEqual(@as(?u64, null), decide(default, vetoed, 0.0));
}

test "an ambiguous delivery stops a transport failure only" {
    var cut = failed(http.Error.ConnectionLost, 1);
    cut.info.delivery = .possibly_sent;
    // No idempotency key exists for either provider, so a repeat could bill the same work twice.
    try testing.expectEqual(@as(?u64, null), decide(default, cut, 0.0));

    cut.info.delivery = .definitely_unsent;
    try testing.expectEqual(@as(?u64, 500), decide(default, cut, 0.0));

    // A 429 is a provider ANSWER, so the request certainly arrived and the gate does not apply.
    var answered = failed(http.Error.RateLimited, 1);
    answered.info.delivery = .possibly_sent;
    try testing.expectEqual(@as(?u64, 500), decide(default, answered, 0.0));
}

test "a server delay is a floor under the computed delay" {
    var a = failed(http.Error.RateLimited, 1);
    a.info.retry_after_ms = 2_500;
    try testing.expectEqual(@as(?u64, 2_500), decide(default, a, 0.0));

    // A provider sent `retry-after: 0`, and five attempts fired within 8 ms.
    a.info.retry_after_ms = 0;
    try testing.expectEqual(@as(?u64, 500), decide(default, a, 0.0));

    // Above the cap the run stops. It must not fall back to a shorter local delay.
    a.info.retry_after_ms = default.retry_after_cap_ms + 1;
    try testing.expectEqual(@as(?u64, null), decide(default, a, 0.0));
}

test "the attempt count and the run budget each stop the retry" {
    try testing.expectEqual(@as(?u64, null), decide(default, failed(http.Error.ServerError, 5), 0.0));

    var spent = failed(http.Error.ServerError, 1);
    spent.budget_left = 0;
    try testing.expectEqual(@as(?u64, null), decide(default, spent, 0.0));
}
