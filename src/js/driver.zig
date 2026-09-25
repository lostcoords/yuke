const std = @import("std");
const builtin = @import("builtin");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const extensions_mod = @import("extensions.zig");
const Host = host_mod.Host;
const tui_loop = @import("loop.zig");
const report = @import("report.zig");

const Event = term_pkg.Event;

const Queue = std.Io.Queue(Msg);

/// One owner message: a parser event with owned key or paste text, or a synthetic tick.
const Msg = union(enum) {
    event: EventBuf,
    paste: []const u8,
    tick,

    pub fn from(ev: Event) Msg {
        return switch (ev) {
            .paste => |text| .{ .paste = text },
            else => .{ .event = EventBuf.from(ev) },
        };
    }

    /// Free an owned paste payload. Every other variant owns nothing.
    pub fn deinit(self: *Msg, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .paste => |text| gpa.free(text),
            else => {},
        }
    }
};

/// A parser event plus a copy of its key text. The copy survives the next parse.
const EventBuf = struct {
    ev: Event,
    text: [128]u8 = undefined,
    n: u8 = 0,

    pub fn from(ev: Event) EventBuf {
        var m: EventBuf = .{ .ev = ev };
        const key = switch (ev) {
            .key_press, .key_release => |k| k,
            else => return m,
        };
        const t = key.text orelse return m;
        m.n = @intCast(@min(t.len, m.text.len));
        @memcpy(m.text[0..m.n], t[0..m.n]);
        return m;
    }

    pub fn event(self: *EventBuf) Event {
        if (self.n == 0) return self.ev;
        var ev = self.ev;
        switch (ev) {
            .key_press, .key_release => |*k| k.text = self.text[0..self.n],
            else => {},
        }
        return ev;
    }
};

const frame_buf_bytes = 256 * 1024;

/// Boot the terminal composition and publish its terminal capability.
pub const boot =
    \\import { plugins } from "yuke:internal/ext";
    \\import { tuiPlugin } from "yuke:internal/tui";
    \\import { tuiInteractionPlugin } from "yuke:internal/interaction-ui";
    \\import "yuke:internal/core";
    \\import "yuke:internal/defaults";
    \\plugins.use(tuiPlugin);
    \\plugins.use(tuiInteractionPlugin);
;

/// The largest run of messages one frame absorbs, so steady input never starves the screen.
const drain_max = 64;

/// Open the TTY, enter the alternate screen, and run until quit. The caller owns `extensions`.
pub fn runIo(extensions: *extensions_mod.Extensions) !void {
    const gpa = extensions.host.gpa;
    const io = extensions.host.io;
    var tty = try term_pkg.Tty.open(io);
    defer tty.deinit();

    var write_buf: [frame_buf_bytes]u8 = undefined;
    var file_w = tty.writerStreaming(&write_buf);
    const writer = &file_w.interface;

    var render = try term_pkg.Render.init(io, gpa, extensions.host.execution.env);
    defer render.deinit(writer);
    try render.enableTui(writer);

    const host = extensions.host;

    const ws = try tty.getWinsize();
    try render.resize(writer, ws);
    host.paint.bindRender(host.ctx, &render, writer);
    defer {
        host.stopPlugins();
        host.paint.output = null;
    }
    std.debug.assert(host.paint.output != null);
    host.paint.output.?.tty = &tty;
    if (extensions.user_entry_fault) report.paintFault(host);

    var input: term_pkg.Input = .{ .gpa = gpa };
    defer input.deinit();
    // The queue holds a wheel burst, so `serve` can fold it into one dispatch.
    var slot: [64]Msg = undefined;
    var queue: Queue = .init(&slot);
    var winch: ?term_pkg.WinsizeWatch = if (term_pkg.resize_in_band) null else try term_pkg.WinsizeWatch.init();
    defer if (winch) |*watch| watch.deinit();
    var group: std.Io.Group = .init;
    defer {
        // Stop all producers, then free the queued messages.
        tty.shutdownInput();
        host.wake.set(io);
        group.cancel(io);
        drainQueue(gpa, io, &queue);
    }

    try group.concurrent(io, inputTask, .{ gpa, io, &tty, &input, &queue });
    try group.concurrent(io, tickTask, .{ host, &queue });
    if (winch) |*watch| try group.concurrent(io, winchTask, .{ io, watch, &tty, &queue });

    try serve(host, &queue);
}

