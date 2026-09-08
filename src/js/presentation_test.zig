const std = @import("std");
const Host = @import("host.zig").Host;
const Paint = @import("test_paint.zig").Paint;

fn expectResult(host: *Host) !void {
    const value = try host.ctx.eval("globalThis.result", "presentation-result.js", .{});
    defer host.ctx.freeValue(value);
    const text = try host.ctx.toCStringLen(value);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "presentation moves the same composer between welcome and sidebar layouts" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 20, 60);
    defer paint.deinit();
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { ChatView } from "yuke:transcript";
        \\import { Text } from "yuke:ui";
        \\import { root, events } from "yuke:core";
        \\import { row, column, child, fixed, fit, grow } from "yuke:layout";
        \\import { Context, Scope } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const fail = [];
        \\const check = (name, value) => { if (!value) fail.push(name); };
        \\let sessionId = null;
        \\const view = new ChatView({ sessionId: () => sessionId, textOf: () => "history across sidebar" });
        \\const composer = view.composer, transcript = view.transcript, pager = transcript.pager;
        \\composer.onKey({ type: "paste", text: "draft\nline two\nline three\n" });
        \\const draft = composer.text, caret = composer.input.caret, spans = JSON.stringify(composer.spans);
        \\const scope = new Scope("test");
        \\let mounts = 0, layouts = 0, disposed = 0, contextSession;
        \\tui.bindTo(new Context(scope, "test")).presentation((chat, owner) => {
        \\  mounts++;
        \\  owner.effect(() => () => disposed++);
        \\  const logo = new Text({ text: "welcome 世界" });
        \\  const side = new Text({ text: "session details" });
        \\  return state => {
        \\    layouts++; contextSession = state.sessionId;
        \\    if (!state.empty) return row([child(null, grow(), { layout: state.defaultLayout }), child(side, fixed(18))], { gap: 1 });
        \\    const width = Math.min(40, state.bounds.w);
        \\    return column([child(null, grow()), child(logo, fit(), { intrinsic: logo.measure(width) }),
        \\      child("composer", fit(), { intrinsic: { w: width, h: chat.composer.height(width) } }), child(null, grow())], { align: "center", gap: 1 });
        \\  };
        \\});
        \\root.setActive(view); root.flush();
        \\check("center", composer.rect.x === 10 && composer.rect.y > 2 && composer.rect.y < 15);
        \\check("empty-transcript-hidden", transcript.pager.rect() === null);
        \\const beforeLayout = layouts;
        \\root.invalidatePaint(); root.flush();
        \\check("paint-skips-layout", layouts === beforeLayout && mounts === 1);
        \\sessionId = "session-a";
        \\transcript.setOutline([{ id: 1, type: "user" }], null);
        \\root.invalidate(); root.flush();
        \\check("sidebar", composer.rect.w === 41 && composer.rect.y >= 16);
        \\check("context", contextSession === "session-a");
        \\const mouse = (event, col) => ({ type: "mouse", event, button: "left", col, row: 0, mods: 0, count: 1 });
        \\view.onMouse(mouse("press", 2)); view.onMouse(mouse("drag", 45)); view.onMouse(mouse("release", 45));
        \\check("transcript-capture-crosses-sidebar", transcript.selectedText() === "history across sidebar" && !transcript._dragging);
        \\check("identity", composer === view.composer && transcript === view.transcript && pager === transcript.pager && mounts === 1);
        \\check("draft", composer.text === draft && composer.input.caret === caret && JSON.stringify(composer.spans) === spans);
        \\globalThis.finish = () => {
        \\  scope.dispose(); root.flush();
        \\  check("unload", disposed === 1 && view.presentation === null && view.presentationViews.length === 0 && composer.rect.w === 60);
        \\  root.setActive(null);
        \\  globalThis.result = fail.length ? fail.join(",") : "ok";
        \\};
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "presentation-layout.js");
    try expectResult(host);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "welcome") != null);
    for ("session details", 0..) |byte, i| {
        const cell = paint.render.vx.screen.readCell(@intCast(42 + i), 0).?;
        try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
    }
    const finish = try host.ctx.eval("globalThis.finish()", "presentation-finish.js", .{});
    host.ctx.freeValue(finish);
    try expectResult(host);
}

