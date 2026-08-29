const std = @import("std");
const quickjs = @import("quickjs");
const term_pkg = @import("term");
const Host = @import("../host.zig").Host;

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;
const Modifiers = term_pkg.Key.Modifiers;

/// The largest clipboard payload `term.copy` accepts. JavaScript reads it to report a refusal.
pub const clipboard_max = term_pkg.Render.clipboard_max;

pub const tick_ms_min: u32 = 50;
pub const tick_ms_max: u32 = 2000;

/// Register the closed `yuke:term` module and export `term`.
pub fn install(host: *Host) error{OutOfMemory}!void {
    std.debug.assert(host.phase == .open);
    const m = host.ctx.newModule("yuke:term", init) orelse return error.OutOfMemory;
    host.ctx.addModuleExport(m, "term") catch return error.OutOfMemory;
}

fn init(ctx: Context, m: Module) c_int {
    const host = Host.fromContext(ctx);
    std.debug.assert(host.phase == .open);

    const term_obj = ctx.newObject();
    if (ctx.isException(term_obj)) return -1;

    if (bindAll(ctx, host, term_obj) != 0) {
        ctx.freeValue(term_obj);
        return -1;
    }

    const size_obj = ctx.newObject();
    if (ctx.isException(size_obj)) {
        ctx.freeValue(term_obj);
        return -1;
    }
    ctx.setPropertyStr(size_obj, "w", ctx.newInt32(host.paint.width)) catch {
        ctx.freeValue(size_obj);
        ctx.freeValue(term_obj);
        return -1;
    };
    ctx.setPropertyStr(size_obj, "h", ctx.newInt32(host.paint.height)) catch {
        ctx.freeValue(size_obj);
        ctx.freeValue(term_obj);
        return -1;
    };

    host.paint.size_obj = ctx.dupValue(size_obj);
    ctx.freeValue(size_obj);
    host.paint.term_obj = ctx.dupValue(term_obj);
    ctx.setModuleExport(m, "term", term_obj) catch {
        // The export call owns `term_obj`, even when it fails.
        ctx.freeValue(host.paint.term_obj);
        ctx.freeValue(host.paint.size_obj);
        host.paint.term_obj = quickjs.UNDEFINED;
        host.paint.size_obj = quickjs.UNDEFINED;
        return -1;
    };
    return 0;
}

fn bindAll(ctx: Context, host: *Host, term_obj: Value) c_int {
    bind(ctx, term_obj, "beginFrame", 0, beginFrame) catch return -1;
    bind(ctx, term_obj, "endFrame", 0, endFrame) catch return -1;
    bind(ctx, term_obj, "fill", 4, fill) catch return -1;
    bind(ctx, term_obj, "text", 3, text) catch return -1;
    bind(ctx, term_obj, "measure", 1, measure) catch return -1;
    bind(ctx, term_obj, "graphemes", 1, graphemes) catch return -1;
    bind(ctx, term_obj, "cursor", 3, cursor) catch return -1;
    bind(ctx, term_obj, "size", 0, sizeOf) catch return -1;
    bind(ctx, term_obj, "setNeedsTick", 2, setNeedsTick) catch return -1;
    bind(ctx, term_obj, "copy", 1, copyToClipboard) catch return -1;
    bind(ctx, term_obj, "quit", 0, quit) catch return -1;
    bind(ctx, term_obj, "keyMatches", 3, keyMatches) catch return -1;
    ctx.setPropertyStr(term_obj, "clipboardMax", ctx.newInt32(clipboard_max)) catch return -1;
    ctx.setPropertyStr(term_obj, "cwd", ctx.newString(host.cwd)) catch return -1;
    ctx.setPropertyStr(term_obj, "width", ctx.newInt32(host.paint.width)) catch return -1;
    ctx.setPropertyStr(term_obj, "height", ctx.newInt32(host.paint.height)) catch return -1;
    return 0;
}

fn bind(
    ctx: Context,
    obj: Value,
    name: [*:0]const u8,
    length: c_int,
    comptime fn_: fn (Context, Value, []const Value) Value,
) !void {
    try ctx.setPropertyStr(obj, name, ctx.newFunction(name, length, fn_));
}

