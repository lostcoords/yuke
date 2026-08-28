const std = @import("std");
const zio = @import("zio");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const tui_loop = @import("loop.zig");
const report = @import("report.zig");

const Event = term_pkg.Event;
const Channel = zio.Channel(Msg);

const frame_buf_bytes = 256 * 1024;

/// Bound a test send at one second, so a stalled `serve` fails rather than hangs.
const send_tries_max = 100;

/// The user entry file inside the config directory.
pub const user_entry = "index.js";

pub const Options = struct {
    /// The config directory holds `index.js`.
    /// A null value skips the user entry.
    config_dir: ?[]const u8 = null,
    /// Skip the user entry file.
    /// `--safe-mode` sets `safe_mode` to `true`.
    safe_mode: bool = false,
};

/// One owner message: a parser event with owned key text, or a synthetic tick.
const Msg = union(enum) {
    event: EventBuf,
    tick,

    fn from(ev: Event) Msg {
        return .{ .event = EventBuf.from(ev) };
    }
};

/// A parser event plus a copy of its key text. The copy survives the next parse.
const EventBuf = struct {
    ev: Event,
    text: [128]u8 = undefined,
    n: u8 = 0,

    fn from(ev: Event) EventBuf {
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

    fn event(self: *EventBuf) Event {
        if (self.n == 0) return self.ev;
        var ev = self.ev;
        switch (ev) {
            .key_press, .key_release => |*k| k.text = self.text[0..self.n],
            else => {},
        }
        return ev;
    }
};

/// Open the TTY, enter the alternate screen, and run until quit.
pub fn run(gpa: std.mem.Allocator, env: *std.process.Environ.Map, opts: Options) !void {
    var rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    try runIo(gpa, rt.io(), env, opts);
}

fn runIo(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, opts: Options) !void {
    var tty = try term_pkg.Tty.open(io);
    defer tty.deinit();

    var write_buf: [frame_buf_bytes]u8 = undefined;
    var file_w = tty.writerStreaming(&write_buf);
    const writer = &file_w.interface;

    var render = try term_pkg.Render.init(io, gpa, env, .{});
    defer render.deinit(writer);
    try render.enterAltScreen(writer);

    const host = try Host.createWith(gpa, io, .{});
    defer host.destroy();

    const ws = try tty.getWinsize();
    try render.resize(writer, ws);
    host.bindRender(&render, writer);

    var tick_wake: zio.ResetEvent = .init;
    host.paint.tick_wake = &tick_wake;

    var input: term_pkg.Input = .{};
    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var group: zio.Group = .init;
    defer {
        ch.close(.immediate);
        tty.shutdownInput();
        tick_wake.set();
        group.cancel();
    }

    try group.spawn(inputTask, .{ &tty, &input, &ch });
    try group.spawn(tickTask, .{ host, &ch });
    if (!term_pkg.resize_in_band) {
        try group.spawn(winchTask, .{ &tty, &ch });
    }

    // The baked graph is trusted, so its compile and run are not bounded. The user entry is bounded.
    host.interrupt_budget = std.math.maxInt(u32);
    try host.evalModule("import \"yuke:core\";\nimport \"yuke:defaults\";", "boot.js");
    host.interrupt_budget = host_mod.default_interrupt_budget;
    if (!opts.safe_mode) try absorbScriptFault(host, evalUserEntry(host, opts.config_dir));
    try serve(host, &ch);
}

/// Evaluate `<config_dir>/index.js`. A missing directory or file is not an error.
/// The path is joined on the heap, so no path length can silently drop the entry.
fn evalUserEntry(host: *Host, config_dir: ?[]const u8) host_mod.Error!void {
    const dir = config_dir orelse return;
    const path = try std.fs.path.joinZ(host.gpa, &.{ dir, user_entry });
    defer host.gpa.free(path);
    _ = try host.evalFile(path);
}

test "a user entry file evaluates and a missing one is not an error" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = user_entry,
        .data = "globalThis.result = 5;\n",
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try evalUserEntry(host, dir);
    try std.testing.expectEqual(@as(i32, 5), try host.evalInt("globalThis.result"));

    try evalUserEntry(host, null);
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    var empty_buf: [std.fs.max_path_bytes]u8 = undefined;
    const empty_len = try empty.dir.realPath(std.testing.io, &empty_buf);
    try evalUserEntry(host, empty_buf[0..empty_len]);
}

