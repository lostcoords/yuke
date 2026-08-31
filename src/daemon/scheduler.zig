//! One task owns the periodic control-plane jobs and serializes their fetches.

const std = @import("std");
const State = @import("State.zig");

const Timestamp = std.Io.Clock.Timestamp;
const Duration = std.Io.Clock.Duration;

/// The catalog is anonymous and changes slowly, so a conditional GET each hour is enough.
const catalog_interval_ms = 60 * 60 * 1000;
/// The bundle carries the routes a run needs, so it revalidates more often than the catalog.
const bundle_interval_ms = 15 * 60 * 1000;
/// Fetch a new bundle this long before the account token expires.
const expiry_margin_ms = 5 * 60 * 1000;
/// The first delay after a failure. Each later failure doubles it.
const backoff_base_ms = 30 * 1000;
/// The longest delay a failed job waits. A periodic job never stops, so it needs a ceiling.
const backoff_cap_ms = 30 * 60 * 1000;
/// The clock counts suspended time, because the control plane times its documents by its own clock.
const clock: std.Io.Clock = .boot;

/// One periodic job. The failure count selects the backoff, and a success clears it.
pub const Job = struct {
    due: Timestamp,
    failures: u6 = 0,

    fn init(io: std.Io) Job {
        return .{ .due = .now(io, clock) };
    }

    pub fn isDue(self: Job, io: std.Io) bool {
        return self.due.durationFromNow(io).raw.nanoseconds <= 0;
    }

    /// Advance from the prior deadline and skip the periods that a long run missed.
    fn succeed(self: *Job, io: std.Io, interval_ms: i64) void {
        self.failures = 0;
        const next = self.due.addDuration(millis(interval_ms));
        self.due = if (next.durationFromNow(io).raw.nanoseconds <= 0) .fromNow(io, millis(interval_ms)) else next;
    }

    /// Back off after a failure. The job stays alive, because a control plane outage always ends.
    fn fail(self: *Job, io: std.Io) void {
        if (self.failures < std.math.maxInt(u6)) self.failures += 1;
        self.due = .fromNow(io, millis(backoffMillis(self.failures)));
    }
};

/// Double the base delay for each failure, up to the ceiling.
fn backoffMillis(failures: u6) i64 {
    if (failures == 0) return backoff_base_ms;
    const shift: u6 = @min(failures - 1, 31);
    const scaled = backoff_base_ms *| (@as(i64, 1) <<| shift);
    return @min(scaled, backoff_cap_ms);
}

/// Return the wait before a token needs its replacement, or null inside the margin.
fn leadMillis(expires_at: u64, now_ms: u64) ?i64 {
    if (expires_at <= now_ms) return null;
    const remaining = expires_at - now_ms;
    if (remaining <= expiry_margin_ms) return null;
    return std.math.cast(i64, remaining - expiry_margin_ms) orelse null;
}

fn millis(value: i64) Duration {
    return .{ .raw = .fromMilliseconds(value), .clock = clock };
}