fn rethrow(ctx: Context) Value {
    if (ctx.hasException()) return ctx.throw(ctx.getException());
    return ctx.throwTypeError("yuke:term");
}

fn beginFrame(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.paint.render == null) return ctx.throwTypeError("term.beginFrame: no host");
    startFrame(host);
    return quickjs.UNDEFINED;
}

fn endFrame(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.paint.render == null) return ctx.throwTypeError("term.endFrame: no host");
    commitFrame(host);
    return quickjs.UNDEFINED;
}

fn sizeOf(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    std.debug.assert(!ctx.isUndefined(host.paint.size_obj));
    return ctx.dupValue(host.paint.size_obj);
}

fn fill(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const render = host.paint.render orelse return ctx.throwTypeError("term.fill: no host");
    if (args.len < 4) return ctx.throwTypeError("term.fill(x, y, w, h, style?)");

    const x = ctx.toInt32(args[0]) catch return rethrow(ctx);
    const y = ctx.toInt32(args[1]) catch return rethrow(ctx);
    const w = ctx.toInt32(args[2]) catch return rethrow(ctx);
    const h = ctx.toInt32(args[3]) catch return rethrow(ctx);
    if (x < 0 or y < 0 or w <= 0 or h <= 0) return quickjs.UNDEFINED;
    if (x > std.math.maxInt(i17) or y > std.math.maxInt(i17)) return quickjs.UNDEFINED;

    const style = parseStyle(ctx, if (args.len > 4) args[4] else null) catch return rethrow(ctx);
    ensureFrame(host);
    render.window().child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = std.math.cast(u16, w) orelse std.math.maxInt(u16),
        .height = std.math.cast(u16, h) orelse std.math.maxInt(u16),
    }).fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
    host.paint.dirty = true;
    return quickjs.UNDEFINED;
}

fn text(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const render = host.paint.render orelse return ctx.throwTypeError("term.text: no host");
    if (args.len < 3) return ctx.throwTypeError("term.text(x, y, s, style?)");

    const x = ctx.toInt32(args[0]) catch return rethrow(ctx);
    const y = ctx.toInt32(args[1]) catch return rethrow(ctx);
    if (x < 0 or y < 0) return quickjs.UNDEFINED;
    if (x > std.math.maxInt(i17) or y > std.math.maxInt(i17)) return quickjs.UNDEFINED;

    const s = ctx.toCStringLen(args[2]) catch return rethrow(ctx);
    defer ctx.freeCString(s.ptr);

    const style = parseStyle(ctx, if (args.len > 3) args[3] else null) catch return rethrow(ctx);
    ensureFrame(host);
    const copy = host.paint.glyphs.allocator().dupe(u8, s) catch return ctx.throwOutOfMemory();
    const win = render.window();
    _ = win.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = win.width -| (std.math.cast(u16, x) orelse 0),
        .height = 1,
    }).printSegment(.{ .text = copy, .style = style }, .{ .wrap = .none });
    host.paint.dirty = true;
    return quickjs.UNDEFINED;
}

fn measure(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len < 1) return ctx.throwTypeError("term.measure(s)");
    const s = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(s.ptr);
    return ctx.newInt32(measureUtf8(s));
}

fn graphemes(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1) return ctx.throwTypeError("term.graphemes(s)");
    const s = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(s.ptr);

    var triples: std.ArrayList(i32) = .empty;
    defer triples.deinit(host.gpa);

    var u16_off: i32 = 0;
    var it = term_pkg.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const bytes = g.bytes(s);
        const n = utf16Len(bytes);
        const w: i32 = @intCast(term_pkg.gwidth.gwidth(bytes, .unicode));
        triples.appendSlice(host.gpa, &.{ u16_off, n, w }) catch return ctx.throwOutOfMemory();
        u16_off += n;
    }
    return int32Array(ctx, triples.items);
}

