//! The native `yuke:term` module: the frame, the cells, the measurements, and the quit that the view tier draws through.

const std = @import("std");
const quickjs = @import("quickjs");
const term_pkg = @import("term");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const wrapping = @import("wrap.zig");
const metrics_enabled = @import("builtin").is_test or @import("metrics").enabled;

const Context = quickjs.Context;
const Value = quickjs.Value;

pub const Counters = struct {
    frames: u64 = 0,
    text_calls: u64 = 0,
    text_bytes: u64 = 0,
    measure_calls: u64 = 0,
    measure_bytes: u64 = 0,
    grapheme_calls: u64 = 0,
    grapheme_bytes: u64 = 0,
    wrap_calls: u64 = 0,
    wrap_bytes: u64 = 0,
    wrap_graphemes: u64 = 0,
    wrap_rows: u64 = 0,
    fill_calls: u64 = 0,
};

/// State shared by the renderer and the `yuke:term` module.
pub const Paint = struct {
    pub const Output = struct {
        render: *term_pkg.Render,
        writer: *std.Io.Writer,
    };

    counters: if (metrics_enabled) Counters else void = if (metrics_enabled) .{} else {},
    output: ?Output = null,
    width: u16 = 80,
    height: u16 = 24,
    dirty: bool = false,
    in_frame: bool = false,
    /// True while the owner drains its queue. The frame then paints once, after the last event.
    defer_frame: bool = false,
    needs_tick: bool = false,
    tick_period_ms: u32 = 450,
    quit_requested: bool = false,
    term_obj: quickjs.Value = quickjs.UNDEFINED,
    /// Own grapheme bytes for the open frame. Reset after the grid clears.
    glyphs: std.heap.ArenaAllocator = undefined,

    /// Apply a terminal size to the renderer and cached JavaScript objects.
    pub fn resize(self: *Paint, ctx: Context, winsize: term_pkg.Winsize) void {
        if (winsize.cols == 0 or winsize.rows == 0) return;
        if (self.width == winsize.cols and self.height == winsize.rows) return;
        // A failed write after the grid swapped keeps the frame dirty, so the next commit flushes.
        var resize_dirty = false;
        if (self.output) |output| {
            const render = output.render;
            const writer = output.writer;
            render.resize(writer, winsize) catch {
                if (render.window().width != winsize.cols or render.window().height != winsize.rows)
                    return;
                resize_dirty = true;
            };
            render.vx.screen.width_method = .unicode;
        }
        self.width = winsize.cols;
        self.height = winsize.rows;
        self.dirty = resize_dirty;
        self.in_frame = false;
        self.syncSizeProps(ctx);
    }

    /// Bind the renderer and its writer. `runIo` and the render tests call it.
    pub fn bindRender(self: *Paint, ctx: Context, render: *term_pkg.Render, writer: *std.Io.Writer) void {
        render.vx.caps.unicode = .unicode;
        render.vx.screen.width_method = .unicode;
        self.output = .{ .render = render, .writer = writer };
        const win = render.window();
        self.width = win.width;
        self.height = win.height;
        self.syncSizeProps(ctx);
    }

    /// Copy the cached size to the retained `term` object.
    pub fn syncSizeProps(self: *Paint, ctx: Context) void {
        if (ctx.isUndefined(self.term_obj)) return;
        ctx.setPropertyStr(self.term_obj, "width", ctx.newInt32(self.width)) catch {};
        ctx.setPropertyStr(self.term_obj, "height", ctx.newInt32(self.height)) catch {};
    }

    pub fn freeRoots(self: *Paint, ctx: Context) void {
        if (!ctx.isUndefined(self.term_obj)) {
            ctx.freeValue(self.term_obj);
            self.term_obj = quickjs.UNDEFINED;
        }
    }
};

/// The largest clipboard payload `term.copy` accepts. JavaScript reads it to report a refusal.
pub const clipboard_max = term_pkg.Render.clipboard_max;

pub const tick_ms_min: u32 = 50;
pub const tick_ms_max: u32 = 2000;

/// Register `yuke:term` and its one `term` object, which the host also keeps as a root for size updates.
pub fn install(host: *Host) void {
    module.installObject(host, "yuke:term", "term", &.{
        .{ .name = "beginFrame", .arity = 0, .call = jsBeginFrame },
        .{ .name = "endFrame", .arity = 0, .call = jsEndFrame },
        .{ .name = "fill", .arity = 4, .call = jsFill },
        .{ .name = "text", .arity = 3, .call = jsText },
        .{ .name = "measure", .arity = 1, .call = jsMeasure },
        .{ .name = "graphemes", .arity = 1, .call = jsGraphemes },
        .{ .name = "wrap", .arity = 2, .call = jsWrap },
        .{ .name = "cursor", .arity = 3, .call = jsCursor },
        .{ .name = "setNeedsTick", .arity = 2, .call = jsSetNeedsTick },
        .{ .name = "copy", .arity = 1, .call = jsCopy },
        .{ .name = "quit", .arity = 0, .call = jsQuit },
    }, addRoots);
}

