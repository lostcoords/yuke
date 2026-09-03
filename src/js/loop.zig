const std = @import("std");
const quickjs = @import("quickjs");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const Error = host_mod.Error;
const term_mod = @import("native/term.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Key = term_pkg.Key;
const Mouse = term_pkg.Mouse;
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
        .mouse => |m| try stepMouseRepeat(host, m, 1),
        .winsize => |ws| try stepResize(host, ws),
        .focus_in => try stepFocus(host, true),
        .focus_out => try stepFocus(host, false),
        // Ignore the leave and capability events.
        else => {},
    }
}

/// Dispatch a paste as its own event type, so a text input inserts `text` with one edit.
pub fn stepPaste(host: *Host, text: []const u8) Error!void {
    std.debug.assert(host.phase == .open);
    const obj = try pasteObject(host.ctx, text);
    _ = try dispatch(host, obj);
}

/// Dispatch a `tick` event on the reactor owner.
pub fn stepTick(host: *Host) Error!void {
    std.debug.assert(host.phase == .open);
    const obj = try objectType(host.ctx, "tick");
    _ = try dispatch(host, obj);
}

/// A key press or release. The tag name reaches JavaScript as `ev.event`.
const KeyKind = enum { press, release };

/// Dispatch a key. Without `onEvent`, `q` quits so a boot failure leaves an exit.
fn stepKey(host: *Host, key: Key, kind: KeyKind) Error!void {
    const obj = try keyObject(host.ctx, key, kind);
    if (try dispatch(host, obj)) return;
    if (kind == .press and (key.codepoint == 'q' or key.codepoint == 'Q')) {
        host.paint.needs_tick = false;
        host.paint.quit_requested = true;
    }
}

/// Dispatch one mouse event that stands for `count` equal steps, so a fast scroll costs one dispatch.
pub fn stepMouseRepeat(host: *Host, m: Mouse, count: u32) Error!void {
    std.debug.assert(host.phase == .open);
    std.debug.assert(count >= 1);
    const cell = if (host.paint.render) |r| r.vx.translateMouse(m) else m;
    const obj = try mouseObject(host.ctx, cell, count);
    _ = try dispatch(host, obj);
}

/// A run of equal wheel steps on one cell. The owner dispatches it once.
pub const WheelRun = struct {
    mouse: Mouse,
    count: u32,
};

/// The wheel button of a mouse event, or null for any other event.
pub fn wheelOf(ev: Event) ?Mouse.Button {
    const m = switch (ev) {
        .mouse => |m| m,
        else => return null,
    };
    return switch (m.button) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => m.button,
        else => null,
    };
}

fn mouseCell(host: *Host, m: Mouse) Mouse {
    return if (host.paint.render) |r| r.vx.translateMouse(m) else m;
}

/// Join a wheel event into `run` when it is the same button on the same cell.
pub fn foldWheel(host: *Host, run: *?WheelRun, ev: Event) Error!void {
    const btn = wheelOf(ev) orelse unreachable;
    const cell = mouseCell(host, ev.mouse);
    if (run.*) |*w| {
        const prev = mouseCell(host, w.mouse);
        if (w.mouse.button == btn and prev.col == cell.col and prev.row == cell.row) {
            w.count += 1;
            return;
        }
    }
    try flushWheel(host, run);
    run.* = .{ .mouse = ev.mouse, .count = 1 };
}

/// Dispatch the open wheel run, if one exists.
pub fn flushWheel(host: *Host, run: *?WheelRun) Error!void {
    const w = run.* orelse return;
    run.* = null;
    try stepMouseRepeat(host, w.mouse, w.count);
}

/// Dispatch a focus change the terminal reported.
fn stepFocus(host: *Host, focused: bool) Error!void {
    const obj = try focusObject(host.ctx, focused);
    _ = try dispatch(host, obj);
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
    if (!host.paint.defer_frame) try flushFrame(host);
    return true;
}