fn cursor(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const render = host.paint.render orelse return ctx.throwTypeError("term.cursor: no host");
    if (args.len < 3) return ctx.throwTypeError("term.cursor(x, y, visible)");

    const x = ctx.toInt32(args[0]) catch return rethrow(ctx);
    const y = ctx.toInt32(args[1]) catch return rethrow(ctx);
    const vis = ctx.toBool(args[2]) catch return rethrow(ctx);
    if (x < 0 or y < 0) return quickjs.UNDEFINED;

    ensureFrame(host);
    const win = render.window();
    if (vis) {
        const col = std.math.cast(u16, x) orelse return quickjs.UNDEFINED;
        const row = std.math.cast(u16, y) orelse return quickjs.UNDEFINED;
        win.showCursor(col, row);
    } else {
        win.hideCursor();
    }
    host.paint.dirty = true;
    return quickjs.UNDEFINED;
}

/// Put text on the system clipboard through OSC 52. Return the UTF-8 byte count the write sent,
/// or -1 when the text is over `clipboardMax`. OSC 52 has no acknowledgement, so a count reports
/// only that the sequence left this process.
fn copyToClipboard(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const render = host.paint.render orelse return ctx.throwTypeError("term.copy: no host");
    if (args.len < 1 or !ctx.isString(args[0])) return ctx.throwTypeError("term.copy(text): text is a string");
    const payload = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(payload.ptr);
    // `bindRender` sets the render and the writer together, so a render implies a writer.
    std.debug.assert(host.paint.writer != null);
    render.copyToClipboard(host.paint.writer.?, payload) catch |err| switch (err) {
        error.ClipboardTooLarge => return ctx.newInt32(-1),
        else => return ctx.throwInternalError("term.copy: the write failed"),
    };
    return ctx.newInt32(@intCast(payload.len));
}

fn quit(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    host.paint.needs_tick = false;
    host.paint.quit_requested = true;
    return quickjs.UNDEFINED;
}

fn setNeedsTick(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1) return ctx.throwTypeError("term.setNeedsTick(enabled, periodMs?)");
    const enabled = ctx.toBool(args[0]) catch return rethrow(ctx);

    var period = host.paint.tick_period_ms;
    if (args.len >= 2 and !ctx.isUndefined(args[1]) and !ctx.isNull(args[1])) {
        const ms = ctx.toInt32(args[1]) catch return rethrow(ctx);
        period = std.math.clamp(@as(u32, @intCast(@max(ms, 0))), tick_ms_min, tick_ms_max);
    }

    if (host.paint.quit_requested) {
        host.paint.needs_tick = false;
        return quickjs.UNDEFINED;
    }
    const was_armed = host.paint.needs_tick;
    const old_period = host.paint.tick_period_ms;
    host.paint.tick_period_ms = period;
    host.paint.needs_tick = enabled;
    // Wake on a fresh arm or period change. A disable waits for the current timer.
    if (enabled and (!was_armed or period != old_period)) {
        if (host.paint.tick_wake) |wake| wake.set();
    }
    return quickjs.UNDEFINED;
}

fn keyMatches(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len < 2 or !ctx.isObject(args[0]) or !ctx.isString(args[1]))
        return ctx.throwTypeError("term.keyMatches(ev, cp, mods?)");

    const cp = firstRuneValue(ctx, args[1]) catch return rethrow(ctx);
    var mods: Modifiers = .{};
    if (args.len >= 3) {
        const bits = ctx.toInt32(args[2]) catch return rethrow(ctx);
        mods = modsFromBits(bits);
    }

    var text_buf: [128]u8 = undefined;
    const char = runeProp(ctx, args[0], "char") catch return rethrow(ctx);
    const shifted = runeProp(ctx, args[0], "shifted") catch return rethrow(ctx);
    const text_s = textProp(ctx, args[0], &text_buf) catch return rethrow(ctx);
    const ev_mods = modsProp(ctx, args[0]) catch return rethrow(ctx);
    return ctx.newBool(matchKey(char, shifted, text_s, ev_mods, cp, mods));
}