fn addRoots(host: *Host, ctx: Context, term_obj: Value) void {
    module.set(ctx, term_obj, "clipboardMax", ctx.newInt32(clipboard_max));
    module.set(ctx, term_obj, "cwd", ctx.newString(host.cwd));
    module.set(ctx, term_obj, "width", ctx.newInt32(host.paint.width));
    module.set(ctx, term_obj, "height", ctx.newInt32(host.paint.height));
    host.paint.term_obj = ctx.dupValue(term_obj);
}

fn rethrow(ctx: Context) Value {
    if (ctx.hasException()) return ctx.throw(ctx.getException());
    return ctx.throwTypeError("yuke:term");
}

fn jsBeginFrame(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.paint.output == null) return ctx.throwTypeError("term.beginFrame: no host");
    startFrame(host);
    return quickjs.UNDEFINED;
}

fn jsEndFrame(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.paint.output == null) return ctx.throwTypeError("term.endFrame: no host");
    commitFrame(host);
    return quickjs.UNDEFINED;
}

fn jsFill(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const output = host.paint.output orelse return ctx.throwTypeError("term.fill: no host");
    const render = output.render;
    if (args.len < 4) return ctx.throwTypeError("term.fill(x, y, w, h, style?)");

    const x = ctx.toInt32(args[0]) catch return rethrow(ctx);
    const y = ctx.toInt32(args[1]) catch return rethrow(ctx);
    const w = ctx.toInt32(args[2]) catch return rethrow(ctx);
    const h = ctx.toInt32(args[3]) catch return rethrow(ctx);
    if (x < 0 or y < 0 or w <= 0 or h <= 0) return quickjs.UNDEFINED;
    if (x > std.math.maxInt(i17) or y > std.math.maxInt(i17)) return quickjs.UNDEFINED;

    const style = parseStyle(ctx, if (args.len > 4) args[4] else null) catch return rethrow(ctx);
    if (metrics_enabled) host.paint.counters.fill_calls += 1;
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

fn jsText(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const output = host.paint.output orelse return ctx.throwTypeError("term.text: no host");
    const render = output.render;
    if (args.len < 3) return ctx.throwTypeError("term.text(x, y, s, style?)");

    const x = ctx.toInt32(args[0]) catch return rethrow(ctx);
    const y = ctx.toInt32(args[1]) catch return rethrow(ctx);
    if (x < 0 or y < 0) return quickjs.UNDEFINED;
    if (x > std.math.maxInt(i17) or y > std.math.maxInt(i17)) return quickjs.UNDEFINED;

    const s = ctx.toCStringLen(args[2]) catch return rethrow(ctx);
    defer ctx.freeCString(s.ptr);

    const style = parseStyle(ctx, if (args.len > 3) args[3] else null) catch return rethrow(ctx);
    if (metrics_enabled) {
        host.paint.counters.text_calls += 1;
        host.paint.counters.text_bytes += s.len;
    }
    ensureFrame(host);
    const copy = host.paint.glyphs.allocator().dupe(u8, s) catch unreachable;
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

fn jsMeasure(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len < 1) return ctx.throwTypeError("term.measure(s)");
    const s = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(s.ptr);
    if (metrics_enabled) {
        const host = Host.fromContext(ctx);
        host.paint.counters.measure_calls += 1;
        host.paint.counters.measure_bytes += s.len;
    }
    return ctx.newInt32(measureUtf8(s));
}

fn jsGraphemes(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1) return ctx.throwTypeError("term.graphemes(s)");
    const s = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(s.ptr);
    if (metrics_enabled) {
        host.paint.counters.grapheme_calls += 1;
        host.paint.counters.grapheme_bytes += s.len;
    }

    var triples: std.ArrayList(i32) = .empty;
    defer triples.deinit(host.gpa);

    var u16_off: i32 = 0;
    var it = term_pkg.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const bytes = g.bytes(s);
        const n = utf16Len(bytes);
        const w: i32 = @intCast(term_pkg.gwidth.gwidth(bytes, .unicode));
        triples.appendSlice(host.gpa, &.{ u16_off, n, w }) catch unreachable;
        u16_off += n;
    }
    return int32Array(ctx, triples.items);
}

