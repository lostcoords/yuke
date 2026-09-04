//! Decide whether a failed provider attempt may repeat. The decision is pure: no I/O and no state.
//! `docs/plan.md` in the yuke repository holds the reasoning and the sources.

const std = @import("std");
const failure = @import("failure.zig");
const transport = @import("transport.zig");

/// The reason a run must stop instead of repeating the request.
pub const Stop = enum {
    /// The error can never succeed.
    permanent,
    /// The request used every attempt.
    attempts,
    /// The run used every retry permit.
    budget,
    /// The provider sent `x-should-retry: false`.
    server_veto,
    /// The provider asked for a longer wait than the cap allows.
    retry_after_long,
    /// A semantic event already reached the client. A repeat would duplicate it.
    output_started,
    /// The provider may already hold the request, and no idempotency key exists.
    delivery_unknown,
};

pub const Decision = union(enum) {
    /// Wait this many milliseconds, then repeat the request.
    retry_in_ms: u64,
    stop: Stop,
};

pub const Policy = struct {
    max_attempts: u8 = 5,
    base_ms: u64 = 500,
    /// The cap for a computed delay. A server delay uses `retry_after_cap_ms`.
    cap_ms: u64 = 8_000,
    /// Above this, the run stops. It must not fall back to a shorter local delay, because a provider
    /// outage would then become a retry storm.
    retry_after_cap_ms: u64 = 120_000,
};

/// One failed attempt. The caller collects these facts; this module only decides.
pub const Attempt = struct {
    err: anyerror,
    /// What the transport learned during the attempt: the retry headers and the delivery state.
    info: transport.AttemptInfo = .{},
    /// The stream published a semantic event before it failed.
    saw_semantic: bool = false,
    /// The 1-based number of the attempt that just failed.
    number: u8,
    /// The retry permits the run has left.
    budget_left: u8,
};

/// Decide the next step. `jitter` is a value in [0, 1) that the caller draws once per decision, so
/// this function stays deterministic and testable.
pub fn decide(policy: Policy, attempt: Attempt, jitter: f64) Decision {
    std.debug.assert(attempt.number >= 1);
    std.debug.assert(jitter >= 0.0 and jitter < 1.0);

    // Order matters. Each gate below answers a different question, and an earlier gate outranks a
    // later one. A published event outranks everything: the client already saw the output.
    if (attempt.saw_semantic) return .{ .stop = .output_started };
    if (attempt.info.should_retry) |allowed| if (!allowed) return .{ .stop = .server_veto };
    const class = failure.classify(attempt.err).class;
    if (class == .permanent) return .{ .stop = .permanent };
    // A provider answer proves the request arrived. The gate covers a transport fault only.
    if (class == .transport and attempt.info.delivery == .possibly_sent) return .{ .stop = .delivery_unknown };
    if (attempt.number >= policy.max_attempts) return .{ .stop = .attempts };
    if (attempt.budget_left == 0) return .{ .stop = .budget };

    if (attempt.info.retry_after_ms) |asked| {
        if (asked > policy.retry_after_cap_ms) return .{ .stop = .retry_after_long };
        return .{ .retry_in_ms = asked }; // A server delay takes no jitter.
    }
    return .{ .retry_in_ms = backoff(policy, attempt.number, jitter) };
}

/// Return the computed delay for the attempt that just failed.
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
    try testing.expectEqual(@as(u64, 500), decide(default, failed(http.Error.RateLimited, 1), 0.0).retry_in_ms);
    try testing.expectEqual(@as(u64, 1000), decide(default, failed(http.Error.ServerError, 2), 0.0).retry_in_ms);
    // The jitter removes at most a quarter, so a full draw leaves 750 of 1000.
    try testing.expectEqual(@as(u64, 750), decide(default, failed(http.Error.ServerError, 2), 0.999).retry_in_ms);
}

test "the computed delay stops at the cap" {
    // Attempt 8 would ask for 64000 ms without the cap.
    try testing.expectEqual(@as(u64, 8000), backoff(default, 8, 0.0));
    try testing.expectEqual(@as(u64, 8000), backoff(default, 40, 0.0));
}