/// Match keys in this order: exact, text without Shift, then shifted codepoint.
fn matchKey(char: u21, shifted: u21, text_s: []const u8, ev_mods: Modifiers, cp: u21, mods: Modifiers) bool {
    if (cp == 0) return false;
    if (char == cp and eqlMods(ev_mods, mods)) return true;
    const rest = eqlMods(dropShift(ev_mods), dropShift(mods));
    if (rest and text_s.len != 0) {
        const want: u21 = if (mods.shift) asciiUpper(cp) else cp;
        if (textIsRune(text_s, want)) return true;
    }
    return rest and shifted == cp;
}

fn startFrame(host: *Host) void {
    const render = host.paint.render orelse return;
    render.window().clear();
    render.window().hideCursor();
    _ = host.paint.glyphs.reset(.retain_capacity);
    host.paint.in_frame = true;
    host.paint.dirty = true;
}

pub fn commitFrame(host: *Host) void {
    const render = host.paint.render orelse return;
    const writer = host.paint.writer orelse return;
    if (!host.paint.dirty) {
        host.paint.in_frame = false;
        return;
    }
    render.render(writer) catch return;
    host.paint.dirty = false;
    host.paint.in_frame = false;
    // A successful frame replaces the fault row, so `clearFault` clears the fault text.
    host.clearFault();
}

fn ensureFrame(host: *Host) void {
    if (!host.paint.in_frame) startFrame(host);
}

fn measureUtf8(s: []const u8) i32 {
    var total: i32 = 0;
    var it = term_pkg.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        total +|= @intCast(term_pkg.gwidth.gwidth(g.bytes(s), .unicode));
    }
    return total;
}

fn utf16Len(s: []const u8) i32 {
    var n: i32 = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        n += if (cp > 0xFFFF) 2 else 1;
    }
    return n;
}

fn int32Array(ctx: Context, items: []const i32) Value {
    const len = ctx.newInt32(@intCast(items.len));
    var args = [_]Value{len};
    const ta = ctx.newTypedArray(&args, .Int32Array);
    ctx.freeValue(len);
    if (ctx.isException(ta)) return ta;
    for (items, 0..) |item, i| {
        ctx.setPropertyUint32(ta, @intCast(i), ctx.newInt32(item)) catch {
            ctx.freeValue(ta);
            return rethrow(ctx);
        };
    }
    return ta;
}

fn parseStyle(ctx: Context, maybe: ?Value) error{Exception}!term_pkg.Style {
    // Omitted fg is the terminal default, so a reset theme reads correctly on a light terminal.
    var style: term_pkg.Style = .{};
    const st = maybe orelse return style;
    if (!ctx.isObject(st)) return style;

    if (try colorProp(ctx, st, "fg")) |c| style.fg = c;
    if (try colorProp(ctx, st, "bg")) |c| style.bg = c;
    style.bold = try boolProp(ctx, st, "bold");
    style.dim = try boolProp(ctx, st, "dim");
    style.italic = try boolProp(ctx, st, "italic");
    style.reverse = try boolProp(ctx, st, "reverse");
    if (try boolProp(ctx, st, "underline")) style.ul_style = .single;
    return style;
}

/// Read a color property. Return null when the property is absent or unusable.
fn colorProp(ctx: Context, obj: Value, name: [*:0]const u8) error{Exception}!?term_pkg.Color {
    const v = ctx.getPropertyStr(obj, name);
    defer ctx.freeValue(v);
    if (ctx.isException(v)) return error.Exception;
    if (ctx.isUndefined(v)) return null;
    return parseColor(ctx, v);
}

fn boolProp(ctx: Context, obj: Value, name: [*:0]const u8) error{Exception}!bool {
    const v = ctx.getPropertyStr(obj, name);
    defer ctx.freeValue(v);
    if (ctx.isException(v)) return error.Exception;
    if (ctx.isUndefined(v) or ctx.isNull(v)) return false;
    return ctx.toBool(v) catch error.Exception;
}

