//! The host timers behind the global `setTimeout` and `setInterval`. Only the owner touches the table, so no task races it.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The most live timers. A call past the limit throws `RangeError`.
pub const max_timers = 4096;
/// The longest delay, as on the web. A larger delay waits this long.
const max_delay_ms: u64 = std.math.maxInt(i32);

const Timer = struct {
    id: u64,
    due: std.Io.Timestamp,
    /// The creation order, so timers with one due time fire in the order they were set.
    seq: u64,
    /// Null for a one-shot timer.
    interval_ms: ?u64,
    callback: Value,
    /// Owned copies of the extra arguments.
    args: []Value,
};

pub const Timers = struct {
    /// Sorted by `(due, seq)`.
    entries: std.ArrayList(Timer) = .empty,
    last_id: u64 = 0,
    last_seq: u64 = 0,
    /// The timer whose callback runs now, so a clear inside the callback stops its re-arm and the limit still counts it.
    firing: ?*Timer = null,

    /// Answer the first due time, or null with no timer.
    pub fn nextDeadline(self: *const Timers) ?std.Io.Timestamp {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[0].due;
    }

    /// Answer whether a timer is due at `now`.
    pub fn isDue(self: *const Timers, now: std.Io.Timestamp) bool {
        const first = self.nextDeadline() orelse return false;
        return first.nanoseconds <= now.nanoseconds;
    }

    fn insert(self: *Timers, gpa: std.mem.Allocator, timer: Timer) void {
        std.debug.assert(self.entries.items.len < max_timers);
        const at = std.sort.upperBound(Timer, self.entries.items, timer, struct {
            fn order(context: Timer, item: Timer) std.math.Order {
                if (context.due.nanoseconds != item.due.nanoseconds) return std.math.order(context.due.nanoseconds, item.due.nanoseconds);
                return std.math.order(context.seq, item.seq);
            }
        }.order);
        self.entries.insert(gpa, at, timer) catch unreachable;
    }

    fn free(ctx: Context, gpa: std.mem.Allocator, timer: Timer) void {
        ctx.freeValue(timer.callback);
        for (timer.args) |arg| ctx.freeValue(arg);
        gpa.free(timer.args);
    }

    /// Remove the timer with `id`. An unknown or fired id does nothing.
    fn clear(self: *Timers, ctx: Context, gpa: std.mem.Allocator, id: u64) void {
        if (self.firing) |timer| if (timer.id == id) {
            timer.interval_ms = null;
        };
        for (self.entries.items, 0..) |timer, i| if (timer.id == id) {
            _ = self.entries.orderedRemove(i);
            free(ctx, gpa, timer);
            return;
        };
    }

    /// Run the timers that were due and set before this call, and answer whether a callback threw. A timer set in a callback waits for the next pump.
    pub fn fire(self: *Timers, host: *Host, now: std.Io.Timestamp) bool {
        std.debug.assert(host.phase == .open);
        std.debug.assert(self.firing == null);
        const last_seq = self.last_seq;
        var faulted = false;
        while (self.entries.items.len > 0) {
            const first = self.entries.items[0];
            if (first.due.nanoseconds > now.nanoseconds or first.seq > last_seq) break;
            var timer = self.entries.orderedRemove(0);
            self.firing = &timer;
            host.enterSlice();
            const answer = host.ctx.call(timer.callback, quickjs.UNDEFINED, timer.args);
            if (host.ctx.isException(answer)) {
                host.noteFault();
                faulted = true;
            }
            host.ctx.freeValue(answer);
            self.firing = null;
            if (timer.interval_ms) |ms| {
                self.last_seq += 1;
                timer.seq = self.last_seq;
                timer.due = now.addDuration(.fromMilliseconds(@intCast(ms)));
                self.insert(host.gpa, timer);
                continue;
            }
            free(host.ctx, host.gpa, timer);
        }
        return faulted;
    }

    /// Free every timer root and call nothing. `Host.close` calls this before the context dies.
    pub fn deinit(self: *Timers, ctx: Context, gpa: std.mem.Allocator) void {
        std.debug.assert(self.firing == null);
        for (self.entries.items) |timer| free(ctx, gpa, timer);
        self.entries.deinit(gpa);
        self.* = .{};
    }
};

/// Install the timer globals. `clearInterval` is `clearTimeout`, because both share one id space.
pub fn install(host: *Host) void {
    const ctx = host.ctx;
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    ctx.setPropertyStr(global, "setTimeout", ctx.newFunction("setTimeout", 2, jsSetTimeout)) catch unreachable;
    ctx.setPropertyStr(global, "setInterval", ctx.newFunction("setInterval", 2, jsSetInterval)) catch unreachable;
    const clear = ctx.newFunction("clearTimeout", 1, jsClear);
    ctx.setPropertyStr(global, "clearTimeout", ctx.dupValue(clear)) catch unreachable;
    ctx.setPropertyStr(global, "clearInterval", clear) catch unreachable;
}

fn jsSetTimeout(ctx: Context, _: Value, args: []const Value) Value {
    return set(ctx, args, false);
}

fn jsSetInterval(ctx: Context, _: Value, args: []const Value) Value {
    return set(ctx, args, true);
}