fn jsWrap(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 2) return ctx.throwTypeError("term.wrap(s, width, head?, tail?)");
    const width = ctx.toInt32(args[1]) catch return rethrow(ctx);
    const head = if (args.len > 2) module.integer(ctx, args[2], 0, std.math.maxInt(i32)) orelse return ctx.throwTypeError("term.wrap: invalid head limit") else 0;
    const tail = if (args.len > 3) module.integer(ctx, args[3], 0, std.math.maxInt(i32)) orelse return ctx.throwTypeError("term.wrap: invalid tail limit") else 0;
    if (head == 0 and tail != 0) return ctx.throwTypeError("term.wrap: a tail needs a positive head");
    const source = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(source.ptr);
    var wrapped = wrapping.wrap(host.gpa, source, width, @intCast(head), @intCast(tail)) catch return ctx.throwOutOfMemory();
    defer wrapped.rows.deinit(host.gpa);
    if (metrics_enabled) {
        host.paint.counters.wrap_calls += 1;
        host.paint.counters.wrap_bytes += source.len;
        host.paint.counters.wrap_graphemes += wrapped.graphemes;
        host.paint.counters.wrap_rows += wrapped.rows.items.len;
    }
    const length = std.math.cast(i32, wrapped.rows.items.len * 3) orelse return ctx.throwRangeError("term.wrap: too many rows");
    const result = ctx.newObject();
    if (ctx.isException(result)) return result;
    const size = ctx.newInt32(length);
    const rows = ctx.newTypedArray(&.{size}, .Int32Array);
    ctx.freeValue(size);
    if (ctx.isException(rows)) {
        ctx.freeValue(result);
        return rows;
    }
    for (wrapped.rows.items, 0..) |row, i| {
        const values = [_]i32{ row.start, row.end, @intFromBool(row.soft) };
        for (values, 0..) |value, field| {
            ctx.setPropertyUint32(rows, @intCast(i * 3 + field), ctx.newInt32(value)) catch {
                ctx.freeValue(rows);
                ctx.freeValue(result);
                return rethrow(ctx);
            };
        }
    }
    ctx.setPropertyStr(result, "rows", rows) catch {
        ctx.freeValue(result);
        return rethrow(ctx);
    };
    ctx.setPropertyStr(result, "omitted", ctx.newBool(wrapped.omitted)) catch {
        ctx.freeValue(result);
        return rethrow(ctx);
    };
    return result;
}

fn jsCursor(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const output = host.paint.output orelse return ctx.throwTypeError("term.cursor: no host");
    const render = output.render;
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

/// Put text on the clipboard through OSC 52 and return the bytes sent, or -1 over `clipboardMax`; OSC 52 has no acknowledgement.
fn jsCopy(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const output = host.paint.output orelse return ctx.throwTypeError("term.copy: no host");
    const render = output.render;
    if (args.len < 1 or !ctx.isString(args[0])) return ctx.throwTypeError("term.copy(text): text is a string");
    const payload = ctx.toCStringLen(args[0]) catch return rethrow(ctx);
    defer ctx.freeCString(payload.ptr);
    render.copyToClipboard(output.writer, payload) catch |err| switch (err) {
        error.ClipboardTooLarge => return ctx.newInt32(-1),
        else => return ctx.throwInternalError("term.copy: the write failed"),
    };
    return ctx.newInt32(@intCast(payload.len));
}

fn jsQuit(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    host.paint.needs_tick = false;
    host.paint.quit_requested = true;
    return quickjs.UNDEFINED;
}

fn jsSetNeedsTick(ctx: Context, _: Value, args: []const Value) Value {
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
        host.wake.set(host.io);
    }
    return quickjs.UNDEFINED;
}

fn startFrame(host: *Host) void {
    const output = host.paint.output orelse return;
    if (metrics_enabled) host.paint.counters.frames += 1;
    const render = output.render;
    render.window().clear();
    render.window().hideCursor();
    _ = host.paint.glyphs.reset(.retain_capacity);
    host.paint.in_frame = true;
    host.paint.dirty = true;
}

pub fn commitFrame(host: *Host) void {
    const output = host.paint.output orelse return;
    const render = output.render;
    const writer = output.writer;
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
    // Printable ASCII has one cell per byte.
    if (isSingleCellAscii(s)) return @intCast(s.len);
    var total: i32 = 0;
    var it = term_pkg.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        total +|= @intCast(term_pkg.gwidth.gwidth(g.bytes(s), .unicode));
    }
    return total;
}

/// Return true when every byte is printable ASCII, which spans `0x20` through `0x7e`.
fn isSingleCellAscii(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isPrint(c)) return false;
    }
    return true;
}

const utf16Len = wrapping.utf16Len;

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

fn evalOk(host: *Host, src: [:0]const u8) !i32 {
    try host.evalModule(src, "term.js");
    return host.evalInt("globalThis.result");
}

test "an extra yuke:term export name fails" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { foo } from 'yuke:term';", "term.js"),
    );
}

