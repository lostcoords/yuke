const std = @import("std");
const zio = @import("zio");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const extensions_mod = @import("extensions.zig");
const Host = host_mod.Host;
const tui_loop = @import("loop.zig");
const report = @import("report.zig");

const Event = term_pkg.Event;

pub const Channel = zio.Channel(Msg);

/// One owner message: a parser event with owned key or paste text, or a synthetic tick.
pub const Msg = union(enum) {
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
pub const EventBuf = struct {
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
    \\import { plugins } from "yuke:ext";
    \\import { tuiPlugin } from "yuke:tui";
    \\import { tuiInteractionPlugin } from "yuke:interaction-ui";
    \\import "yuke:core";
    \\import "yuke:defaults";
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

    var render = try term_pkg.Render.init(io, gpa, extensions.host.execution.env, .{});
    defer render.deinit(writer);
    try render.enterAltScreen(writer);
    // The terminal wraps pasted text in start and end markers.
    try render.setBracketedPaste(writer, true);
    // Mouse reporting is always on. The in-app selection replaces the selection of the terminal.
    try render.setMouseMode(writer, true);

    const host = extensions.host;

    const ws = try tty.getWinsize();
    try render.resize(writer, ws);
    host.paint.bindRender(host.ctx, &render, writer);
    if (extensions.user_entry_fault) report.paintFault(host);

    var input: term_pkg.Input = .{ .gpa = gpa };
    defer input.deinit();
    // The queue holds a wheel burst, so `serve` can fold it into one dispatch.
    var slot: [64]Msg = undefined;
    var ch = Channel.init(&slot);
    var group: zio.Group = .init;
    defer {
        // Stop all producers, then drain the queued messages, then close the channel.
        tty.shutdownInput();
        extensions.host.wake.set(extensions.host.io);
        group.cancel();
        drainChannel(gpa, &ch);
        ch.close(.immediate);
    }

    try group.spawn(inputTask, .{ gpa, &tty, &input, &ch });
    try group.spawn(tickTask, .{ host, &ch });
    if (!term_pkg.resize_in_band) {
        try group.spawn(winchTask, .{ &tty, &ch });
    }

    try serve(host, &ch);
}

/// Run `start`, then process queued events with `step`. Native quit ends the loop, but a script error does not.
pub fn serve(host: *Host, ch: *Channel) !void {
    std.debug.assert(host.phase == .open);
    if (tui_loop.start(host)) |_| {
        try absorbScriptFault(host, tui_loop.flushFrame(host));
    } else |err| try absorbScriptFault(host, err);
    if (host.engine.runtime) |application| application.engine.resumeWorkspace(host.cwd) catch |err| {
        std.log.warn("cannot resume the workspace: {t}", .{err});
    };
    while (!host.paint.quit_requested) {
        var msg = ch.receive() catch |err| switch (err) {
            error.ChannelClosed, error.Canceled => break,
            else => |e| return e,
        };

        // Apply every queued message, then paint once. A burst costs one frame, not one each.
        var wheel: ?tui_loop.WheelRun = null;
        var applied: u32 = 0;
        while (true) {
            try applyMsg(host, &msg, &wheel);
            applied += 1;
            if (applied >= drain_max or host.paint.quit_requested) break;
            msg = ch.tryReceive() catch break;
        }
        try absorbScriptFault(host, host.pump());
        try absorbScriptFault(host, tui_loop.flushWheel(host, &wheel));
        try absorbScriptFault(host, tui_loop.flushFrame(host));
    }
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

/// Free every message the owner never received. `stopReaders` must run first, so no reader sends.
fn drainChannel(gpa: std.mem.Allocator, ch: *Channel) void {
    while (ch.tryReceive()) |m| {
        var msg = m;
        msg.deinit(gpa);
    } else |_| {}
}

/// The shortest gap between two engine frames. Deltas merge in the engine, so a later drain loses nothing.
const engine_frame: zio.Duration = .fromMilliseconds(33);

/// The tick task enqueues plain messages. It never calls QuickJS.
fn tickTask(host: *Host, ch: *Channel) !void {
    const wake = &host.wake;
    var last: zio.Timestamp = .zero;
    while (!host.paint.quit_requested) {
        const due = tickDue(host, last) orelse {
            wake.wait(host.io) catch return;
            wake.reset();
            continue;
        };
        const now = zio.now();
        if (due.value > now.value) {
            // A wake before the deadline re-reads it, because a pending engine event may owe an earlier tick.
            wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromNanoseconds(due.value - now.value), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            wake.reset();
            continue;
        }
        last = now;
        ch.send(.tick) catch return;
    }
}

/// The next moment a tick is owed: the animation period or the engine frame gap, whichever is first.
fn tickDue(host: *const Host, last: zio.Timestamp) ?zio.Timestamp {
    var due: ?zio.Timestamp = null;
    if (host.paint.needs_tick) due = last.addDuration(.fromMilliseconds(host.paint.tick_period_ms));
    if (host.hasPending()) {
        const engine = last.addDuration(engine_frame);
        due = if (due) |d| (if (engine.value < d.value) engine else d) else engine;
    }
    return due;
}

/// Absorb a `JavaScriptFault`, paint the fault row, and keep the loop.
fn absorbScriptFault(host: *Host, result: host_mod.Error!void) host_mod.Error!void {
    result catch |err| switch (err) {
        error.JavaScriptFault => report.paintFault(host),
        else => |e| return e,
    };
}

/// Read TTY events. A decode error resets the input, only EOF or cancellation closes the channel, and the owner frees the paste text.
fn inputTask(gpa: std.mem.Allocator, tty: *term_pkg.Tty, input: *term_pkg.Input, ch: *Channel) !void {
    while (true) {
        const ev = input.readEvent(tty) catch |err| switch (err) {
            error.EndOfStream, error.Canceled => {
                ch.close(.graceful);
                return;
            },
            else => {
                input.reset();
                continue;
            },
        };
        switch (ev) {
            .key_press, .key_release, .mouse, .winsize, .focus_in, .focus_out => ch.send(Msg.from(ev)) catch return,
            .paste => |text| ch.send(Msg.from(ev)) catch {
                gpa.free(text);
                return;
            },
            else => {},
        }
    }
}

/// Watch SIGWINCH and skip a size when ioctl fails; `runIo` spawns this task only for a terminal with no in-band resize.
fn winchTask(tty: *term_pkg.Tty, ch: *Channel) !void {
    var watch = try term_pkg.WinsizeWatch.init();
    defer watch.deinit();
    while (true) {
        const ws = watch.wait(tty) catch |err| switch (err) {
            error.Canceled => {
                ch.close(.graceful);
                return;
            },
            else => continue,
        };
        ch.send(Msg.from(.{ .winsize = ws })) catch return;
    }
}

test "serve stops when q arrives" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var producer = try rt.spawn(sendQuit, .{&ch});
    try serve(host, &ch);
    producer.join() catch {};
    try std.testing.expect(host.paint.quit_requested);
}

test "serve folds a wheel run into one dispatch and keeps the next button" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval(
        \\globalThis.seen = [];
        \\globalThis.onEvent = (ev) => {
        \\  if (ev.type === "mouse") globalThis.seen.push(ev.button + ":" + ev.count);
        \\};
    , "count.js");

    // The queue holds the whole burst, so the fold has something to collapse.
    var slot: [16]Msg = undefined;
    var ch = Channel.init(&slot);
    var producer = try rt.spawn(sendWheelBurst, .{&ch});
    try serve(host, &ch);
    producer.join();

    // Five equal steps fold into one event. The opposite direction stays a separate event.
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt(
        "globalThis.seen.join(',') === 'wheel_down:5,wheel_up:1' ? 1 : 0",
    ));
}