/// Paint the frame the handlers asked for; the owner calls this once per drained queue, so a burst costs one paint.
pub fn flushFrame(host: *Host) Error!void {
    const ctx = host.ctx;
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const flush = ctx.getPropertyStr(global, "flushFrame");
    defer ctx.freeValue(flush);
    if (ctx.isFunction(flush)) {
        const result = ctx.call(flush, quickjs.UNDEFINED, &.{});
        if (ctx.isException(result)) {
            host.paint.needs_tick = false;
            host.noteFault();
            return error.JavaScriptFault;
        }
        ctx.freeValue(result);
        try host.drainJobs();
    }
    term_mod.commitFrame(host);
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
    put(ctx, obj, "event", ctx.newString(@tagName(kind)));
    put(ctx, obj, "char", ctx.newString(char_s));
    put(ctx, obj, "shifted", ctx.newString(encode(key.shifted_codepoint orelse 0, &shifted_buf)));
    put(ctx, obj, "baseLayout", ctx.newString(encode(key.base_layout_codepoint orelse 0, &base_buf)));
    put(ctx, obj, "text", ctx.newString(key.text orelse ""));
    // Drop `caps_lock` and `num_lock`. A lock state must not change the binding that matches.
    put(ctx, obj, "mods", ctx.newInt32(bits & 0x3f));
    if (ctx.hasException()) return error.JavaScriptFault;
    return obj;
}

fn mouseObject(ctx: Context, m: Mouse, count: u32) Error!Value {
    const obj = try objectType(ctx, "mouse");
    errdefer ctx.freeValue(obj);

    // Normalize the mouse modifiers to the key bit layout: shift 1, alt 2, ctrl 4.
    const bits: u3 = @bitCast(m.mods);
    put(ctx, obj, "col", ctx.newInt32(m.col));
    put(ctx, obj, "row", ctx.newInt32(m.row));
    put(ctx, obj, "button", ctx.newString(@tagName(m.button)));
    put(ctx, obj, "event", ctx.newString(@tagName(m.type)));
    put(ctx, obj, "mods", ctx.newInt32(bits));
    put(ctx, obj, "count", ctx.newInt32(@intCast(count)));
    if (ctx.hasException()) return error.JavaScriptFault;
    return obj;
}

fn focusObject(ctx: Context, focused: bool) Error!Value {
    const obj = try objectType(ctx, "focus");
    errdefer ctx.freeValue(obj);

    put(ctx, obj, "focused", ctx.newBool(focused));
    if (ctx.hasException()) return error.JavaScriptFault;
    return obj;
}

fn pasteObject(ctx: Context, text: []const u8) Error!Value {
    const obj = try objectType(ctx, "paste");
    errdefer ctx.freeValue(obj);

    put(ctx, obj, "text", ctx.newString(text));
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

test "start and stepTick deliver their event type" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.onEvent = function(ev) { globalThis.seen = ev.type; };", "onEvent.js");
    try start(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen === 'start' ? 1 : 0"));
    try stepTick(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen === 'tick' ? 1 : 0"));
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

test "a paste arrives as one paste event with the whole text" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.onEvent = (ev) => { globalThis.ev = ev; };", "onEvent.js");

    const text = "line one\nline two";
    try stepPaste(host, text);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ev.type === 'paste' ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, @intCast(text.len)), try host.evalInt("globalThis.ev.text.length"));
}

test "a large paste reaches JavaScript in one event" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.n = 0; globalThis.onEvent = (ev) => { globalThis.n++; globalThis.len = ev.text.length; };", "onEvent.js");

    const text = try gpa.allocator().alloc(u8, 100 * 1024);
    defer gpa.allocator().free(text);
    @memset(text, 'x');
    try stepPaste(host, text);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.n"));
    try std.testing.expectEqual(@as(i32, 100 * 1024), try host.evalInt("globalThis.len"));
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

test "a mouse event reaches JavaScript with the cell, the button, and the modifiers" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.onEvent = (ev) => { globalThis.ev = ev; };", "onEvent.js");

    try step(host, .{ .mouse = .{
        .col = 3,
        .row = 4,
        .button = .left,
        .mods = .{ .ctrl = true },
        .type = .drag,
    } });
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ev.type === 'mouse' ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 3), try host.evalInt("globalThis.ev.col"));
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.ev.row"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ev.button === 'left' ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ev.event === 'drag' ? 1 : 0"));
    // The mouse and the key share the low three modifier bits.
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.ev.mods"));
}
test "focus in and focus out reach JavaScript" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.seen = []; globalThis.onEvent = (ev) => { globalThis.seen.push(ev.type + ':' + ev.focused); };", "onEvent.js");

    try step(host, .focus_in);
    try step(host, .focus_out);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen.join(',') === 'focus:true,focus:false' ? 1 : 0"));
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