fn parseColor(ctx: Context, v: Value) error{Exception}!?term_pkg.Color {
    if (ctx.isNumber(v)) {
        const n = ctx.toInt32(v) catch return error.Exception;
        if (n < 0 or n > 255) return null;
        return .{ .index = @intCast(n) };
    }
    if (!ctx.isString(v)) return null;
    const s = ctx.toCStringLen(v) catch return error.Exception;
    defer ctx.freeCString(s.ptr);
    return ansiFromName(s);
}

const ansi_names = [_]struct { n: []const u8, i: u8 }{
    .{ .n = "black", .i = 0 },
    .{ .n = "red", .i = 1 },
    .{ .n = "green", .i = 2 },
    .{ .n = "yellow", .i = 3 },
    .{ .n = "blue", .i = 4 },
    .{ .n = "magenta", .i = 5 },
    .{ .n = "cyan", .i = 6 },
    .{ .n = "gray", .i = 7 },
    .{ .n = "grey", .i = 7 },
    .{ .n = "dark_gray", .i = 8 },
    .{ .n = "dark_grey", .i = 8 },
    .{ .n = "light_red", .i = 9 },
    .{ .n = "light_green", .i = 10 },
    .{ .n = "light_yellow", .i = 11 },
    .{ .n = "light_blue", .i = 12 },
    .{ .n = "light_magenta", .i = 13 },
    .{ .n = "light_cyan", .i = 14 },
    .{ .n = "white", .i = 15 },
};

fn ansiFromName(name: []const u8) ?term_pkg.Color {
    if (std.mem.eql(u8, name, "reset")) return .default;
    for (ansi_names) |e| {
        if (std.mem.eql(u8, name, e.n)) return .{ .index = e.i };
    }
    return null;
}

fn modsFromBits(v: i32) Modifiers {
    const bits: u8 = @truncate(@as(u32, @bitCast(v)) & 0x3f);
    return @bitCast(bits);
}

fn dropShift(m: Modifiers) Modifiers {
    var out = m;
    out.shift = false;
    return out;
}

fn eqlMods(a: Modifiers, b: Modifiers) bool {
    return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
}

fn asciiUpper(cp: u21) u21 {
    if (cp >= 'a' and cp <= 'z') return cp - ('a' - 'A');
    return cp;
}

fn textIsRune(text_s: []const u8, cp: u21) bool {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return false;
    return std.mem.eql(u8, text_s, buf[0..n]);
}

fn firstRune(s: []const u8) u21 {
    if (s.len == 0) return 0;
    const seq_len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (seq_len > s.len) return 0;
    return std.unicode.utf8Decode(s[0..seq_len]) catch 0;
}

fn firstRuneValue(ctx: Context, v: Value) error{Exception}!u21 {
    const s = ctx.toCStringLen(v) catch return error.Exception;
    defer ctx.freeCString(s.ptr);
    return firstRune(s);
}

fn runeProp(ctx: Context, v: Value, name: [*:0]const u8) error{Exception}!u21 {
    const prop = ctx.getPropertyStr(v, name);
    defer ctx.freeValue(prop);
    if (ctx.isException(prop)) return error.Exception;
    if (!ctx.isString(prop)) return 0;
    const s = ctx.toCStringLen(prop) catch return error.Exception;
    defer ctx.freeCString(s.ptr);
    return firstRune(s);
}

fn textProp(ctx: Context, v: Value, buf: *[128]u8) error{Exception}![]const u8 {
    const prop = ctx.getPropertyStr(v, "text");
    defer ctx.freeValue(prop);
    if (ctx.isException(prop)) return error.Exception;
    if (!ctx.isString(prop)) return &.{};
    const s = ctx.toCStringLen(prop) catch return error.Exception;
    defer ctx.freeCString(s.ptr);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn modsProp(ctx: Context, v: Value) error{Exception}!Modifiers {
    const prop = ctx.getPropertyStr(v, "mods");
    defer ctx.freeValue(prop);
    if (ctx.isException(prop)) return error.Exception;
    if (ctx.isUndefined(prop)) return .{};
    const bits = ctx.toInt32(prop) catch return error.Exception;
    return modsFromBits(bits);
}

fn evalOk(host: *Host, src: [:0]const u8) !i32 {
    try host.evalModule(src, "term.js");
    return host.evalInt("globalThis.result");
}

test "an extra yuke:term export name fails" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { foo } from 'yuke:term';", "term.js"),
    );
}