/// Run `start`, then process queued events with `step`. Native quit ends the loop, but a script error does not.
fn serve(host: *Host, queue: *Queue) !void {
    std.debug.assert(host.phase == .open);
    if (tui_loop.start(host)) |_| {
        try absorbScriptFault(host, tui_loop.flushFrame(host));
    } else |err| try absorbScriptFault(host, err);
    if (host.engine.runtime) |application| application.engine.resumeWorkspace(host.cwd) catch |err| {
        std.log.warn("cannot resume the workspace: {t}", .{err});
    };
    while (!host.paint.quit_requested) {
        var msg = queue.getOne(host.io) catch break;

        // Apply every queued message, then paint once. A burst costs one frame, not one each.
        var wheel: ?tui_loop.WheelRun = null;
        var applied: u32 = 0;
        while (true) {
            try applyMsg(host, &msg, &wheel);
            applied += 1;
            if (applied >= drain_max or host.paint.quit_requested or host.paint.suspend_requested) break;
            msg = take(host.io, queue) orelse break;
        }
        try absorbScriptFault(host, host.pump());
        try absorbScriptFault(host, tui_loop.flushWheel(host, &wheel));
        try parkIfRequested(host);
        try absorbScriptFault(host, tui_loop.flushFrame(host));
    }
}

/// Leave the TUI, stop, then restore and resize after continue.
fn parkIfRequested(host: *Host) !void {
    if (!host.paint.suspend_requested) return;
    host.paint.suspend_requested = false;
    if (builtin.os.tag == .windows) return;
    const output = host.paint.output orelse return;
    const tty = output.tty orelse return;
    output.render.resetState(output.writer);
    tty.restore();
    std.posix.raise(std.posix.SIG.TSTP) catch {};
    try tty.enterRaw();
    try output.render.enableTui(output.writer);
    output.render.queueRefresh();
    const ws = tty.getWinsize() catch term_pkg.Winsize{
        .rows = host.paint.height,
        .cols = host.paint.width,
        .x_pixel = 0,
        .y_pixel = 0,
    };
    try absorbScriptFault(host, tui_loop.step(host, .{ .winsize = ws }));
}

/// Apply one message; the caller owns the frame. A wheel step joins the open run, and every other message ends it.
fn applyMsg(host: *Host, msg: *Msg, wheel: *?tui_loop.WheelRun) !void {
    switch (msg.*) {
        .event => |*e| {
            const ev = e.event();
            if (tui_loop.wheelOf(ev) != null) {
                try absorbScriptFault(host, tui_loop.foldWheel(host, wheel, ev));
                return;
            }
            try absorbScriptFault(host, tui_loop.flushWheel(host, wheel));
            try absorbScriptFault(host, tui_loop.step(host, ev));
        },
        .tick => {
            try absorbScriptFault(host, tui_loop.flushWheel(host, wheel));
            try absorbScriptFault(host, tui_loop.stepTick(host));
        },
        .paste => |text| {
            defer msg.deinit(host.gpa);
            try absorbScriptFault(host, tui_loop.flushWheel(host, wheel));
            try absorbScriptFault(host, tui_loop.stepPaste(host, text));
        },
    }
}

/// Take a queued message without blocking.
fn take(io: std.Io, queue: *Queue) ?Msg {
    var one: [1]Msg = undefined;
    const n = queue.getUncancelable(io, &one, 0) catch return null;
    return if (n == 1) one[0] else null;
}

/// Close the queue and free every message the owner never received. The producers must stop first.
fn drainQueue(gpa: std.mem.Allocator, io: std.Io, queue: *Queue) void {
    queue.close(io);
    while (take(io, queue)) |m| {
        var msg = m;
        msg.deinit(gpa);
    }
}

/// The shortest gap between two engine frames. Deltas merge in the engine, so a later drain loses nothing.
const engine_frame: std.Io.Duration = .fromMilliseconds(33);

