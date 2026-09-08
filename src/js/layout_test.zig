const std = @import("std");
const Host = @import("host.zig").Host;

fn expectResult(host: *Host, want: []const u8) !void {
    const out = try host.ctx.eval("globalThis.result", "layout-result.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

test "layout column fits fixed content and gives the remainder to grow" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { column, child, fixed, fit, grow, solve } from "yuke:layout";
        \\const tree = column([
        \\  child("fixed", fixed(2)),
        \\  child("fit", fit(), { intrinsic: { w: 20, h: 3 } }),
        \\  child("grow", grow()),
        \\], { gap: 1, padding: 1 });
        \\const got = solve(tree, { x: 0, y: 0, w: 20, h: 12 });
        \\globalThis.result = JSON.stringify(got.children.map((x) => [x.value, x.rect]));
    , "layout-column.js");
    try expectResult(host, "[[\"fixed\",{\"x\":1,\"y\":1,\"w\":18,\"h\":2}],[\"fit\",{\"x\":1,\"y\":4,\"w\":18,\"h\":3}],[\"grow\",{\"x\":1,\"y\":8,\"w\":18,\"h\":3}]]");
}

test "layout row splits an odd remainder in source order" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { row, child, grow, solve } from "yuke:layout";
        \\const tree = row([child("a", grow()), child("b", grow()), child("c", grow())], { gap: 1 });
        \\globalThis.result = JSON.stringify(solve(tree, { x: 0, y: 0, w: 10, h: 4 }).children.map((x) => [x.value, x.rect]));
    , "layout-row.js");
    try expectResult(host, "[[\"a\",{\"x\":0,\"y\":0,\"w\":3,\"h\":4}],[\"b\",{\"x\":4,\"y\":0,\"w\":3,\"h\":4}],[\"c\",{\"x\":8,\"y\":0,\"w\":2,\"h\":4}]]");
}

test "layout honors min and max and centers a non-stretch child" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { row, child, fixed, grow, solve } from "yuke:layout";
        \\const tree = row([
        \\  child("fixed", fixed(3), { align: "center", intrinsic: { w: 3, h: 2 } }),
        \\  child("grow", grow(1, { min: 2, max: 4 })),
        \\], { gap: 1 });
        \\globalThis.result = JSON.stringify(solve(tree, { x: 0, y: 0, w: 12, h: 6 }).children.map((x) => [x.value, x.rect]));
        \\const cases = [
        \\  [[[1, 0, 2], [1, 0, 100]], [2, 9]],
        \\  [[[1, 2, 4], [2, 0, 100]], [4, 7]],
        \\  [[[2, 0, 3], [1, 0, 100], [1, 0, 100]], [3, 4, 4]],
        \\  [[[Number.MIN_VALUE, 0, 100], [Number.MAX_VALUE, 0, 100]], [0, 11]],
        \\];
        \\for (const [specs, expected] of cases) {
        \\  const items = specs.map(([weight, min, max], i) => child(i, grow(weight, { min, max })));
        \\  const widths = solve(row(items), { x: 0, y: 0, w: 11, h: 1 }).children.map(item => item.rect.w);
        \\  if (JSON.stringify(widths) !== JSON.stringify(expected)) throw new Error("grow redistribution differs");
        \\}
    , "layout-limits.js");
    try expectResult(host, "[[\"fixed\",{\"x\":0,\"y\":2,\"w\":3,\"h\":2}],[\"grow\",{\"x\":4,\"y\":0,\"w\":4,\"h\":6}]]");
}

test "layout clips an over-constrained child to the available bounds" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { column, child, fixed, solve, clipRect } from "yuke:layout";
        \\const tree = column([child("too-tall", fixed(5))], { padding: 2 });
        \\const clipped = solve(tree, { x: 0, y: 0, w: 5, h: 3 }).children[0].rect;
        \\globalThis.result = JSON.stringify([clipped, clipRect({ x: -2, y: 1, w: 8, h: 4 }, { x: 0, y: 0, w: 4, h: 3 })]);
    , "layout-clip.js");
    try expectResult(host, "[{\"x\":2,\"y\":2,\"w\":1,\"h\":0},{\"x\":0,\"y\":1,\"w\":4,\"h\":2}]");
}

test "layout keeps empty padding and large grow weights bounded" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { column, child, grow, solve } from "yuke:layout";
        \\const tree = column([
        \\  child("a", grow(Number.MAX_VALUE)),
        \\  child("b", grow(Number.MAX_VALUE)),
        \\], { padding: 20 });
        \\const got = solve(tree, { x: 3, y: 4, w: 2, h: 1 });
        \\globalThis.result = got.children.every((item) => item.rect.x >= 3 && item.rect.x <= 5 && item.rect.y >= 4 && item.rect.y <= 5 && item.rect.w >= 0 && item.rect.h >= 0 && Number.isFinite(item.rect.x + item.rect.y + item.rect.w + item.rect.h)) ? "ok" : JSON.stringify(got.children);
    , "layout-bounds.js");
    try expectResult(host, "ok");
}

test "mounted views have one owner and same-owner claims are idempotent" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { claimView, releaseView, root, Node } from "yuke:core";
        \\import { Window } from "yuke:ui";
        \\const view = { layout() {}, draw() {} };
        \\const first = {}, second = {};
        \\claimView(view, first);
        \\claimView(view, first);
        \\let rejected = false;
        \\try { claimView(view, second); } catch (_) { rejected = true; }
        \\releaseView(view, first);
        \\claimView(view, second);
        \\releaseView(view, second);
        \\const leaf = Node.leaf(view);
        \\let duplicate = false;
        \\try { root.setRoot(Node.branch("row", leaf, leaf, 0.5)); } catch (_) { duplicate = true; }
        \\const invalid = new Window({ width: () => NaN });
        \\let dimension = false;
        \\try { invalid.layout({ x: 0, y: 0, w: 10, h: 10 }); } catch (_) { dimension = true; }
        \\globalThis.result = rejected && duplicate && dimension && root.root_node === null ? "ok" : "bad";
    , "view-ownership.js");
    try expectResult(host, "ok");
}