test "presentation replacement and pane removal release resources and pointer capture" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { ChatView } from "yuke:transcript";
        \\import { root } from "yuke:core";
        \\import { row, child, fixed, grow } from "yuke:layout";
        \\import { Context, Scope } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const fail = [], seen = [];
        \\const check = (name, value) => { if (!value) fail.push(name); };
        \\const a = new Scope("a"), b = new Scope("b");
        \\const view = new ChatView();
        \\const bounds = { x: 0, y: 0, w: 60, h: 20 };
        \\let aMount = 0, aDispose = 0, bDispose = 0;
        \\tui.bindTo(new Context(a, "a")).presentation((_chat, owner) => {
        \\  aMount++; owner.effect(() => () => aDispose++);
        \\  const side = { rect: bounds, layout(r) { this.rect = r; }, draw() {},
        \\    onMouse(ev) { seen.push(ev.event); return true; }, onKey() { seen.push("key"); return true; } };
        \\  return state => row([child(null, grow(), { layout: state.defaultLayout }), child(side, fixed(10))]);
        \\});
        \\root.setActive(view); view.layout(bounds);
        \\const mouse = (event, col) => ({ type: "mouse", event, button: "left", col, row: 1, mods: 0, count: 1 });
        \\view.onMouse(mouse("press", 55)); view.onMouse(mouse("drag", 0)); view.onKey({ type: "key", key: "enter" });
        \\check("capture", seen.join(",") === "press,drag,key");
        \\tui.bindTo(new Context(b, "b")).presentation((_chat, owner) => {
        \\  owner.effect(() => () => bDispose++);
        \\  return state => state.defaultLayout;
        \\});
        \\view.layout(bounds);
        \\check("replace", aDispose === 1 && view.presentationCapture === null && view.presentationFocus === null);
        \\view.onMouse(mouse("release", 0));
        \\check("old-capture-stops", seen.join(",") === "press,drag,key");
        \\b.dispose(); view.layout(bounds);
        \\check("restore", bDispose === 1 && aMount === 2);
        \\view.onMouse(mouse("press", 55));
        \\view.layout({ ...bounds, w: 0 });
        \\check("hidden-clears-capture", view.presentationCapture === null && view.presentationFocus === null);
        \\root.setActive(null);
        \\check("pane-close", aDispose === 2 && view.presentation === null && view.presentationViews.length === 0);
        \\a.dispose();
        \\check("dispose-once", aDispose === 2 && bDispose === 1);
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "presentation-owner.js");
    try expectResult(host);
}

test "presentation rejects duplicate mounts and contains factory failures" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { ChatView } from "yuke:transcript";
        \\import { events } from "yuke:core";
        \\import { column, child, fixed } from "yuke:layout";
        \\import { Context, Scope } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const view = new ChatView(), scope = new Scope("bad");
        \\let errors = 0, disposed = 0;
        \\const off = events.on("ext.error", () => errors++);
        \\const surface = tui.bindTo(new Context(scope, "bad"));
        \\const remove = surface.presentation((_chat, owner) => {
        \\  owner.effect(() => () => disposed++);
        \\  return () => column([child("composer", fixed(1)), child("composer", fixed(1))]);
        \\});
        \\view.layout({ x: 0, y: 0, w: 30, h: 10 });
        \\const duplicate = errors === 1 && disposed === 1 && view.presentation === null && view.composer.rect.w === 30;
        \\remove();
        \\surface.presentation((_chat, owner) => { owner.effect(() => () => disposed++); throw new Error("factory failure"); });
        \\view.layout({ x: 0, y: 0, w: 30, h: 10 });
        \\scope.dispose(); off();
        \\globalThis.result = duplicate && errors === 2 && disposed === 2 ? "ok" : [duplicate, errors, disposed].join(",");
    , "presentation-failure.js");
    try expectResult(host);
}