/// The tick task enqueues plain messages. It never calls QuickJS.
fn tickTask(host: *Host, queue: *Queue) std.Io.Cancelable!void {
    const wake = &host.wake;
    var last: std.Io.Timestamp = .zero;
    while (!host.paint.quit_requested) {
        const due = tickDue(host, last) orelse {
            wake.wait(host.io) catch return;
            wake.reset();
            continue;
        };
        const now = std.Io.Timestamp.now(host.io, .awake);
        if (due.nanoseconds > now.nanoseconds) {
            // A wake before the deadline re-reads it, because an engine event or a new timer may owe an earlier tick.
            wake.waitTimeout(host.io, .{ .deadline = .{ .raw = due, .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            wake.reset();
            continue;
        }
        last = now;
        queue.putOne(host.io, .tick) catch return;
    }
}

/// The next moment a tick is owed: the animation period, the engine frame gap, or the next timer, whichever is first.
fn tickDue(host: *const Host, last: std.Io.Timestamp) ?std.Io.Timestamp {
    var due: ?std.Io.Timestamp = null;
    if (host.paint.needs_tick) due = last.addDuration(.fromMilliseconds(host.paint.tick_period_ms));
    if (host.hasPending()) due = earlier(due, last.addDuration(engine_frame));
    // A due timer is paced like engine work, so the task sends one tick per frame and not one per loop.
    if (host.timers.nextDeadline()) |timer| {
        const paced = last.addDuration(engine_frame);
        due = earlier(due, if (timer.nanoseconds < paced.nanoseconds) paced else timer);
    }
    return due;
}

fn earlier(a: ?std.Io.Timestamp, b: std.Io.Timestamp) std.Io.Timestamp {
    const first = a orelse return b;
    return if (b.nanoseconds < first.nanoseconds) b else first;
}

/// Absorb a `JavaScriptFault`, paint the fault row, and keep the loop.
fn absorbScriptFault(host: *Host, result: host_mod.Error!void) host_mod.Error!void {
    result catch |err| switch (err) {
        error.JavaScriptFault => report.paintFault(host),
    };
}

/// Read TTY events. A decode error resets the input, only EOF or cancellation closes the queue, and the owner frees the paste text.
fn inputTask(gpa: std.mem.Allocator, io: std.Io, tty: *term_pkg.Tty, input: *term_pkg.Input, queue: *Queue) std.Io.Cancelable!void {
    while (true) {
        const ev = input.readEvent(tty) catch |err| switch (err) {
            error.EndOfStream, error.Canceled => {
                queue.close(io);
                return;
            },
            else => {
                input.reset();
                continue;
            },
        };
        switch (ev) {
            .key_press, .key_release, .mouse, .winsize, .focus_in, .focus_out => queue.putOne(io, Msg.from(ev)) catch return,
            .paste => |text| queue.putOne(io, Msg.from(ev)) catch {
                gpa.free(text);
                return;
            },
            else => {},
        }
    }
}

/// Watch SIGWINCH and skip a size when ioctl fails; `runIo` spawns this task only for a terminal with no in-band resize.
fn winchTask(io: std.Io, watch: *term_pkg.WinsizeWatch, tty: *term_pkg.Tty, queue: *Queue) std.Io.Cancelable!void {
    while (true) {
        const ws = watch.wait(tty) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        queue.putOne(io, Msg.from(.{ .winsize = ws })) catch return;
    }
}

const zio = @import("zio");
const support = @import("tests/support.zig");

test "serve stops when q arrives" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);

    var slot: [1]Msg = undefined;
    var queue: Queue = .init(&slot);
    var producer = try host.io.concurrent(sendKeys, .{ host.io, &queue, "q" });
    try serve(host, &queue);
    try producer.await(host.io);
    try std.testing.expect(host.paint.quit_requested);
}

test "serve folds a wheel run into one dispatch and keeps the next button" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);
    try host.eval(
        \\globalThis.seen = [];
        \\globalThis.onEvent = (ev) => {
        \\  if (ev.type === "mouse") globalThis.seen.push(ev.button + ":" + ev.count);
        \\};
    , "count.js");

    // The queue holds the whole burst, so the fold has something to collapse.
    var slot: [16]Msg = undefined;
    var queue: Queue = .init(&slot);
    var producer = try host.io.concurrent(sendWheelBurst, .{ host.io, &queue });
    try serve(host, &queue);
    try producer.await(host.io);

    // Five equal steps fold into one event. The opposite direction stays a separate event.
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt(
        "globalThis.seen.join(',') === 'wheel_down:5,wheel_up:1' ? 1 : 0",
    ));
}

test "a closed queue unblocks serve" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);
    try host.eval("globalThis.seen = 0; globalThis.onEvent = () => { globalThis.seen++; };", "count.js");

    var slot: [1]Msg = undefined;
    var queue: Queue = .init(&slot);
    var producer = try host.io.concurrent(sendKeys, .{ host.io, &queue, "a" });
    try serve(host, &queue);
    try producer.await(host.io);
    // `serve` handled `start` plus the key, then the close ended the loop rather than a quit.
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.seen"));
    try std.testing.expect(!host.paint.quit_requested);
}