test "a permanent class never repeats" {
    for ([_]anyerror{
        http.Error.AuthFailed,
        http.Error.PermissionDenied,
        http.Error.QuotaExhausted,
        http.Error.RateLimitUnknown,
        http.Error.BadStatus,
        http.Error.BadUrl,
        http.Error.RedirectRefused,
        error.Protocol,
        error.HttpChunkInvalid,
        error.UnknownModel,
        error.OutOfMemory,
    }) |err| {
        try testing.expectEqual(Stop.permanent, decide(default, failed(err, 1), 0.0).stop);
    }
}

test "a published event outranks every other gate" {
    var a = failed(http.Error.RateLimited, 1);
    a.saw_semantic = true;
    a.info.retry_after_ms = 10;
    a.info.should_retry = true;
    try testing.expectEqual(Stop.output_started, decide(default, a, 0.0).stop);
}

test "the server veto outranks a repeatable class" {
    var a = failed(http.Error.ServerError, 1);
    a.info.should_retry = false;
    try testing.expectEqual(Stop.server_veto, decide(default, a, 0.0).stop);

    // A true value promotes nothing. It leaves a permanent class permanent.
    var b = failed(http.Error.QuotaExhausted, 1);
    b.info.should_retry = true;
    try testing.expectEqual(Stop.permanent, decide(default, b, 0.0).stop);
}

test "an ambiguous delivery stops a transport failure only" {
    var cut = failed(error.ConnectionResetByPeer, 1);
    cut.info.delivery = .possibly_sent;
    // No idempotency key exists for either provider, so a repeat could bill the same work twice.
    try testing.expectEqual(Stop.delivery_unknown, decide(default, cut, 0.0).stop);

    cut.info.delivery = .definitely_unsent;
    try testing.expectEqual(@as(u64, 500), decide(default, cut, 0.0).retry_in_ms);

    // A 429 is a provider ANSWER, so the request certainly arrived and the gate does not apply.
    var answered = failed(http.Error.RateLimited, 1);
    answered.info.delivery = .possibly_sent;
    try testing.expectEqual(@as(u64, 500), decide(default, answered, 0.0).retry_in_ms);
}

test "a server delay replaces the computed delay and takes no jitter" {
    var a = failed(http.Error.RateLimited, 1);
    a.info.retry_after_ms = 2_500;
    try testing.expectEqual(@as(u64, 2_500), decide(default, a, 0.999).retry_in_ms);

    // Above the cap the run stops. It must not fall back to a shorter local delay.
    a.info.retry_after_ms = default.retry_after_cap_ms + 1;
    try testing.expectEqual(Stop.retry_after_long, decide(default, a, 0.0).stop);
}

test "the attempt count and the run budget each stop the retry" {
    try testing.expectEqual(Stop.attempts, decide(default, failed(http.Error.ServerError, 5), 0.0).stop);

    var spent = failed(http.Error.ServerError, 1);
    spent.budget_left = 0;
    try testing.expectEqual(Stop.budget, decide(default, spent, 0.0).stop);
}

test "a truncated stream repeats" {
    // `transport.zig` raises IncompleteStream when a stream ends without its terminal event.
    try testing.expectEqual(@as(u64, 500), decide(default, failed(error.IncompleteStream, 1), 0.0).retry_in_ms);
}

test "a stalled read repeats only when the request never left" {
    // An idle read stall is a transport fault, unlike an HTTP 408 or 504 that the provider answered.
    try testing.expectEqual(@as(u64, 500), decide(default, failed(http.Error.IdleTimeout, 1), 0.0).retry_in_ms);
    var stalled = failed(http.Error.IdleTimeout, 1);
    stalled.info.delivery = .possibly_sent;
    try testing.expectEqual(Stop.delivery_unknown, decide(default, stalled, 0.0).stop);
}

test "the policy controls the computed delay" {
    const slow: Policy = .{ .base_ms = 2_000, .cap_ms = 30_000 };
    try testing.expectEqual(@as(u64, 2_000), decide(slow, failed(http.Error.ServerError, 1), 0.0).retry_in_ms);
    try testing.expectEqual(@as(u64, 8_000), decide(slow, failed(http.Error.ServerError, 3), 0.0).retry_in_ms);
}
