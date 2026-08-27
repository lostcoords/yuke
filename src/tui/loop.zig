const std = @import("std");
const quickjs = @import("quickjs");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const Error = host_mod.Error;
const term_mod = @import("modules/term.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Key = term_pkg.Key;
const Event = term_pkg.Event;
const Winsize = term_pkg.Winsize;

/// Dispatch a `start` event.
pub fn start(host: *Host) Error!void {
    std.debug.assert(host.phase == .open);
    const obj = try objectType(host.ctx, "start");
    _ = try dispatch(host, obj);
}

/// Process one parser event on the owner.
pub fn step(host: *Host, ev: Event) Error!void {
    std.debug.assert(host.phase == .open);
    switch (ev) {
        .key_press => |k| try stepKey(host, k, .press),
        .key_release => |k| try stepKey(host, k, .release),
        .winsize => |ws| try stepResize(host, ws),
        else => {},
    }
}

/// A key press or release. The name reaches JavaScript as `ev.event`.
const KeyKind = enum {
    press,
    release,

    fn name(self: KeyKind) []const u8 {
        return @tagName(self);
    }
};

/// Dispatch a key. Without `onEvent`, `q` quits so a boot failure leaves an exit.
fn stepKey(host: *Host, key: Key, kind: KeyKind) Error!void {
    const obj = try keyObject(host.ctx, key, kind);
    if (try dispatch(host, obj)) return;
    if (kind == .press and (key.codepoint == 'q' or key.codepoint == 'Q')) {
        host.paint.needs_tick = false;
        host.paint.quit_requested = true;
    }
}

fn stepResize(host: *Host, ws: Winsize) Error!void {
    host.resize(ws);
    const ctx = host.ctx;
    const obj = try objectType(ctx, "resize");
    ctx.setPropertyStr(obj, "w", ctx.newInt32(host.paint.width)) catch {
        ctx.freeValue(obj);
        return error.JavaScriptFault;
    };
    ctx.setPropertyStr(obj, "h", ctx.newInt32(host.paint.height)) catch {
        ctx.freeValue(obj);
        return error.JavaScriptFault;
    };
    _ = try dispatch(host, obj);
}

/// Call `globalThis.onEvent` with `obj`. Return false when no handler exists.
fn dispatch(host: *Host, obj: Value) Error!bool {
    const ctx = host.ctx;
    defer ctx.freeValue(obj);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const handler = ctx.getPropertyStr(global, "onEvent");
    defer ctx.freeValue(handler);
    if (!ctx.isFunction(handler)) return false;

    host.enterSlice();
    const result = ctx.call(handler, quickjs.UNDEFINED, &.{obj});
    if (ctx.isException(result)) {
        host.paint.needs_tick = false;
        host.noteFault();
        return error.JavaScriptFault;
    }
    ctx.freeValue(result);
    try host.drainJobs();
    term_mod.commitIfDirty(host);
    return true;
}

fn objectType(ctx: Context, typ: []const u8) Error!Value {
    const obj = ctx.newObject();
    if (ctx.isException(obj)) return error.JavaScriptFault;
    ctx.setPropertyStr(obj, "type", ctx.newString(typ)) catch {
        ctx.freeValue(obj);
        return error.JavaScriptFault;
    };
    return obj;
}

fn keyObject(ctx: Context, key: Key, kind: KeyKind) Error!Value {
    const obj = try objectType(ctx, "key");
    errdefer ctx.freeValue(obj);

    const code = keyCode(key.codepoint);
    var char_buf: [4]u8 = undefined;
    var shifted_buf: [4]u8 = undefined;
    var base_buf: [4]u8 = undefined;
    const char_s: []const u8 = if (std.mem.eql(u8, code, "char")) encode(key.codepoint, &char_buf) else "";
    const bits: u8 = @bitCast(key.mods);
    put(ctx, obj, "code", ctx.newString(code));
    put(ctx, obj, "event", ctx.newString(kind.name()));
    put(ctx, obj, "char", ctx.newString(char_s));
    put(ctx, obj, "shifted", ctx.newString(encode(key.shifted_codepoint orelse 0, &shifted_buf)));
    put(ctx, obj, "baseLayout", ctx.newString(encode(key.base_layout_codepoint orelse 0, &base_buf)));
    put(ctx, obj, "text", ctx.newString(key.text orelse ""));
    // Drop `caps_lock` and `num_lock`. A lock state must not change the binding that matches.
    put(ctx, obj, "mods", ctx.newInt32(bits & 0x3f));
    if (ctx.hasException()) return error.JavaScriptFault;
    return obj;
}

fn put(ctx: Context, obj: Value, name: [*:0]const u8, val: Value) void {
    ctx.setPropertyStr(obj, name, val) catch {};
}

fn encode(cp: u21, buf: *[4]u8) []const u8 {
    if (cp == 0) return "";
    const n = std.unicode.utf8Encode(cp, buf) catch return "";
    return buf[0..n];
}

fn keyCode(cp: u21) []const u8 {
    return switch (cp) {
        Key.tab => "tab",
        Key.enter => "enter",
        Key.escape => "esc",
        Key.backspace => "backspace",
        Key.insert => "insert",
        Key.delete => "delete",
        Key.left => "left",
        Key.right => "right",
        Key.up => "up",
        Key.down => "down",
        Key.page_up => "page_up",
        Key.page_down => "page_down",
        Key.home => "home",
        Key.end => "end",
        Key.menu => "menu",
        Key.f1 => "f1",
        Key.f2 => "f2",
        Key.f3 => "f3",
        Key.f4 => "f4",
        Key.f5 => "f5",
        Key.f6 => "f6",
        Key.f7 => "f7",
        Key.f8 => "f8",
        Key.f9 => "f9",
        Key.f10 => "f10",
        Key.f11 => "f11",
        Key.f12 => "f12",
        else => if (cp >= 57344 and cp <= 63743) "unknown" else "char",
    };
}

test "start delivers type start" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.onEvent = function(ev) { globalThis.seen = ev.type; };", "onEvent.js");
    try start(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen === 'start' ? 1 : 0"));
}

test "a parser key paints and a missing endFrame still commits" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &out.writer);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\globalThis.onEvent = (ev) => {
        \\  globalThis.code = ev.code;
        \\  globalThis.ch = ev.char;
        \\  term.beginFrame();
        \\  term.text(0, 0, ev.char);
        \\};
    , "onEvent.js");
    var input: term_pkg.Input = .{};
    try input.push("a");
    const ev = (try input.next()).?;
    try step(host, ev);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.code === 'char' && globalThis.ch === 'a' ? 1 : 0"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a") != null);
}