test "measure and graphemes use cell width and UTF-16 offsets" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\const s = "a中e\u0301𝄞";
        \\const gs = term.graphemes(s);
        \\let out = "";
        \\let w = 0;
        \\for (let k = 0; k < gs.length; k += 3) {
        \\  out += s.slice(gs[k], gs[k] + gs[k + 1]);
        \\  w += gs[k + 2];
        \\}
        \\globalThis.result = (
        \\  term.measure("") === 0 &&
        \\  term.measure("a") === 1 &&
        \\  term.measure("中") === 2 &&
        \\  "𝄞".length === 2 && term.measure("𝄞") === 1 &&
        \\  gs instanceof Int32Array &&
        \\  out === s &&
        \\  w === term.measure(s)
        \\) ? 1 : 0;
    ));
}

test "setNeedsTick clamps and quit blocks a later arm" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\term.setNeedsTick(true, 10);
        \\term.setNeedsTick(false);
        \\term.quit();
        \\term.setNeedsTick(true, 100);
        \\globalThis.result = 1;
    , "term.js");
    try std.testing.expectEqual(@as(u32, 50), host.paint.tick_period_ms);
    try std.testing.expect(host.paint.quit_requested);
    try std.testing.expect(!host.paint.needs_tick);
}

test "keyMatches follows Odin exact, text, and shifted rules" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\const q = { char: "q", shifted: "Q", text: "q", mods: 0 };
        \\const colon = { char: ";", shifted: ":", text: "", mods: 1 };
        \\globalThis.result = (
        \\  term.keyMatches(q, "q") &&
        \\  !term.keyMatches(q, "x") &&
        \\  !term.keyMatches(q, "q", 2) &&
        \\  term.keyMatches(colon, ":") &&
        \\  term.keyMatches(colon, ":", 1)
        \\) ? 1 : 0;
    ));
}

test "beginFrame without a renderer throws" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\globalThis.term = term;
    , "term.js");
    try std.testing.expectError(error.JavaScriptFault, host.eval("term.beginFrame()", "bad.js"));
    // A missing binding would raise a different TypeError, so name the one `beginFrame` raises.
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "term.beginFrame: no host") != null);
}

test "paint copies graphemes, skips negative coords, and diffs" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    const io = std.testing.io;
    var render = try term_pkg.Render.init(io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &out.writer);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\term.beginFrame();
        \\term.fill(-1, 0, 1, 1);
        \\term.text(-1, 0, "Z");
        \\term.fill(0, 0, 8, 2, { fg: "white" });
        \\term.text(0, 0, "A中", { fg: "white", bold: true });
        \\term.endFrame();
        \\globalThis.result = term.width * 10 + term.height;
    , "term.js");
    try std.testing.expectEqual(@as(i32, 82), try host.evalInt("globalThis.result"));
    const first = out.written();
    try std.testing.expect(std.mem.indexOf(u8, first, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "Z") == null);

    out.clearRetainingCapacity();
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\term.beginFrame();
        \\term.fill(0, 0, 8, 2, { fg: "white" });
        \\term.text(0, 0, "A中", { fg: "white", bold: true });
        \\term.endFrame();
    , "term.js");
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a failed endFrame keeps the frame dirty and retries" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    const io = std.testing.io;
    var render = try term_pkg.Render.init(io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 1, .cols = 1, .x_pixel = 0, .y_pixel = 0 });

    var fail: std.Io.Writer = .failing;
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &fail);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\term.beginFrame();
        \\term.text(0, 0, "A");
        \\term.endFrame();
    , "term.js");
    try std.testing.expect(host.paint.dirty);
    try std.testing.expect(render.vx.refresh);

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    host.bindRender(&render, &out.writer);
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\term.endFrame();
    , "term.js");
    try std.testing.expect(!host.paint.dirty);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A") != null);
}