test "serve keeps the loop after onEvent throw" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { term } from "yuke:internal/native/term";
        \\globalThis.onEvent = (ev) => {
        \\  if (ev.char === "x") throw new Error("nope");
        \\  if (ev.char === "q") term.quit();
        \\};
    , "onEvent.js");

    var slot: [1]Msg = undefined;
    var queue: Queue = .init(&slot);
    var producer = try host.io.concurrent(sendKeys, .{ host.io, &queue, "xq" });
    try serve(host, &queue);
    try producer.await(host.io);
    try std.testing.expect(host.paint.quit_requested);
}

test "tickTask enqueues a tick while armed" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);
    host.paint.needs_tick = true;
    host.paint.tick_period_ms = 50;

    var slot: [1]Msg = undefined;
    var queue: Queue = .init(&slot);
    var group: std.Io.Group = .init;
    defer group.cancel(host.io);
    try group.concurrent(host.io, tickTask, .{ host, &queue });

    try std.testing.expect(try queue.getOne(host.io) == .tick);
}

test "tickTask wakes for a timer set while it sleeps with no deadline" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);

    var slot: [1]Msg = undefined;
    var queue: Queue = .init(&slot);
    var group: std.Io.Group = .init;
    defer group.cancel(host.io);
    try group.concurrent(host.io, tickTask, .{ host, &queue });
    // Nothing is owed, so the task sleeps on the wake with no deadline before the timer exists.
    try host.io.sleep(.fromMilliseconds(20), .awake);

    const started: std.Io.Timestamp = .now(host.io, .awake);
    try host.eval("setTimeout(() => {}, 30);", "tick-timer.js");
    try std.testing.expect(try queue.getOne(host.io) == .tick);
    try std.testing.expect(started.durationTo(.now(host.io, .awake)).toMilliseconds() >= 25);
}

test "tickDue paces engine work and due timers to the frame gap" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const last: std.Io.Timestamp = .now(host.io, .awake);
    try std.testing.expectEqual(null, tickDue(host, last));

    // Pending engine work waits one frame after the last tick, so a busy engine never floods the queue.
    host.engine.index_dirty = true;
    try std.testing.expectEqual(last.addDuration(engine_frame).nanoseconds, tickDue(host, last).?.nanoseconds);
    host.engine.index_dirty = false;

    // A timer due inside the frame waits for the frame; a later timer keeps its own deadline.
    try host.eval("globalThis.soon = setTimeout(() => {}, 0);", "tick-soon.js");
    try std.testing.expectEqual(last.addDuration(engine_frame).nanoseconds, tickDue(host, last).?.nanoseconds);
    try host.eval("clearTimeout(soon); setTimeout(() => {}, 60000);", "tick-late.js");
    try std.testing.expect(tickDue(host, last).?.nanoseconds > last.addDuration(engine_frame).nanoseconds);
}

/// Send one key press per character, then close the queue.
fn sendKeys(io: std.Io, queue: *Queue, keys: []const u8) !void {
    defer queue.close(io);
    for (keys) |key| try queue.putOne(io, Msg.from(.{ .key_press = .{ .codepoint = key } }));
}

fn wheelMsg(button: term_pkg.Mouse.Button) Msg {
    return Msg.from(.{ .mouse = .{ .col = 1, .row = 1, .button = button, .mods = .{}, .type = .press } });
}

/// Send a run of wheel steps, then a different button, then close. `serve` must fold only the run.
fn sendWheelBurst(io: std.Io, queue: *Queue) !void {
    defer queue.close(io);
    for (0..5) |_| try queue.putOne(io, wheelMsg(.wheel_down));
    try queue.putOne(io, wheelMsg(.wheel_up));
}

test "a paste message owns its text" {
    const gpa = std.testing.allocator;
    const text = try gpa.dupe(u8, "pasted");
    var msg = Msg.from(.{ .paste = text });
    defer msg.deinit(gpa);
    try std.testing.expectEqualStrings("pasted", msg.paste);
}

test "queued key text survives a later parse" {
    var input: term_pkg.Input = .{};
    try input.push("ab");
    const first = (try input.next()).?;
    var buf = EventBuf.from(first);
    _ = try input.next();
    try std.testing.expectEqualStrings("a", buf.event().key_press.text.?);
}