test "native wrap preserves UTF-16 rows and bounds preview work" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\const equal = (a, b) => JSON.stringify(Array.from(a)) === JSON.stringify(b);
        \\const cases = [
        \\  ["hello world", 5, [0, 6, 1, 6, 11, 0]],
        \\  ["  keep   spaces", 7, [0, 9, 1, 9, 15, 0]],
        \\  ["a\n\nb", 2, [0, 1, 0, 2, 2, 0, 3, 4, 0]],
        \\  ["世界é", 2, [0, 1, 1, 1, 2, 1, 2, 4, 0]],
        \\  ["👩‍💻x", 2, [0, 5, 1, 5, 6, 0]],
        \\];
        \\let ok = cases.every(([s, w, expected]) => equal(term.wrap(s, w).rows, expected));
        \\const source = "first\n" + "middle\n".repeat(1000) + "last";
        \\const prefix = term.wrap(source, 20, 2);
        \\const ends = term.wrap(source, 20, 1, 1);
        \\ok &&= prefix.omitted && equal(prefix.rows, [0, 5, 0, 6, 12, 0]);
        \\ok &&= ends.omitted && equal(ends.rows, [0, 5, 0, source.length - 4, source.length, 0]);
        \\for (const [head, tail] of [[-1, 0], [0, 1], [1, -1], [Infinity, 0], [NaN, 0], [1.5, 0], [2 ** 32, 0], ["3", 0]]) {
        \\  let rejected = false;
        \\  try { term.wrap(source, 20, head, tail); } catch (error) { rejected = error instanceof TypeError; }
        \\  ok &&= rejected;
        \\}
        \\globalThis.result = ok ? 1 : 0;
    ));
    host.paint.counters = .{};
    _ = try evalOk(host,
        \\import { term } from "yuke:term";
        \\term.wrap("line\n".repeat(10000), 80, 3);
        \\globalThis.result = 1;
    );
    try std.testing.expectEqual(@as(u64, 3), host.paint.counters.wrap_rows);
    try std.testing.expect(host.paint.counters.wrap_graphemes <= 20);
    try std.testing.expectEqual(@as(u64, 50000), host.paint.counters.wrap_bytes);
}

test "measure and graphemes use cell width and UTF-16 offsets" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
    defer host.destroy();

    // Printable ASCII takes the byte-length path, so both ends of the range must measure as one.
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\let ascii = "";
        \\for (let c = 0x20; c <= 0x7e; c++) ascii += String.fromCharCode(c);
        \\globalThis.result = (
        \\  term.measure("") === 0 &&
        \\  term.measure("a") === 1 &&
        \\  term.measure(" ") === 1 &&
        \\  term.measure("~") === 1 &&
        \\  term.measure("hello world") === 11 &&
        \\  term.measure(ascii) === ascii.length &&
        \\  ascii.length === 95
        \\) ? 1 : 0;
    ));

    // A control byte has no cell, so a byte count of these strings would report a width too wide.
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\globalThis.result = (
        \\  term.measure("\u001f") === 0 &&
        \\  term.measure("\u007f") === 0 &&
        \\  term.measure("\t") === 0 &&
        \\  term.measure("\r\n") === 0 &&
        \\  term.measure("a\u007fb") === 2 &&
        \\  term.measure("a\tb") === 2 &&
        \\  term.measure("a\u4e2d") === 3
        \\) ? 1 : 0;
    ));

    // A wide character, an astral character, and a combining mark keep their own widths.
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\globalThis.result = (
        \\  term.measure("\u4e2d") === 2 &&
        \\  "\ud834\udd1e".length === 2 && term.measure("\ud834\udd1e") === 1
        \\) ? 1 : 0;
    ));

    // CRLF is one grapheme, so a byte count would measure it wrong; graphemes report the clusters.
    try std.testing.expectEqual(@as(i32, 1), try evalOk(host,
        \\import { term } from "yuke:term";
        \\const s = "a\u4e2de\u0301\ud834\udd1e";
        \\const gs = term.graphemes(s);
        \\let out = "";
        \\let w = 0;
        \\for (let k = 0; k < gs.length; k += 3) {
        \\  out += s.slice(gs[k], gs[k] + gs[k + 1]);
        \\  w += gs[k + 2];
        \\}
        \\globalThis.result = (
        \\  gs instanceof Int32Array &&
        \\  out === s &&
        \\  w === term.measure(s) &&
        \\  term.graphemes("\r\n").length === 3
        \\) ? 1 : 0;
    ));
}

test "setNeedsTick clamps and quit blocks a later arm" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
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

test "beginFrame without a renderer throws" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
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
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.paint.bindRender(host.ctx, &render, &out.writer);

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
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.paint.bindRender(host.ctx, &render, &fail);

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
    host.paint.bindRender(host.ctx, &render, &out.writer);
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\term.endFrame();
    , "term.js");
    try std.testing.expect(!host.paint.dirty);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A") != null);
}
