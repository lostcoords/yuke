const std = @import("std");
const Host = @import("host.zig").Host;
const Paint = @import("test_paint.zig").Paint;

fn expectResult(host: *Host) !void {
    const out = try host.ctx.eval("globalThis.result", "text-result.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "text retains independent measurement and clipped visible rows" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 4, 12);
    defer paint.deinit();
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { Text } from "yuke:ui";
        \\import { term } from "yuke:term";
        \\const t = new Text({ text: "αβ gamma delta", group: "UIBody" });
        \\const rect = { x: 1, y: 1, w: 5, h: 2 };
        \\const measured = t.measure(5);
        \\t.layout({ ...rect, w: 6 });
        \\t.layout(rect);
        \\const visible = t._layoutCache;
        \\t.measure(5);
        \\const independent = visible === t._layoutCache;
        \\globalThis.repeat = () => {
        \\  t.setText("αβ gamma delta"); t.measure(5); t.layout(rect);
        \\  term.beginFrame(); t.draw(true); t.draw(false); term.endFrame();
        \\};
        \\globalThis.result = independent && measured.h > 2 && visible.rows.length === 2 && visible.rows.every(row => term.measure(row) <= 5) ? "ok" : "text cache mismatch";
    , "text-widget.js");
    try expectResult(host);
    const before = host.paint.counters;
    const repeated = try host.ctx.eval("globalThis.repeat()", "text-repeat.js", .{});
    host.ctx.freeValue(repeated);
    try std.testing.expectEqual(before.wrap_calls, host.paint.counters.wrap_calls);
    try std.testing.expectEqual(before.measure_calls, host.paint.counters.measure_calls);
    try std.testing.expect(host.paint.counters.text_calls > before.text_calls);
}

test "text updates invalidate once and clip an overwide grapheme to its bounds" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { Text } from "yuke:ui";
        \\import { root } from "yuke:core";
        \\const t = new Text({ text: "same" });
        \\t.layout({ x: 0, y: 0, w: 10, h: 2 });
        \\root._needsDraw = false; root._layoutDirty = false;
        \\t.setText("same");
        \\const same = !root._needsDraw && !root._layoutDirty;
        \\t.setText("世界");
        \\const changed = root._needsDraw && root._layoutDirty;
        \\t.layout({ x: 0, y: 0, w: 1, h: 2 });
        \\const clipped = t._layoutCache.rows.every(row => row === "");
        \\globalThis.result = same && changed && clipped ? "ok" : "text invalidation mismatch";
    , "text-invalidate.js");
    try expectResult(host);
}