test "a throwing user entry is a JavaScriptFault the loop absorbs" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = user_entry,
        .data = "throw new Error('bad config');\n",
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        evalUserEntry(host, dir_buf[0..dir_len]),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "bad config") != null);
    try absorbScriptFault(host, evalUserEntry(host, dir_buf[0..dir_len]));
}

/// Run `start`, then process queued events with `step`.
/// A script error keeps the alternate screen. Native quit ends the loop.
pub fn serve(host: *Host, ch: *Channel) !void {
    std.debug.assert(host.phase == .open);
    try absorbScriptFault(host, tui_loop.start(host));
    while (!host.paint.quit_requested) {
        var msg = ch.receive() catch |err| switch (err) {
            error.ChannelClosed, error.Canceled => break,
            else => |e| return e,
        };
        switch (msg) {
            .tick => try absorbScriptFault(host, tui_loop.stepTick(host)),
            .event => |*e| try absorbScriptFault(host, tui_loop.step(host, e.event())),
        }
    }
}

/// The tick task enqueues plain messages. It never calls QuickJS.
fn tickTask(host: *Host, ch: *Channel) !void {
    const wake = host.paint.tick_wake.?;
    while (true) {
        if (!host.paint.needs_tick) {
            wake.wait() catch return;
        } else {
            const period = host.paint.tick_period_ms;
            wake.timedWait(.fromMilliseconds(period)) catch |err| switch (err) {
                error.Timeout => {
                    if (host.paint.needs_tick and !host.paint.quit_requested) {
                        ch.send(.tick) catch return;
                    }
                },
                error.Canceled => return,
            };
        }
        wake.reset();
    }
}

/// Absorb a `JavaScriptFault` and keep the loop.
/// Paint the fault row when the function absorbs a `JavaScriptFault`.
fn absorbScriptFault(host: *Host, result: host_mod.Error!void) host_mod.Error!void {
    result catch |err| switch (err) {
        error.JavaScriptFault => report.paintFault(host),
        else => |e| return e,
    };
}

/// Read TTY events. Drop the input buffer on overflow.
/// Close the channel only on EOF or cancellation.
fn inputTask(tty: *term_pkg.Tty, input: *term_pkg.Input, ch: *Channel) !void {
    while (true) {
        const ev = input.readEvent(tty) catch |err| switch (err) {
            error.EndOfStream, error.Canceled => {
                ch.close(.graceful);
                return;
            },
            else => {
                input.len = 0;
                continue;
            },
        };
        switch (ev) {
            .key_press, .key_release, .winsize => ch.send(Msg.from(ev)) catch return,
            else => {},
        }
    }
}

/// Watch SIGWINCH. Skip a size when ioctl fails.
/// `runIo` spawns this task only when the terminal does not send resize events in-band.
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

test "queued key text survives a later parse" {
    var input: term_pkg.Input = .{};
    try input.push("ab");
    const first = (try input.next()).?;
    var buf = EventBuf.from(first);
    _ = try input.next();
    try std.testing.expectEqualStrings("a", buf.event().key_press.text.?);
}

test "serve stops when q arrives" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = try Host.create(gpa.allocator());
    defer host.destroy();

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var producer = try rt.spawn(sendQuit, .{&ch});
    try serve(host, &ch);
    producer.join() catch {};
    try std.testing.expect(host.paint.quit_requested);
}

test "a closed channel unblocks serve" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();

    const host = try Host.create(gpa.allocator());
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

    const host = try Host.create(gpa.allocator());
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

    const host = try Host.create(gpa.allocator());
    defer host.destroy();

    var wake: zio.ResetEvent = .init;
    host.paint.tick_wake = &wake;
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
    wake.set();
}

fn sendQuit(ch: *Channel) !void {
    try ch.send(Msg.from(.{ .key_press = .{ .codepoint = 'q' } }));
}

fn sendThrowThenQuit(ch: *Channel) !void {
    try sendBounded(ch, Msg.from(.{ .key_press = .{ .codepoint = 'x' } }));
    try sendBounded(ch, Msg.from(.{ .key_press = .{ .codepoint = 'q' } }));
}

/// Send with a bound. A stalled consumer fails the test instead of parking the producer forever.
/// The owner channel holds one message, so a second send blocks when `serve` stops.
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