test "presentation cannot retain a view after its scope closes inside a hook" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { ChatView } from "yuke:transcript";
        \\import { Text } from "yuke:ui";
        \\import { row, child, fixed, grow } from "yuke:layout";
        \\import { Context, Scope } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const view = new ChatView(), bounds = { x: 0, y: 0, w: 30, h: 10 };
        \\const mountScope = new Scope("mount");
        \\tui.bindTo(new Context(mountScope, "mount")).presentation((_chat, owner) => {
        \\  owner.dispose(); return state => state.defaultLayout;
        \\});
        \\view.layout(bounds);
        \\const mountClosed = view.presentation === null && view.presentationViews.length === 0;
        \\mountScope.dispose();
        \\const layoutScope = new Scope("layout");
        \\tui.bindTo(new Context(layoutScope, "layout")).presentation(() => state => {
        \\  layoutScope.dispose();
        \\  return row([child(null, grow(), { layout: state.defaultLayout }), child(new Text({ text: "stale" }), fixed(10))]);
        \\});
        \\view.layout(bounds);
        \\globalThis.result = mountClosed && view.presentation === null && view.presentationViews.length === 0 && view.composer.rect.w === 30 ? "ok" : "stale presentation";
    , "presentation-reentrant.js");
    try expectResult(host);
}

test "presentation shares view ownership with panes and windows" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { ChatView } from "yuke:transcript";
        \\import { Text, Window } from "yuke:ui";
        \\import { RootView, events } from "yuke:core";
        \\import { row, child, fixed, grow } from "yuke:layout";
        \\import { Context, Scope } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const view = new ChatView(), scope = new Scope("owners"), otherRoot = new RootView();
        \\const side = new Text({ text: "one owner" }), bounds = { x: 0, y: 0, w: 30, h: 10 };
        \\let errors = 0;
        \\const off = events.on("ext.error", () => errors++);
        \\tui.bindTo(new Context(scope, "owners")).presentation(() => state => row([
        \\  child(null, grow(), { layout: state.defaultLayout }), child(side, fixed(10)),
        \\]));
        \\otherRoot.setActive(side); view.layout(bounds);
        \\const paneRejected = errors === 1 && view.presentation === null;
        \\otherRoot.setActive(null); view.layout(bounds);
        \\let reverseRejected = false, windowRejected = false, composerRejected = false;
        \\try { otherRoot.setActive(side); } catch (error) { reverseRejected = error instanceof TypeError; }
        \\try { new Window({ content: side }); } catch (error) { windowRejected = error instanceof TypeError; }
        \\try { otherRoot.setActive(view.composer); } catch (error) { composerRejected = error instanceof TypeError; }
        \\scope.dispose(); otherRoot.setActive(side);
        \\const released = otherRoot.active === side;
        \\otherRoot.setActive(null); off();
        \\globalThis.result = paneRejected && reverseRejected && windowRejected && composerRejected && released ? "ok" : [paneRejected, reverseRejected, windowRejected, composerRejected, released].join(",");
    , "presentation-shared-owner.js");
    try expectResult(host);
}

test "default presentation shows welcome text only for an empty chat" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 12, 40);
    defer paint.deinit();
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { ChatView } from "yuke:transcript";
        \\import { root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import { chatPlugin } from "yuke:chat";
        \\plugins.use(tuiPlugin); const off = plugins.use(chatPlugin);
        \\const view = new ChatView({ textOf: () => "history" });
        \\root.setActive(view); root.flush();
        \\const welcome = view.presentationViews.some(child => child.text === "new chat");
        \\view.transcript.setOutline([{ id: 1, type: "user" }], null);
        \\root.invalidate(); root.flush();
        \\const history = view.presentationViews.length === 0 && view.transcript.pager.rect() !== null;
        \\root.setActive(null); off();
        \\globalThis.result = welcome && history ? "ok" : [welcome, history].join(",");
    , "presentation-default.js");
    try expectResult(host);
}