test "a closed channel unblocks serve" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.eval("globalThis.seen = 0; globalThis.onEvent = () => { globalThis.seen++; };", "count.js");

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var producer = try rt.spawn(sendThenClose, .{&ch});
    try serve(host, &ch);
    producer.join();
    // `serve` handled `start` plus the key, then the close ended the loop rather than a quit.
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.seen"));
    try std.testing.expect(!host.paint.quit_requested);
}

test "serve keeps the loop after onEvent throw" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\globalThis.onEvent = (ev) => {
        \\  if (ev.char === "x") throw new Error("nope");
        \\  if (ev.char === "q") term.quit();
        \\};
    , "onEvent.js");

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var producer = try rt.spawn(sendThrowThenQuit, .{&ch});
    try serve(host, &ch);
    producer.join() catch {};
    try std.testing.expect(host.paint.quit_requested);
}

test "tickTask enqueues a tick while armed" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    host.paint.needs_tick = true;
    host.paint.tick_period_ms = 50;

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(tickTask, .{ host, &ch });

    const msg = try ch.receive();
    try std.testing.expect(msg == .tick);

    host.paint.needs_tick = false;
    host.paint.quit_requested = true;
    host.wake.set(host.io);
}

test "tickTask paces engine wakes to the frame gap" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    // No owner drains here, so the engine stays pending and the task must not flood the channel.
    host.engine.index_dirty = true;

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(tickTask, .{ host, &ch });

    const start = zio.now();
    var ticks: u32 = 0;
    while (start.untilNow(.monotonic).toMilliseconds() < 120) : (ticks += 1) {
        const msg = try ch.receive();
        try std.testing.expect(msg == .tick);
    }
    // The gap between two ticks is tens of milliseconds, so the window holds a handful and never a flood.
    try std.testing.expect(ticks >= 1 and ticks < 12);

    host.paint.quit_requested = true;
    host.wake.set(host.io);
}

fn sendQuit(ch: *Channel) !void {
    try ch.send(Msg.from(.{ .key_press = .{ .codepoint = 'q' } }));
}

fn sendThrowThenQuit(ch: *Channel) !void {
    try sendBounded(ch, Msg.from(.{ .key_press = .{ .codepoint = 'x' } }));
    try sendBounded(ch, Msg.from(.{ .key_press = .{ .codepoint = 'q' } }));
}

/// Bound a test send at one second, so a stalled `serve` fails rather than hangs.
const send_tries_max = 100;

/// Send with a bound, so a stalled consumer fails the test instead of parking the producer forever.
fn sendBounded(ch: *Channel, msg: Msg) !void {
    var tries: u8 = 0;
    while (true) : (tries += 1) {
        ch.trySend(msg) catch |err| switch (err) {
            error.ChannelFull => {
                if (tries == send_tries_max) return error.ConsumerStalled;
                try zio.sleep(.fromMilliseconds(10));
                continue;
            },
            else => |e| return e,
        };
        return;
    }
}

fn sendThenClose(ch: *Channel) void {
    ch.send(Msg.from(.{ .key_press = .{ .codepoint = 'a' } })) catch {};
    ch.close(.graceful);
}

fn wheelMsg(button: term_pkg.Mouse.Button) Msg {
    return Msg.from(.{ .mouse = .{ .col = 1, .row = 1, .button = button, .mods = .{}, .type = .press } });
}

/// Send a run of wheel steps, then a different button, then close. `serve` must fold only the run.
fn sendWheelBurst(ch: *Channel) void {
    for (0..5) |_| ch.send(wheelMsg(.wheel_down)) catch {};
    ch.send(wheelMsg(.wheel_up)) catch {};
    ch.close(.graceful);
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
