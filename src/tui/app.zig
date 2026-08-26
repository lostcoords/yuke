const std = @import("std");
const zio = @import("zio");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const tui_loop = @import("loop.zig");

const Event = term_pkg.Event;
const Channel = zio.Channel(Msg);

const frame_buf_bytes = 256 * 1024;

/// An event with owned key text. The copy survives the next parse.
const Msg = struct {
    ev: Event,
    text: [128]u8 = undefined,
    n: u8 = 0,

    fn from(ev: Event) Msg {
        var m: Msg = .{ .ev = ev };
        const key = switch (ev) {
            .key_press, .key_release => |k| k,
            else => return m,
        };
        const t = key.text orelse return m;
        m.n = @intCast(@min(t.len, m.text.len));
        @memcpy(m.text[0..m.n], t[0..m.n]);
        return m;
    }

    fn event(self: *Msg) Event {
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
pub fn run(gpa: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    var rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    try runIo(gpa, rt.io(), env);
}

fn runIo(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
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

    var input: term_pkg.Input = .{};
    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var group: zio.Group = .init;
    defer {
        ch.close(.immediate);
        tty.shutdownInput();
        group.cancel();
    }

    try group.spawn(inputTask, .{ &tty, &input, &ch });
    if (!term_pkg.resize_in_band) {
        try group.spawn(winchTask, .{ &tty, &ch });
    }

    try host.evalModule("import \"yuke:core\";", "boot.js");
    try serve(host, &ch);
}

/// Run `start`, then process queued events with `step`.
/// A script error keeps the alternate screen. Native quit ends the loop.
pub fn serve(host: *Host, ch: *Channel) !void {
    std.debug.assert(host.phase == .open);
    try absorbScriptFault(tui_loop.start(host));
    while (!host.paint.quit_requested) {
        var msg = ch.receive() catch |err| switch (err) {
            error.ChannelClosed, error.Canceled => break,
            else => |e| return e,
        };
        try absorbScriptFault(tui_loop.step(host, msg.event()));
    }
}

fn absorbScriptFault(result: host_mod.Error!void) host_mod.Error!void {
    result catch |err| switch (err) {
        error.JavaScriptFault => {},
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
/// Windows sends resize events in-band.
fn winchTask(tty: *term_pkg.Tty, ch: *Channel) !void {
    if (comptime term_pkg.resize_in_band) {
        ch.close(.graceful);
        return;
    } else {
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
}

test "queued key text survives a later parse" {
    var input: term_pkg.Input = .{};
    try input.push("ab");
    const first = (try input.next()).?;
    var msg = Msg.from(first);
    _ = try input.next();
    try std.testing.expectEqualStrings("a", msg.event().key_press.text.?);
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

    var slot: [1]Msg = undefined;
    var ch = Channel.init(&slot);
    var producer = try rt.spawn(closeChannel, .{&ch});
    try serve(host, &ch);
    producer.join();
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

fn sendQuit(ch: *Channel) !void {
    try ch.send(Msg.from(.{ .key_press = .{ .codepoint = 'q' } }));
}

fn sendThrowThenQuit(ch: *Channel) !void {
    try ch.send(Msg.from(.{ .key_press = .{ .codepoint = 'x' } }));
    try ch.send(Msg.from(.{ .key_press = .{ .codepoint = 'q' } }));
}

fn closeChannel(ch: *Channel) void {
    ch.close(.graceful);
}