fn set(ctx: Context, args: []const Value, repeat: bool) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return ctx.throwTypeError("the host is closed");
    if (args.len == 0 or !ctx.isFunction(args[0])) return ctx.throwTypeError("the timer callback must be a function");
    // A firing interval left the table but re-arms after its callback, so it still counts.
    const firing: usize = if (host.timers.firing) |timer| @intFromBool(timer.interval_ms != null) else 0;
    if (host.timers.entries.items.len + firing >= max_timers) return ctx.throwRangeError("the host holds 4096 timers");
    const delay_ms = delayOf(ctx, if (args.len > 1) args[1] else quickjs.UNDEFINED) orelse return ctx.throw(ctx.getException());

    const extra = if (args.len > 2) args[2..] else &.{};
    const owned = host.gpa.alloc(Value, extra.len) catch unreachable;
    for (extra, owned) |arg, *slot| slot.* = ctx.dupValue(arg);
    const timers = &host.timers;
    timers.last_id += 1;
    timers.last_seq += 1;
    timers.insert(host.gpa, .{
        .id = timers.last_id,
        .due = std.Io.Timestamp.now(host.io, .awake).addDuration(.fromMilliseconds(@intCast(delay_ms))),
        .seq = timers.last_seq,
        .interval_ms = if (repeat) delay_ms else null,
        .callback = ctx.dupValue(args[0]),
        .args = owned,
    });
    // The TUI tick task can sleep with no deadline, so it must re-read the next deadline.
    host.wake.set(host.io);
    return ctx.newFloat64(@floatFromInt(timers.last_id));
}

/// Convert a delay as the web does: a missing, non-finite, or negative delay is zero, and a fraction rounds down. Null means a conversion threw.
fn delayOf(ctx: Context, value: Value) ?u64 {
    const ms = ctx.toFloat64(value) catch return null;
    if (!std.math.isFinite(ms) or ms <= 0) return 0;
    return @intFromFloat(@floor(@min(ms, @as(f64, @floatFromInt(max_delay_ms)))));
}

fn jsClear(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open or args.len == 0 or !ctx.isNumber(args[0])) return quickjs.UNDEFINED;
    const id = ctx.toFloat64(args[0]) catch return quickjs.UNDEFINED;
    if (!(id >= 1 and id <= @as(f64, @floatFromInt(host.timers.last_id))) or @floor(id) != id) return quickjs.UNDEFINED;
    host.timers.clear(ctx, host.gpa, @intFromFloat(id));
    return quickjs.UNDEFINED;
}

const testing = std.testing;
const support = @import("test_support.zig");

test "timers fire in order on a later pump, a zero delay set in a callback waits a pump, and a clear stops a timer" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.eval(
        \\globalThis.log = [];
        \\setTimeout(() => log.push("late"), 60000);
        \\setTimeout((a, b) => log.push("first" + a + b), 0, 1, 2);
        \\setTimeout(() => log.push("second"));
        \\const again = () => { log.push("again"); setTimeout(again, -5); };
        \\setTimeout(again, 0);
        \\clearTimeout(setTimeout(() => log.push("cleared"), 0));
        \\clearTimeout("x");
        \\new Promise((resolve) => setTimeout(resolve, 0)).then(() => log.push("reaction"));
        \\log.push("sync");
    , "order.js");
    try host.pump();
    try support.expectString(host, "log.join()", "sync,first12,second,again,reaction");
    try host.pump();
    try support.expectString(host, "log.join()", "sync,first12,second,again,reaction,again");
}

test "setInterval repeats until clearInterval from inside its own callback" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.eval("globalThis.ticks = 0; const id = setInterval(() => { if (++ticks === 3) clearInterval(id); }, 1);", "interval.js");
    try support.pumpUntilTrue(host, "ticks === 3");
    try testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
}

test "a timer callback that throws faults the pump, and later timers still run" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.eval("globalThis.after = 0; setTimeout(() => { throw new Error(\"boom\"); }, 0); setTimeout(() => { after = 1; }, 0);", "throw.js");
    try testing.expectError(error.JavaScriptFault, host.pump());
    try testing.expect(std.mem.indexOf(u8, host.faultText(), "boom") != null);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.after"));
}

test "timer arguments are checked, and a firing interval counts toward the limit" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.eval(
        \\globalThis.errors = [];
        \\try { setTimeout(42, 0); } catch (e) { errors.push(e.name); }
        \\for (let i = 0; i < 4095; i++) setTimeout(() => {}, 100000);
        \\const id = setInterval(() => { try { setTimeout(() => {}, 0); } catch (e) { errors.push(e.name); clearInterval(id); } }, 0);
    , "limit.js");
    try host.pump();
    try support.expectString(host, "errors.join()", "TypeError,RangeError");
}

test "host close frees every timer root and calls no callback" {
    var pool: support.Pool = .init;
    defer std.debug.assert(pool.deinit() == .ok);
    const host = Host.createWith(pool.allocator(), testing.io, support.hostOptions(""));
    try host.eval(
        \\globalThis.called = 0;
        \\const big = { payload: "x".repeat(1000) };
        \\setTimeout((value) => { called = value.payload.length; }, 0, big);
        \\setInterval(() => { called = 2; }, 5);
    , "close.js");
    host.destroy();
}

test "waitForWork returns at the next timer deadline with no wake" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.eval("setTimeout(() => {}, 40);", "wait.js");
    host.wake.reset();
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try host.waitForWork();
    const waited = started.durationTo(.now(testing.io, .awake)).toMilliseconds();
    try testing.expect(waited >= 30 and waited < 5000);
    try testing.expect(host.hasPending());
}