/// The periodic worker. `State` holds a pointer, so an RPC can ask for an early catalog run.
pub const Scheduler = struct {
    state: *State,
    catalog: Job,
    bundle: Job,
    /// A set event ends the wait early. The RPC sets it; only the scheduler task clears it.
    wake: std.Io.Event = .unset,

    pub fn init(state: *State) Scheduler {
        return .{ .state = state, .catalog = .init(state.io), .bundle = .init(state.io) };
    }

    /// Ask for a catalog fetch now. The caller returns at once, and `catalog.changed` reports the result.
    pub fn requestCatalog(self: *Scheduler) void {
        self.catalog.due = .now(self.state.io, clock);
        self.wake.set(self.state.io);
    }

    /// Run until a cancel arrives, which must leave this loop because no later point reports it.
    pub fn run(self: *Scheduler) std.Io.Cancelable!void {
        const io = self.state.io;
        while (true) {
            self.wake.waitTimeout(io, .{ .deadline = self.earliest() }) catch |err| switch (err) {
                // A spurious wake also reports a timeout, so the loop checks each job again.
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
            self.wake.reset();

            if (self.catalog.isDue(io)) try self.runCatalog();
            if (self.bundle.isDue(io)) try self.runBundle();
        }
    }

    fn earliest(self: *const Scheduler) Timestamp {
        const a = self.catalog.due;
        const b = self.bundle.due;
        return if (a.raw.nanoseconds <= b.raw.nanoseconds) a else b;
    }

    fn runCatalog(self: *Scheduler) std.Io.Cancelable!void {
        const io = self.state.io;
        const status = self.state.refreshCatalogOnce() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("catalog refresh failed: {t}", .{err});
            self.catalog.fail(io);
            return;
        };
        switch (status) {
            .current => self.catalog.succeed(io, catalog_interval_ms),
            .catalog_unavailable => {
                // The catalog can appear at any time, so a short retry beats a whole hour.
                std.log.warn("the control plane has not synced its catalog yet", .{});
                self.catalog.fail(io);
            },
        }
    }

    fn runBundle(self: *Scheduler) std.Io.Cancelable!void {
        const io = self.state.io;
        self.state.refreshBundleOnce() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("account refresh failed: {t}", .{err});
            self.bundle.fail(io);
            return;
        };
        self.bundle.succeed(io, bundle_interval_ms);
        // A token that expires before the next run needs its replacement earlier.
        if (self.expiryLeadMillis()) |lead_ms| {
            if (lead_ms < bundle_interval_ms) self.bundle.due = .fromNow(io, millis(lead_ms));
        }
    }

    /// Return the wait that reaches the soonest token with the margin to spare.
    fn expiryLeadMillis(self: *const Scheduler) ?i64 {
        return leadMillis(self.state.bundleExpiryMillis() orelse return null, self.state.nowMillis());
    }
};

const testing = std.testing;

test "the backoff doubles and then holds at the ceiling" {
    try testing.expectEqual(@as(i64, backoff_base_ms), backoffMillis(0));
    try testing.expectEqual(@as(i64, backoff_base_ms), backoffMillis(1));
    try testing.expectEqual(@as(i64, backoff_base_ms * 2), backoffMillis(2));
    try testing.expectEqual(@as(i64, backoff_base_ms * 4), backoffMillis(3));
    // A long outage never exceeds the ceiling and never overflows.
    try testing.expectEqual(@as(i64, backoff_cap_ms), backoffMillis(20));
    try testing.expectEqual(@as(i64, backoff_cap_ms), backoffMillis(std.math.maxInt(u6)));
}

test "a job holds its cadence and skips the periods that a long run missed" {
    const zio = @import("zio");
    var rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    var job: Job = .init(io);
    try testing.expect(job.isDue(io));

    // A run that finishes inside its interval keeps the original phase.
    const started = job.due;
    job.succeed(io, 60_000);
    try testing.expect(!job.isDue(io));
    try testing.expectEqual(started.addDuration(millis(60_000)).raw.nanoseconds, job.due.raw.nanoseconds);

    // A run that overran by more than one interval starts a fresh interval instead of firing at once.
    job.due = .fromNow(io, millis(-180_000));
    job.succeed(io, 60_000);
    try testing.expect(!job.isDue(io));
}

test "a failure backs the job off and a success clears it" {
    const zio = @import("zio");
    var rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    var job: Job = .init(io);
    job.fail(io);
    try testing.expectEqual(@as(u6, 1), job.failures);
    try testing.expect(!job.isDue(io)); // The job waits instead of retrying at once.

    job.fail(io);
    try testing.expectEqual(@as(u6, 2), job.failures);

    job.succeed(io, 60_000);
    try testing.expectEqual(@as(u6, 0), job.failures);
}

test "the expiry never asks for an immediate refetch" {
    // A token inside the margin must not shorten the wait, or a 304 would loop with no delay.
    try testing.expect(leadMillis(1_000, 1_000) == null); // Already expired.
    try testing.expect(leadMillis(0, 1_000) == null); // A zero expiry is not a deadline.
    try testing.expect(leadMillis(1_000 + expiry_margin_ms, 1_000) == null); // Exactly at the margin.

    // A token beyond the margin shortens the wait by the time that remains.
    try testing.expectEqual(@as(?i64, 60_000), leadMillis(1_000 + expiry_margin_ms + 60_000, 1_000));
}
