//! The owner channel message: one reactor owner serves QuickJS, and every other task copies a plain message here.
const std = @import("std");
const zio = @import("zio");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const engine_module = @import("native/engine.zig");

const Event = term_pkg.Event;

pub const Channel = zio.Channel(Msg);

/// Drain engine events and JavaScript work on the one QuickJS owner.
pub fn pump(host: *host_mod.Host) host_mod.Error!void {
    if (drainEngine(host)) return error.JavaScriptFault;
    try host.pump();
}

/// Deliver engine events without changing TUI frame ordering.
pub fn drainEngine(host: *host_mod.Host) bool {
    return engine_module.drain(host.engine, host.ctx);
}

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