test "onEvent throw is a JavaScriptFault" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.onEvent = function(ev) { throw new Error('nope'); };", "onEvent.js");
    try std.testing.expectError(error.JavaScriptFault, start(host));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "nope") != null);
    try std.testing.expect(!host.paint.needs_tick);
}

test "q with no handler requests quit" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try step(host, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(host.paint.quit_requested);
}

test "a key reports the modifiers and no lock state" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.onEvent = (ev) => { globalThis.ev = ev; };", "onEvent.js");
    try step(host, .{ .key_press = .{
        .codepoint = 'a',
        .mods = .{ .ctrl = true, .caps_lock = true, .num_lock = true },
    } });
    // `mods` carries ctrl only. The lock bits never reach JavaScript.
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.ev.mods"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("'locks' in globalThis.ev ? 0 : 1"));
}

test "resize updates term.width before JS reads ev.w" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &out.writer);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\globalThis.onEvent = (ev) => {
        \\  globalThis.w = ev.w;
        \\  globalThis.tw = term.width;
        \\};
    , "onEvent.js");
    try step(host, .{ .winsize = .{ .rows = 3, .cols = 8, .x_pixel = 0, .y_pixel = 0 } });
    try std.testing.expectEqual(@as(i32, 8), try host.evalInt("globalThis.w"));
    try std.testing.expectEqual(@as(i32, 8), try host.evalInt("globalThis.tw"));
}
