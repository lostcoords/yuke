const zio = @import("zio");
const host_mod = @import("host.zig");
const std = @import("std");
const term_pkg = @import("term");
const Host = @import("host.zig").Host;
const tools_table = @import("tools.zig");

fn expectJs(host: *Host, want: []const u8) !void {
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

fn expectSeen(host: *Host, want: []const u8) !void {
    const out = try host.ctx.eval("globalThis.seen", "s.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

fn expectJsInt(host: *Host, want: i32) !void {
    try std.testing.expectEqual(want, try host.evalInt("globalThis.result"));
}

const Paint = struct {
    env_map: std.process.Environ.Map,
    render: term_pkg.Render,
    sink: std.Io.Writer.Allocating,
    out: std.Io.Writer.Allocating,

    fn setup(self: *Paint, gpa: std.mem.Allocator, rows: u16, cols: u16) !void {
        self.env_map = try std.testing.environ.createMap(gpa);
        errdefer self.env_map.deinit();
        self.sink = .init(gpa);
        errdefer self.sink.deinit();
        self.out = .init(gpa);
        errdefer self.out.deinit();
        self.render = try term_pkg.Render.init(std.testing.io, gpa, &self.env_map, .{});
        errdefer self.render.deinit(&self.sink.writer);
        try self.render.resize(&self.sink.writer, .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
    }

    fn deinit(self: *Paint) void {
        self.render.deinit(&self.sink.writer);
        self.out.deinit();
        self.sink.deinit();
        self.env_map.deinit();
    }

    fn bind(self: *Paint, host: *Host) void {
        host.paint.bindRender(host.ctx, &self.render, &self.out.writer);
    }
};

test "yuke:core clip and style.resolve" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { clip, style } from "yuke:core";
        \\const before = style.resolve("Normal").fg;
        \\style.palette.fg = "red";
        \\const stale = style.resolve("Normal").fg;
        \\style.invalidate();
        \\globalThis.result = (
        \\  clip("", 3) === "" &&
        \\  clip("abc", 0) === "" &&
        \\  clip("abc", 10) === "abc" &&
        \\  clip("abc", 1) === "a" &&
        \\  clip("abcd", 3) === "ab…" &&
        \\  clip("中文", 3) === "中…" &&
        \\  before === "reset" &&
        \\  stale === "reset" &&
        \\  style.resolve("Normal").fg === "red" &&
        \\  style.resolve("YukeHeader").fg === "red" &&
        \\  style.resolve("YukeHeader").dim === true &&
        \\  style.resolve("YukeBrand").bold === true
        \\) ? 1 : 0;
    , "core.js");
    try expectJsInt(host, 1);
}

test "yuke:core wrapOffsets keeps every byte and caretRowCol places the caret" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { wrapOffsets, caretRowCol } from "yuke:core";
        \\const join = (s, rows) => rows.map((r) => s.slice(r.start, r.end)).join("|");
        \\// A row plus its break covers the whole string, so no byte is lost.
        \\const covers = (s, rows) => {
        \\  let out = "";
        \\  for (let i = 0; i < rows.length; i++) {
        \\    out += s.slice(rows[i].start, rows[i].end);
        \\    if (i + 1 < rows.length && !rows[i].soft) out += "\n";
        \\  }
        \\  return out === s;
        \\};
        \\const indent = "  keep   spaces";
        \\const para = "hello world";
        \\const rows = wrapOffsets(para, 5);
        \\globalThis.result = (
        \\  join(para, rows) === "hello |world" &&
        \\  rows[0].soft === true &&
        \\  covers(para, rows) &&
        \\  covers(indent, wrapOffsets(indent, 7)) &&
        \\  join(indent, wrapOffsets(indent, 7)) === "  keep   |spaces" &&
        \\  join("abcdefghij", wrapOffsets("abcdefghij", 4)) === "abcd|efgh|ij" &&
        \\  join("a\nb", wrapOffsets("a\nb", 9)) === "a|b" &&
        \\  wrapOffsets("a\nb", 9)[0].soft === false &&
        \\  covers("a\nb", wrapOffsets("a\nb", 9)) &&
        \\  join("", wrapOffsets("", 5)) === "" &&
        \\  covers("one\n\ntwo words", wrapOffsets("one\n\ntwo words", 4)) &&
        \\  caretRowCol(para, rows, 0).row === 0 &&
        \\  caretRowCol(para, rows, 3).col === 3 &&
        \\  caretRowCol(para, rows, 6).row === 1 &&
        \\  caretRowCol(para, rows, 6).col === 0 &&
        \\  caretRowCol(para, rows, 11).row === 1 &&
        \\  caretRowCol(para, rows, 11).col === 5
        \\) ? 1 : 0;
    , "wrap.js");
    try expectJsInt(host, 1);
}

test "yuke:core RootView paints and only ctrl+q quits" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 2, 8);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { View, root, text } from "yuke:core";
        \\class Hello extends View {
        \\  get name() { return "hello"; }
        \\  draw() { text(this.rect.x, this.rect.y, "hi", "Normal"); }
        \\}
        \\root.setActive(new Hello());
    , "ui.js");
    const loop = @import("loop.zig");
    try loop.start(host);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "hi") != null);
    // A bare key never quits, so a stray key in a modal layer cannot end the session.
    try loop.step(host, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(!host.paint.quit_requested);
    try host.evalModule(
        \\import { keymap } from "yuke:core";
        \\keymap.add({ "ctrl+q": "quit" });
    , "bind.js");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'q', .mods = .{ .ctrl = true } } });
    try std.testing.expect(host.paint.quit_requested);
}

test "yuke:ext kernel: scope, advice, services, and the plugin lifecycle" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { command, keymap, events, status, style, root, context, parseContext, config, defineConfig, Emitter, View, Node } from "yuke:core";
        \\import { Scope, Context, advice, services, plugins, rootScope } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
        \\
        \\// A scope reverts its effects newest first.
        \\{
        \\  const order = [];
        \\  const s = new Scope("t");
        \\  s.effect(() => { order.push("a-set"); return () => order.push("a"); });
        \\  s.effect(() => { order.push("b-set"); return () => order.push("b"); });
        \\  s.effect(() => { order.push("c-set"); return () => order.push("c"); });
        \\  s.dispose();
        \\  check("lifo", order.join(",") === "a-set,b-set,c-set,c,b,a");
        \\}
        \\
        \\// A disposer cleans up once, by hand or through dispose.
        \\{
        \\  let n = 0;
        \\  const s = new Scope("t2");
        \\  const off = s.effect(() => () => n++);
        \\  off(); off();
        \\  s.dispose();
        \\  check("effect-idempotent", n === 1);
        \\}
        \\
        \\// A throwing teardown reports on the bus and never stops the rest.
        \\{
        \\  const seen = [];
        \\  const off = events.on("ext.error", (e, name) => seen.push(name));
        \\  const s = new Scope("t3");
        \\  s.effect(() => () => { throw new Error("boom"); });
        \\  s.effect(() => () => seen.push("after"));
        \\  s.dispose();
        \\  off();
        \\  check("dispose-isolate", seen.join(",") === "after,t3");
        \\}
        \\
        \\// emit runs every listener and isolates a throwing one.
        \\{
        \\  const em = new Emitter();
        \\  em.onError = () => {};
        \\  let hits = 0;
        \\  em.on("x", () => { hits++; throw new Error("boom"); });
        \\  em.on("x", () => { hits++; });
        \\  em.emit("x");
        \\  check("emit-isolate", hits === 2);
        \\}
        \\
        \\// bail stops at the first listener that claims the event.
        \\{
        \\  const em = new Emitter();
        \\  const seen = [];
        \\  em.on("k", () => { seen.push(1); });
        \\  em.on("k", () => { seen.push(2); return "claimed"; });
        \\  em.on("k", () => { seen.push(3); });
        \\  check("bail", em.bail("k") === "claimed" && seen.join(",") === "1,2");
        \\}
        \\
        \\// Context.on subscribes on the shared bus and goes away with its scope.
        \\{
        \\  const s = new Scope("t5");
        \\  const ctx = new Context(s, "p5");
        \\  let got = 0;
        \\  ctx.on("ui.tick", () => got++);
        \\  events.emit("ui.tick", null);
        \\  s.dispose();
        \\  events.emit("ui.tick", null);
        \\  check("ctx-on-dispose", got === 1);
        \\}
        \\
        \\// command.add returns a disposer that removes exactly what it added.
        \\{
        \\  const off = command.add(null, { "test:cmd6": () => {} });
        \\  const present = !!command.map["test:cmd6"];
        \\  off();
        \\  check("command-dispose", present && !command.map["test:cmd6"]);
        \\}
        \\
        \\// keymap.add removes the bind and clears a prefix nothing uses.
        \\{
        \\  const off = keymap.add({ "ctrl+x g": () => true });
        \\  const hadPrefix = keymap.prefixes["ctrl+x"].length === 1;
        \\  off();
        \\  check("keymap-dispose", hadPrefix && !keymap.map["ctrl+x g"] && !keymap.prefixes["ctrl+x"]);
        \\}
        \\
        \\// advice folds before, around, filterReturn, and after, then restores on removal.
        \\{
        \\  const obj = { hits: [], greet(n) { this.hits.push("orig:" + n); return "hi " + n; } };
        \\  const original = obj.greet;
        \\  const offs = [
        \\    advice.advise(obj, "greet", "before", function (n) { this.hits.push("before:" + n); }, { owner: "o", name: "b" }),
        \\    advice.advise(obj, "greet", "after", function (n) { this.hits.push("after:" + n); }, { owner: "o", name: "a" }),
        \\    advice.advise(obj, "greet", "around", function (orig, n) { return orig(n.toUpperCase()); }, { owner: "o", name: "ar" }),
        \\    advice.advise(obj, "greet", "filterReturn", function (r) { return r + "!"; }, { owner: "o", name: "f" }),
        \\  ];
        \\  const out = obj.greet("bob");
        \\  check("advice-compose", out === "hi BOB!" && obj.hits.join(",") === "before:bob,orig:BOB,after:bob");
        \\  for (const off of offs) off();
        \\  check("advice-restore", obj.greet === original);
        \\}
        \\
        \\// Advice with no `around` still folds the other kinds.
        \\{
        \\  const obj = { log: [], f(n) { this.log.push("orig:" + n); return n; } };
        \\  const off = advice.advise(obj, "f", "filterReturn", (r) => r * 2, { owner: "o", name: "d" });
        \\  check("advice-no-around", obj.f(3) === 6 && obj.log.join(",") === "orig:3");
        \\  off();
        \\}
        \\
        \\// The same owner and name replaces in place rather than stacking.
        \\{
        \\  const obj = { log: [], f() { this.log.push("orig"); } };
        \\  advice.advise(obj, "f", "before", function () { this.log.push("v1"); }, { owner: "o", name: "n" });
        \\  const off2 = advice.advise(obj, "f", "before", function () { this.log.push("v2"); }, { owner: "o", name: "n" });
        \\  const replaced = advice.list(obj, "f").length === 1;
        \\  obj.f();
        \\  off2();
        \\  check("advice-replace", replaced && obj.log.join(",") === "v2,orig" && advice.list(obj, "f").length === 0);
        \\}
        \\
        \\// A service announces its arrival and its withdrawal.
        \\{
        \\  const seen = [];
        \\  const off = events.on("service:svc", (v) => seen.push(v === undefined ? "gone" : v));
        \\  const drop = services.provide("svc", "here");
        \\  const got = services.get("svc");
        \\  drop();
        \\  off();
        \\  check("service", got === "here" && seen.join(",") === "here,gone" && services.get("svc") === undefined);
        \\}
        \\
        \\// A plugin registers on use, reverts on dispose, and comes back on reload.
        \\{
        \\  const p = { name: "demo9", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { act: () => {} }); } };
        \\  plugins.use(p);
        \\  const present = !!command.map["demo9:act"];
        \\  plugins.dispose("demo9");
        \\  const gone = !command.map["demo9:act"];
        \\  plugins.use(p);
        \\  const back = !!command.map["demo9:act"];
        \\  plugins.dispose("demo9");
        \\  check("plugin-lifecycle", present && gone && back);
        \\}
        \\
        \\// A disposed plugin releases its root entry, so reloads do not retain one capture each.
        \\{
        \\  const held = rootScope._disposers.length;
        \\  for (let i = 0; i < 32; i++) {
        \\    plugins.use({ name: "short", apply() {} });
        \\    plugins.dispose("short");
        \\  }
        \\  check("plugin-root-entry-released", rootScope._disposers.length === held);
        \\}
        \\
        \\// A second use of a live name disposes the first, so nothing stacks on reload.
        \\{
        \\  let disposals = 0;
        \\  const p = { name: "dup", apply(ctx) { const t = tui.bindTo(ctx); ctx.effect(() => () => disposals++); } };
        \\  plugins.use(p);
        \\  plugins.use(p);
        \\  const once = disposals === 1;
        \\  plugins.dispose("dup");
        \\  check("plugin-reload-disposes", once && disposals === 2 && plugins.names().indexOf("dup") < 0);
        \\}
        \\
        \\// A throwing apply reverts what it already registered and leaves no live plugin.
        \\{
        \\  const bad = { name: "bad", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { act: () => {} }); throw new Error("nope"); } };
        \\  let threw = false;
        \\  try { plugins.use(bad); } catch (e) { threw = true; }
        \\  check("plugin-partial-revert", threw && !command.map["bad:act"] && !plugins.get("bad"));
        \\}
        \\
        \\// A plugin is `{ name, apply }` and nothing else, so no shape can register under a guessed name.
        \\{
        \\  const rejects = (p) => { try { plugins.use(p); return false; } catch (e) { return e instanceof TypeError; } };
        \\  const fn = (ctx) => { tui.bindTo(ctx).command(null, { act: () => {} }); };
        \\  fn.pluginName = "sneaky";
        \\  check("plugin-rejects-function", rejects(fn));
        \\  // This one survives a misapplied call, so only the shape test can turn it away.
        \\  const quiet = () => {};
        \\  check("plugin-rejects-quiet-function", rejects(quiet) && plugins.names().indexOf("quiet") < 0);
        \\  check("plugin-function-registers-nothing", plugins.names().indexOf("sneaky") < 0 && plugins.names().indexOf("fn") < 0 && !command.map["fn:act"]);
        \\  check("plugin-rejects-nameless", rejects({ apply(ctx) {} }));
        \\  check("plugin-rejects-empty-name", rejects({ name: "", apply(ctx) {} }));
        \\  check("plugin-rejects-no-apply", rejects({ name: "x" }));
        \\}
        \\
        \\// A child scope disposes with its parent, newest first.
        \\{
        \\  const order = [];
        \\  const parent = new Scope("p");
        \\  parent.effect(() => () => order.push("parent"));
        \\  const kid = parent.child("kid");
        \\  kid.effect(() => () => order.push("kid"));
        \\  parent.dispose();
        \\  check("scope-child", order.join(",") === "kid,parent" && !kid.alive);
        \\}
        \\
        \\// A child disposal detaches its parent entry, so repeated unloads do not retain cleanup captures.
        \\{
        \\  const parent = new Scope("detach");
        \\  const kid = parent.child("kid");
        \\  check("child-entry-held", parent._disposers.length === 1);
        \\  kid.dispose();
        \\  check("child-entry-detached", parent._disposers.length === 0);
        \\  const off = parent.effect(() => () => {});
        \\  check("effect-entry-held", parent._disposers.length === 1);
        \\  off();
        \\  check("effect-entry-detached", parent._disposers.length === 0);
        \\  parent.dispose();
        \\}
        \\
        \\// An effect on a disposed scope throws.
        \\{
        \\  const s = new Scope("dead");
        \\  s.dispose();
        \\  let threw = false;
        \\  try { s.effect(() => {}); } catch (e) { threw = true; }
        \\  check("scope-dead-effect", threw);
        \\}
        \\
        \\// filterArgs rewrites the arguments that the original and `after` both see.
        \\{
        \\  const obj = { log: [], f(a, b) { this.log.push("orig:" + a + b); return a + b; } };
        \\  const off = advice.advise(obj, "f", "filterArgs", (as) => [as[0] * 2, as[1] * 2], { owner: "o", name: "fa" });
        \\  const seen = [];
        \\  const off2 = advice.advise(obj, "f", "after", (a, b) => seen.push(a + "," + b), { owner: "o", name: "af" });
        \\  const out = obj.f(1, 2);
        \\  off(); off2();
        \\  check("advice-filter-args", out === 6 && obj.log.join(",") === "orig:24" && seen.join(",") === "2,4");
        \\}
        \\
        \\// An accessor is not a method, so advise refuses it.
        \\{
        \\  const obj = { get g() { return () => 1; } };
        \\  let threw = false;
        \\  const want = "is an accessor";
        \\  try { advice.advise(obj, "g", "before", () => {}); } catch (e) { threw = e instanceof TypeError && e.message.indexOf(want) >= 0; }
        \\  check("advice-accessor", threw);
        \\}
        \\
        \\// A Context forces its own id as the advice owner and keeps a qualified name intact.
        \\{
        \\  const s = new Scope("t7");
        \\  const ctx = new Context(s, "p7");
        \\  const t = tui.bindTo(ctx);
        \\  const obj = { f() { return 1; } };
        \\  ctx.advise(obj, "f", "filterReturn", (r) => r + 1, { name: "inc" });
        \\  const owned = advice.list(obj, "f")[0];
        \\  t.command(null, { bare: () => {}, "other:kept": () => {} });
        \\  t.keymap({ "ctrl+y": "p7:bare" });
        \\  ctx.provide("svc7", 42);
        \\  const ok = owned.owner === "p7" && obj.f() === 2 &&
        \\    !!command.map["p7:bare"] && !!command.map["other:kept"] &&
        \\    !!keymap.map["ctrl+y"] && services.get("svc7") === 42;
        \\  s.dispose();
        \\  const gone = !command.map["p7:bare"] && !command.map["other:kept"] &&
        \\    !keymap.map["ctrl+y"] && services.get("svc7") === undefined &&
        \\    obj.f() === 1 && advice.list(obj, "f").length === 0;
        \\  check("context-surface", ok && gone);
        \\}
        \\
        \\// The status registry orders each side, rejects a bad segment, and disposes with the scope.
        \\const offA = status.add({ side: "left", order: 10, render: () => "a" });
        \\status.add({ side: "left", order: 1, render: () => "b" });
        \\status.add({ side: "right", order: 0, render: () => "r" });
        \\status.add({ side: "left", order: 5, render: () => null });
        \\check("status-order", status.side("left") === "b · a");
        \\check("status-side", status.side("right") === "r");
        \\check("status-bad-side", throws(() => status.add({ side: "up", render: () => "x" })));
        \\check("status-bad-order", throws(() => status.add({ order: Infinity, render: () => "x" })));
        \\check("status-no-render", throws(() => status.add({ side: "left" })));
        \\offA();
        \\check("status-dispose", status.side("left") === "b");
        \\{
        \\  const stop = plugins.use({ name: "seg", apply: (c) => { tui.bindTo(c).status({ side: "right", order: 9, render: () => "p" }); } });
        \\  check("status-plugin", status.side("right") === "r · p");
        \\  stop();
        \\  check("status-unload", status.side("right") === "r");
        \\}
        \\
        \\
        \\// A later registration shadows an earlier one; its dispose uncovers what it hid.
        \\{
        \\  const seen = [];
        \\  const offA = command.add(null, { "test:shadow": () => seen.push("a") });
        \\  const offB = command.add(null, { "test:shadow": () => seen.push("b") });
        \\  command.perform("test:shadow");
        \\  offB();
        \\  command.perform("test:shadow");
        \\  offA();
        \\  const gone = !command.map["test:shadow"] && !command.perform("test:shadow");
        \\  check("command-shadow", seen.join(",") === "b,a" && gone);
        \\}
        \\
        \\// A shadowing entry its gate rejects falls through to the entry below it.
        \\{
        \\  const seen = [];
        \\  let allow = false;
        \\  const offA = command.add(null, { "test:gate": () => seen.push("base") });
        \\  const offB = command.add(() => allow, { "test:gate": () => seen.push("top") });
        \\  const r1 = command.perform("test:gate");
        \\  allow = true;
        \\  const r2 = command.perform("test:gate");
        \\  check("command-fallthrough", r1 && r2 && JSON.stringify(seen) === JSON.stringify(["base", "top"]));
        \\  check("command-available", command.available("test:gate") && !command.available("test:absent"));
        \\  allow = false;
        \\  offA();
        \\  check("command-unavailable", !command.available("test:gate"));
        \\  offB();
        \\}
        \\
        \\// style.add seeds only an absent name, invalidates a cached miss, and reverts on dispose.
        \\{
        \\  const missed = style.resolve("TestSeed").bold === undefined;
        \\  const off = style.add({ TestSeed: { fg: "fg", bold: true }, Normal: { fg: "danger" } });
        \\  const seeded = style.resolve("TestSeed").bold === true;
        \\  const kept = style.groups.Normal.fg === "fg";
        \\  off();
        \\  const reverted = !("TestSeed" in style.groups) && style.resolve("TestSeed").bold === undefined;
        \\  check("style-add", missed && seeded && kept && reverted && style.groups.Normal.fg === "fg");
        \\}
        \\
        \\// A plugin's highlight groups unload with the plugin.
        \\{
        \\  const stop = plugins.use({ name: "theme", apply: (c) => { tui.bindTo(c).style({ PluginGroup: { fg: "fg", bold: true } }); } });
        \\  const on = style.resolve("PluginGroup").bold === true;
        \\  stop();
        \\  check("style-plugin", on && !("PluginGroup" in style.groups) && style.resolve("PluginGroup").bold === undefined);
        \\}
        \\
        \\// A disposer runs once; a second call leaves a later registration of the same name alone.
        \\{
        \\  const offA = command.add(null, { "test:twice": () => {} });
        \\  offA();
        \\  const offB = command.add(null, { "test:twice": () => {} });
        \\  offA();
        \\  check("command-dispose-twice", command.map["test:twice"].length === 1);
        \\  offB();
        \\}
        \\
        \\// Every gate shape resolves: a bare boolean, [true], [true, x], and [false].
        \\{
        \\  const got = [];
        \\  const off = [
        \\    command.add(() => true, { "test:g1": (...a) => got.push("g1:" + a.length) }),
        \\    command.add(() => [true], { "test:g2": (...a) => got.push("g2:" + a.length) }),
        \\    command.add(() => [true, "x"], { "test:g3": (...a) => got.push("g3:" + a[0]) }),
        \\    command.add(() => [false], { "test:g4": () => got.push("g4") }),
        \\  ];
        \\  command.perform("test:g1", 1);
        \\  command.perform("test:g2", 1);
        \\  command.perform("test:g3", 1);
        \\  const ran4 = command.perform("test:g4", 1);
        \\  check("command-gate-shapes", got.join(",") === "g1:1,g2:1,g3:x" && !ran4);
        \\  for (const f of off) f();
        \\}
        \\
        \\// A throwing gate lists as available, and the throw still escapes perform.
        \\{
        \\  const off = command.add(() => { throw new Error("gate"); }, { "test:boom": () => {} });
        \\  const listed = command.available("test:boom");
        \\  const threw = throws(() => command.perform("test:boom"));
        \\  check("command-gate-throw", listed && threw);
        \\  off();
        \\}
        \\
        \\
        \\// A second provider hides the first; its withdrawal reveals the one below.
        \\{
        \\  const seen = [];
        \\  const offEvt = events.on("service:stack", (v) => seen.push(v === undefined ? "none" : v));
        \\  const offA = services.provide("stack", "a");
        \\  const offB = services.provide("stack", "b");
        \\  const hid = services.get("stack") === "b";
        \\  offB();
        \\  const revealed = services.get("stack") === "a";
        \\  offA();
        \\  check("service-stack", hid && revealed && services.get("stack") === undefined);
        \\  check("service-events", seen.join(",") === "a,b,a,none");
        \\  offEvt();
        \\}
        \\
        \\// Two plugins want one group name: the first owns it and an unload cannot strip the second.
        \\{
        \\  const first = { fg: "fg", bold: true };
        \\  const stopA = plugins.use({ name: "thA", apply: (c) => { tui.bindTo(c).style({ Shared: first }); } });
        \\  const stopB = plugins.use({ name: "thB", apply: (c) => { tui.bindTo(c).style({ Shared: { fg: "danger" } }); } });
        \\  stopA();
        \\  check("style-collision", style.groups.Shared === first && style.resolve("Shared").bold === true);
        \\  stopB();
        \\  check("style-collision-clean", !("Shared" in style.groups));
        \\}
        \\
        \\// An inherited property name is not an existing group.
        \\{
        \\  const off = style.add({ toString: { fg: "danger", bold: true } });
        \\  const seeded = style.resolve("toString").bold === true;
        \\  off();
        \\  check("style-own-property", seeded && !("toString" in style.groups) && style.groups.Normal.fg === "fg");
        \\}
        \\
        \\// The core bus declares a core name, and leaves an `owner:event` name to its owner.
        \\{
        \\  check("bus-typo", throws(() => events.emit("ui.tik", null)));
        \\  check("bus-typo-on", throws(() => events.on("sesion.changed", () => {})));
        \\  check("bus-plugin-free", !throws(() => events.emit("myplugin:thing", 1)));
        \\  check("bus-plugin-on-free", !throws(() => events.on("myplugin:thing", () => {})));
        \\  check("bus-service-free", !throws(() => events.emit("service:anything", 1)));
        \\  // A namespace needs both halves, so neither one alone opens the bus.
        \\  check("bus-no-owner", throws(() => events.emit(":thing", 1)));
        \\  check("bus-no-event", throws(() => events.emit("myplugin:", 1)));
        \\}
        \\
        \\// A later binding wins, and a binding that declines falls through to the one below.
        \\{
        \\  const ran = [];
        \\  const kev = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const offA = keymap.add({ "ctrl+alt+t": () => { ran.push("a"); return true; } });
        \\  const offB = keymap.add({ "ctrl+alt+t": () => { ran.push("b"); return false; } });
        \\  keymap.onKey(kev({ char: "t", mods: 6 }));
        \\  offB();
        \\  offB();
        \\  keymap.onKey(kev({ char: "t", mods: 6 }));
        \\  check("keymap-newest-first", ran.join(",") === "b,a,a");
        \\  offA();
        \\  check("keymap-clean", !keymap.map["ctrl+alt+t"]);
        \\}
        \\
        \\// Two providers of one value stay apart, so a disposer withdraws its own registration.
        \\{
        \\  const same = { v: 1 };
        \\  const offA = services.provide("dup", same);
        \\  const offB = services.provide("dup", same);
        \\  offB();
        \\  const still = services.get("dup") === same;
        \\  offB();
        \\  const held = services.get("dup") === same;
        \\  offA();
        \\  check("service-identity", still && held && services.get("dup") === undefined);
        \\}
        \\
        \\// A disposer runs once, so a repeat call cannot strip a live holder.
        \\{
        \\  const offA = style.add({ Held: { fg: "fg", bold: true } });
        \\  const offB = style.add({ Held: { fg: "danger" } });
        \\  offA();
        \\  offA();
        \\  check("style-dispose-once", style.resolve("Held").bold === true);
        \\  offB();
        \\  check("style-dispose-last", !("Held" in style.groups));
        \\}
        \\
        \\// An inherited object name is not a declared event, and a namespace needs a real suffix.
        \\{
        \\  check("bus-inherited", throws(() => events.emit("toString", 1)));
        \\  check("bus-inherited-on", throws(() => events.on("constructor", () => {})));
        \\  check("bus-namespace-empty", throws(() => events.emit("service:", 1)));
        \\}
        \\
        \\// Every entry point validates, and every declared name is accepted.
        \\{
        \\  check("bus-once-typo", throws(() => events.once("ui.tik", () => {})));
        \\  check("bus-bail-typo", throws(() => events.bail("ui.tik")));
        \\  const core = ["ui.start", "ui.closed", "ui.resize", "ui.tick", "key.press", "mouse.input",
        \\    "paste.input", "focus.changed", "clipboard.copied", "session.changed", "index.changed",
        \\    "ext.error"];
        \\  const bad = core.filter((n) => throws(() => events.on(n, () => {})()));
        \\  check("bus-core-declared:" + bad.join("|"), bad.length === 0);
        \\}
        \\
        \\// A host event reaches the core name it maps to, and one throwing listener spares the rest.
        \\{
        \\  const seen = [];
        \\  const offs = [
        \\    events.on("key.press", () => { throw new Error("listener"); }),
        \\    events.on("key.press", () => seen.push("key")),
        \\    events.on("mouse.input", () => seen.push("mouse")),
        \\    events.on("ui.tick", () => seen.push("tick")),
        \\    events.on("focus.changed", () => seen.push("focus")),
        \\    events.on("paste.input", () => seen.push("paste")),
        \\    events.on("ui.resize", () => seen.push("resize")),
        \\    events.on("ui.start", () => seen.push("start")),
        \\  ];
        \\  root.onEvent({ type: "start" });
        \\  root.onEvent({ type: "resize", w: 80, h: 24 });
        \\  root.onEvent({ type: "key", code: "char", char: "x", text: "", event: "press", mods: 0 });
        \\  root.onEvent({ type: "mouse", col: 1, row: 1, button: "left", event: "press", mods: 0, count: 1 });
        \\  root.onEvent({ type: "paste", text: "p" });
        \\  root.onEvent({ type: "focus", focused: true });
        \\  root.onEvent({ type: "tick" });
        \\  check("root-event-names", JSON.stringify(seen) === JSON.stringify(["start", "resize", "key", "mouse", "paste", "focus", "tick"]));
        \\  for (const f of offs) f();
        \\}
        \\
        \\// A provider disposed below the top leaves the live provider in place.
        \\{
        \\  const offA = services.provide("rev", "a");
        \\  const offB = services.provide("rev", "b");
        \\  offA();
        \\  const live = services.get("rev") === "b";
        \\  offB();
        \\  check("service-reverse", live && services.get("rev") === undefined);
        \\}
        \\
        \\// A modified binding folds shift away, so the stroke an event makes is the stroke that matches.
        \\{
        \\  let ran = 0;
        \\  const kev2 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const off = keymap.add({ "ctrl+shift+g": () => { ran++; return true; } });
        \\  keymap.onKey(kev2({ char: "g", shifted: "G", mods: 5 }));
        \\  check("stroke-ctrl-shift", ran === 1);
        \\  off();
        \\}
        \\
        \\// A view contributes its atoms, and the stack orders them from the root outward.
        \\{
        \\  class Pane extends View { get name() { return "pane"; } draw() {} }
        \\  class Split extends View { contexts() { return ["chat", "composer"]; } draw() {} }
        \\  const pane = new Pane();
        \\  root.setRoot(new Node(pane));
        \\  root.focusView(pane);
        \\  check("ctx-stack-name", JSON.stringify(context.stack()) === JSON.stringify(["root", "pane"]));
        \\  const split = new Split();
        \\  root.setRoot(new Node(split));
        \\  root.focusView(split);
        \\  check("ctx-stack-atoms", JSON.stringify(context.stack()) === JSON.stringify(["root", "chat", "composer"]));
        \\
        \\  // A deeper atom wins, and an unscoped binding sits below every scoped one.
        \\  const ran = [];
        \\  const kev3 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const offs = [
        \\    keymap.add({ F1: () => { ran.push("bare"); return true; } }),
        \\    keymap.add({ F1: () => { ran.push("chat"); return true; } }, "chat"),
        \\    keymap.add({ F1: () => { ran.push("composer"); return true; } }, "composer"),
        \\  ];
        \\  keymap.onKey(kev3({ code: "f1" }));
        \\  check("ctx-depth-wins", ran.join(",") === "composer");
        \\  const d = keymap.describe("f1");
        \\  check("ctx-describe", d.winner.context === "composer" && d.shadowed.length === 2 &&
        \\    d.shadowed[0].context === "chat" && d.shadowed[1].context === "");
        \\  offs[2]();
        \\  keymap.onKey(kev3({ code: "f1" }));
        \\  check("ctx-uncover", ran.join(",") === "composer,chat");
        \\  for (const f of offs) f();
        \\  root.setRoot(null);
        \\}
        \\
        \\// A flag matches by value, and a function flag resolves at match time.
        \\{
        \\  let mode = "insert";
        \\  const off = context.add({ vim: () => mode, fixed: "on" });
        \\  const ran = [];
        \\  const kev4 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const offKey = keymap.add({ F2: () => { ran.push(mode); return true; } }, "vim == normal && fixed == on");
        \\  keymap.onKey(kev4({ code: "f2" }));
        \\  check("ctx-flag-absent", ran.length === 0);
        \\  mode = "normal";
        \\  keymap.onKey(kev4({ code: "f2" }));
        \\  check("ctx-flag-live", ran.join(",") === "normal");
        \\  offKey();
        \\  off();
        \\  check("ctx-flag-disposed", context.flag("vim") === undefined && context.flag("fixed") === undefined);
        \\}
        \\
        \\// The expression grammar covers negation, alternation, inequality, and grouping.
        \\{
        \\  const off = context.add({ m: "a" });
        \\  root.setRoot(null);
        \\  const truthy = (src) => { const off = keymap.add({ f9: () => true }, src);
        \\    const n = keymap.candidates("f9").length; off(); return n === 1; };
        \\  check("ctx-parse-root", truthy("root") && !truthy("chat"));
        \\  check("ctx-parse-not", truthy("!chat") && !truthy("!root"));
        \\  check("ctx-parse-or", truthy("chat || root") && !truthy("chat || nope"));
        \\  check("ctx-parse-eq", truthy("m == a") && truthy("m != b") && !truthy("m == b"));
        \\  check("ctx-parse-group", truthy("(chat || root) && m == a") && !truthy("(chat || root) && m == b") &&
        \\    truthy("root || chat && m == b"));
        \\  check("ctx-parse-bad", throws(() => parseContext("chat &&")) && throws(() => parseContext("(chat")) &&
        \\    throws(() => parseContext("chat ||")) && throws(() => parseContext("m !=")) &&
        \\    throws(() => parseContext("!")) && throws(() => parseContext("chat)")));
        \\  off();
        \\}
        \\
        \\// A chord waits, then runs the prefix alone. An operator waits without a bound.
        \\{
        \\  const ran = [];
        \\  const kev5 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const offs = [
        \\    keymap.add({ "f5 x": () => { ran.push("chord"); return true; } }),
        \\    keymap.add({ f5: () => { ran.push("prefix"); return true; } }),
        \\  ];
        \\  keymap.onKey(kev5({ code: "f5" }));
        \\  check("pend-armed", keymap.pending.kind === "chord" && keymap.pendingLabel() === "f5");
        \\  check("pend-ticks", keymap.needsTick().periodMs === 1000);
        \\  // The rest of the chord arrives before the wait ends.
        \\  keymap.onKey(kev5({ char: "x" }));
        \\  check("pend-chord-first", ran.join(",") === "chord" && keymap.pending === null);
        \\
        \\  // Nothing follows, so the wait ends and the prefix runs on its own.
        \\  keymap.onKey(kev5({ code: "f5" }));
        \\  keymap.pending.at -= 2000;
        \\  keymap.tick();
        \\  check("pend-timeout", ran.join(",") === "chord,prefix" && keymap.pending === null);
        \\  for (const f of offs) f();
        \\}
        \\
        \\// An operator never times out, and the status bar reports it.
        \\{
        \\  const ran = [];
        \\  const kevOp = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const off = keymap.add({ "f8 x": () => { ran.push("op"); return true; } }, undefined, { pending: "operator" });
        \\  keymap.onKey(kevOp({ code: "f8" }));
        \\  check("pend-operator", keymap.pending.kind === "operator" && keymap.pendingLabel() === "f8");
        \\  check("pend-operator-no-tick", keymap.needsTick() === null);
        \\  keymap.pending.at -= 60000;
        \\  keymap.tick();
        \\  check("pend-operator-holds", keymap.pending !== null && keymap.pendingLabel() === "f8");
        \\  keymap.onKey(kevOp({ char: "x" }));
        \\  check("pend-operator-runs", ran.join(",") === "op" && keymap.pending === null);
        \\  off();
        \\}
        \\
        \\// The chord wait is configurable and validated.
        \\{
        \\  defineConfig({ keymap: { chordMs: 250 } });
        \\  check("cfg-chord", config.keymap.chordMs === 250);
        \\  check("cfg-chord-bad", throws(() => defineConfig({ keymap: { chordMs: 0 } })) && config.keymap.chordMs === 250);
        \\  defineConfig({ keymap: { chordMs: 1000 } });
        \\}
        \\
        \\// A chord whose context does not match must not swallow the prefix or the key after it.
        \\{
        \\  const seen = [];
        \\  // The view declines, so the key reaches the keymap and the arming path runs.
        \\  class Bare extends View { get name() { return "bare"; } draw() {} onKey(ev) { seen.push(ev.code || ev.char); return false; } }
        \\  const pane = new Bare();
        \\  root.setRoot(new Node(pane));
        \\  root.focusView(pane);
        \\  const off = keymap.add({ "f6 x": () => true }, "chat");
        \\  check("prefix-context-off", keymap._armKind("f6") === null);
        \\  root.onEvent({ type: "key", code: "f6", char: "", event: "press", text: "", mods: 0 });
        \\  check("prefix-falls-through", seen.join(",") === "f6" && keymap.pending === null);
        \\  off();
        \\  const on = keymap.add({ "f6 x": () => true }, "bare");
        \\  check("prefix-context-on", keymap._armKind("f6") === "chord");
        \\  on();
        \\  root.setRoot(null);
        \\}
        \\
        \\// The parser rejects a source it cannot read whole, so a typo never matches something else.
        \\{
        \\  check("parse-drop-punct", throws(() => parseContext("chat?")));
        \\  check("parse-drop-at", throws(() => parseContext("chat && @leaf")));
        \\  check("parse-drop-unicode", throws(() => parseContext("a == café")));
        \\}
        \\
        \\// A view atom must be a usable name, and a throwing hook must not stop a key.
        \\{
        \\  class Junk extends View { contexts() { return ["root", "", "dup", "dup", null, "ok"]; } draw() {} }
        \\  const junk = new Junk();
        \\  root.setRoot(new Node(junk));
        \\  root.focusView(junk);
        \\  check("atoms-sanitized", JSON.stringify(context.stack()) === JSON.stringify(["root", "dup", "ok"]));
        \\  // A throwing hook falls back to the view name, so a broken plugin keeps the view reachable.
        \\  class Boom extends View { get name() { return "boom"; } contexts() { throw new Error("no"); } draw() {} }
        \\  const boom = new Boom();
        \\  root.setRoot(new Node(boom));
        \\  root.focusView(boom);
        \\  check("atoms-throw-safe", JSON.stringify(context.stack()) === JSON.stringify(["root", "boom"]));
        \\  root.setRoot(null);
        \\}
        \\
        \\// A flag-only context has depth 0, so registration order decides against an unscoped binding.
        \\{
        \\  const offFlag = context.add({ m: "a" });
        \\  const kev6 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const first = [];
        \\  const a1 = keymap.add({ f7: () => { first.push("flag"); return true; } }, "m == a");
        \\  const a2 = keymap.add({ f7: () => { first.push("bare"); return true; } });
        \\  keymap.onKey(kev6({ code: "f7" }));
        \\  a1(); a2();
        \\  const second = [];
        \\  const b1 = keymap.add({ f7: () => { second.push("bare"); return true; } });
        \\  const b2 = keymap.add({ f7: () => { second.push("flag"); return true; } }, "m == a");
        \\  keymap.onKey(kev6({ code: "f7" }));
        \\  b1(); b2();
        \\  check("ctx-depth-tie", first.join(",") === "bare" && second.join(",") === "flag");
        \\  offFlag();
        \\}
        \\
        \\// An overlay deepens the stack, so a binding on the overlay outranks one on the pane below.
        \\{
        \\  class Pane2 extends View { get name() { return "pane2"; } draw() {} }
        \\  const pane = new Pane2();
        \\  root.setRoot(new Node(pane));
        \\  root.focusView(pane);
        \\  const ran = [];
        \\  const kev7 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const offs = [
        \\    keymap.add({ f8: () => { ran.push("pane"); return true; } }, "pane2"),
        \\    keymap.add({ f8: () => { ran.push("over"); return true; } }, "overlay"),
        \\  ];
        \\  keymap.onKey(kev7({ code: "f8" }));
        \\  const layer = { rect: { x: 0, y: 0, w: 1, h: 1 }, draw() {} };
        \\  root.pushOverlay(layer);
        \\  keymap.onKey(kev7({ code: "f8" }));
        \\  root.popOverlay(layer);
        \\  check("ctx-overlay", ran.join(",") === "pane,over");
        \\  for (const f of offs) f();
        \\  root.setRoot(null);
        \\}
        \\
        \\// The keymap runs as a tick service, so a real tick event ends the chord wait.
        \\{
        \\  const ran = [];
        \\  const kev8 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\  const offs = [
        \\    keymap.add({ "f10 x": () => { ran.push("chord"); return true; } }),
        \\    keymap.add({ f10: () => { ran.push("prefix"); return true; } }),
        \\  ];
        \\  keymap.onKey(kev8({ code: "f10" }));
        \\  keymap.pending.at -= 2000;
        \\  root.onEvent({ type: "tick" });
        \\  check("keymap-tick-service", ran.join(",") === "prefix" && keymap.pending === null);
        \\  for (const f of offs) f();
        \\}
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "ext.js");
    try expectJs(host, "ok");
}

test "yuke:core config validates and TextInput inserts committed text" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { config, defineConfig, TextInput, strokeOf, keymap, command } from "yuke:core";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
        \\
        \\// defineConfig merges values and rejects invalid fields.
        \\defineConfig({ mouse: { scrollLines: 7, copyOnSelect: false } });
        \\check("cfg-merge", config.mouse.scrollLines === 7 && config.mouse.copyOnSelect === false);
        \\check("cfg-unknown-key", throws(() => defineConfig({ nope: 1 })));
        \\check("cfg-prototype-key", throws(() => defineConfig({ mouse: { toString: undefined } })));
        \\check("cfg-out-of-range", throws(() => defineConfig({ mouse: { scrollLines: 0 } })));
        \\// A bad patch changes no config value.
        \\const before = config.mouse.scrollLines;
        \\throws(() => defineConfig({ mouse: { scrollLines: 4, copyOnSelect: "no" } }));
        \\check("cfg-atomic", config.mouse.scrollLines === before);
        \\throws(() => defineConfig({ mouse: { scrollLines: 9 }, keymap: { chordMs: 0 } }));
        \\check("cfg-whole-atomic", config.mouse.scrollLines === before);
        \\
        \\// strokeOf separates G from g under both keyboard protocols.
        \\const kev = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
        \\const mk = (o) => strokeOf(kev(o));
        \\check("stroke-legacy-shift", mk({ char: "G", mods: 1 }) === "G");
        \\check("stroke-kitty-shift", mk({ char: "g", shifted: "G", mods: 1 }) === "G");
        \\check("stroke-plain", mk({ char: "g" }) === "g");
        \\check("stroke-kitty-colon", mk({ char: ";", shifted: ":", mods: 1 }) === ":");
        \\// A legacy terminal reports the shifted symbol as the char and sends no shifted form.
        \\check("stroke-legacy-colon", mk({ char: ":", mods: 1 }) === ":");
        \\check("stroke-chord", mk({ char: "d", mods: 4 }) === "ctrl+d");
        \\check("stroke-named", mk({ code: "tab" }) === "tab");
        \\
        \\
        \\// A written binding folds the way an event folds, so the keymap can bind an uppercase key.
        \\{
        \\  const ran = [];
        \\  const off = keymap.add({ G: () => { ran.push("G"); return true; }, g: () => { ran.push("g"); return true; } });
        \\  keymap.onKey(kev({ char: "G", mods: 1 }));
        \\  keymap.onKey(kev({ char: "g" }));
        \\  check("keymap-case", ran.join(",") === "G,g");
        \\  off();
        \\}
        \\
        \\// `shift+g` names the same stroke as `G`, and another modifier folds the case away.
        \\{
        \\  const ran = [];
        \\  const off = keymap.add({ "shift+g": () => { ran.push("shift"); return true; }, "ctrl+G": () => { ran.push("ctrl"); return true; } });
        \\  keymap.onKey(kev({ char: "g", shifted: "G", mods: 1 }));
        \\  keymap.onKey(kev({ char: "g", mods: 4 }));
        \\  check("keymap-shift-alias", ran.join(",") === "shift,ctrl");
        \\  off();
        \\}
        \\// TextInput uses committed text before the folded key.
        \\const key = (o) => Object.assign({ type: "key", code: "char", event: "press", char: "", text: "", mods: 0 }, o);
        \\const insert = (evs) => { const ti = new TextInput(); for (const e of evs) ti.onKey(e); return ti.text; };
        \\check("upper", insert([key({ char: "a", text: "A", mods: 1 }), key({ char: "b", text: "B", mods: 1 })]) === "AB");
        \\check("shifted-symbol", insert([key({ char: "1", text: "!", mods: 1 })]) === "!");
        \\check("ime-cjk", insert([key({ char: "あ", text: "あ", mods: 0 })]) === "あ");
        \\check("ime-zwj", insert([key({ char: "👨", text: "👨‍👩‍👧", mods: 0 })]) === "👨‍👩‍👧");
        \\check("fallback-char", insert([key({ char: "x", text: "", mods: 1 })]) === "x");
        \\check("altgr-text", insert([key({ char: "q", text: "@", mods: 6 })]) === "@");
        \\// A command has no committed text.
        \\check("ctrl-no-insert", insert([key({ char: "z", text: "", mods: 4 })]) === "");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "cfg.js");
    try expectJs(host, "ok");
}

test "yuke:ui mouse config, wheel scroll, and pane routing under the pointer" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 10, 21);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { config, defineConfig, root, Node, View, isWheel } from "yuke:core";
        \\import { List } from "yuke:ui";
        \\import { Pager } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
        \\
        \\check("mouse-default-lines", config.mouse.scrollLines === 3);
        \\defineConfig({ mouse: { scrollLines: 5 } });
        \\check("mouse-merge", config.mouse.scrollLines === 5);
        \\check("mouse-unknown-key", throws(() => defineConfig({ mouse: { nope: 1 } })));
        \\check("mouse-bad-lines", throws(() => defineConfig({ mouse: { scrollLines: 0 } })));
        \\check("is-wheel", isWheel("wheel_up") && !isWheel("left"));
        \\
        \\const mouse = (o) => Object.assign({ type: "mouse", col: 0, row: 0, button: "left", event: "press", mods: 0 }, o);
        \\const p = new Pager();
        \\p.setRows(Array.from({ length: 100 }, (_, i) => ({ text: "row " + i })));
        \\term.beginFrame();
        \\p.draw({ x: 0, y: 0, w: 10, h: 10 });
        \\term.endFrame();
        \\p.toTop();
        \\check("wheel-down", p.onMouse(mouse({ button: "wheel_down" })) === true && p.scroll === 5);
        \\check("wheel-up", p.onMouse(mouse({ button: "wheel_up" })) === true && p.scroll === 0);
        \\check("click-not-scroll", p.onMouse(mouse({ button: "left" })) === false && p.scroll === 0);
        \\
        \\// A click selects the row under the pointer. A two-line row covers two screen rows.
        \\const L = new List({ key: (it) => it.id, itemHeight: 2, format: (it) => ({ text: it.id }) });
        \\L.setItems([{ id: "a" }, { id: "b" }, { id: "c" }]);
        \\term.beginFrame();
        \\L.draw({ x: 2, y: 3, w: 8, h: 6 });
        \\term.endFrame();
        \\check("list-click", L.onMouse(mouse({ col: 3, row: 5, button: "left" })) === true && L.selectedKey === "b");
        \\check("list-click-outside", L.onMouse(mouse({ col: 0, row: 5, button: "left" })) === false);
        \\check("list-wheel", L.onMouse(mouse({ col: 3, row: 3, button: "wheel_down" })) === true && L.selectedKey === "c");
        \\// A short pane paints one two-line row, so a click on the leftover row selects nothing.
        \\const S = new List({ key: (it) => it.id, itemHeight: 2, format: (it) => ({ text: it.id }) });
        \\S.setItems([{ id: "a" }, { id: "b" }]);
        \\term.beginFrame();
        \\S.draw({ x: 0, y: 0, w: 8, h: 3 });
        \\term.endFrame();
        \\check("list-partial-row", S.onMouse(mouse({ col: 1, row: 2, button: "left" })) === false && S.selectedKey === "a");
        \\
        \\// A cleared rect drops a click, so a row that left the screen cannot be hit.
        \\L.clearRect();
        \\check("list-click-cleared", L.onMouse(mouse({ col: 3, row: 5, button: "left" })) === false);
        \\
        \\// A press focuses the pane under the pointer; the wheel reaches it without moving focus.
        \\class Pane extends View {
        \\  constructor() { super(); this.seen = []; }
        \\  draw() {}
        \\  onMouse(ev) { this.seen.push(ev.button); return true; }
        \\}
        \\const left = new Pane();
        \\const right = new Pane();
        \\const a = new Node(left);
        \\const b = new Node(right);
        \\root.setRoot(Node.branch("row", a, b, 0.5));
        \\root.root_node.layout({ x: 0, y: 0, w: 21, h: 5 });
        \\root.focusLeaf(a);
        \\root.routeMouse(mouse({ col: 15, row: 2, button: "left", event: "press" }));
        \\check("press-focuses", root.active === right && right.seen.length === 1);
        \\root.focusLeaf(a);
        \\root.routeMouse(mouse({ col: 15, row: 2, button: "wheel_down", event: "press" }));
        \\check("wheel-keeps-focus", root.active === left && right.seen.length === 2);
        \\root.routeMouse(mouse({ col: 10, row: 2, button: "left", event: "press" }));
        \\check("rule-hits-nothing", right.seen.length === 2 && left.seen.length === 0);
        \\
        \\// A left press captures the pane. The drag and the release reach it even over another pane.
        \\right.seen.length = 0;
        \\left.seen.length = 0;
        \\root.routeMouse(mouse({ col: 15, row: 2, button: "left", event: "press" }));
        \\root.routeMouse(mouse({ col: 3, row: 2, button: "left", event: "drag" }));
        \\root.routeMouse(mouse({ col: 3, row: 2, button: "left", event: "release" }));
        \\check("capture-drag", right.seen.length === 3 && left.seen.length === 0);
        \\// The release ends the capture, so the next press hits the pane under the pointer.
        \\root.routeMouse(mouse({ col: 3, row: 2, button: "left", event: "press" }));
        \\check("capture-released", left.seen.length === 1);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "mouse.js");
    try expectJs(host, "ok");
}

test "yuke:ui copy targets: last reply, message list, and code blocks" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 10, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const body = { u1: "ask", a1: "text\n```zig\nconst a = 1;\n```\nmore", a2: "second reply" };
        \\const t = new Transcript({ textOf: (id) => body[id] || "" });
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], null);
        \\
        \\check("last-assistant", t.last("assistant").id === "a1");
        \\check("last-any", t.last().id === "a1");
        \\check("text-for", t.textFor(t.last("assistant")) === body.a1);
        \\check("no-user-code", t.messages().length === 2);
        \\
        \\// The block body carries no fence line and no language line.
        \\const blocks = t.codeBlocks();
        \\check("one-block", blocks.length === 1);
        \\check("block-lang", blocks[0].lang === "zig");
        \\check("block-text", blocks[0].text === "const a = 1;");
        \\check("block-owner", blocks[0].id === "a1");
        \\
        \\// A user turn can hold a fence too, so no turn type is skipped.
        \\const ub = { u2: "look:\n```sh\nls -l\n```", a3: "ok" };
        \\const ut = new Transcript({ textOf: (id) => ub[id] || "" });
        \\ut.setOutline([{ id: "u2", type: "user" }, { id: "a3", type: "assistant" }], null);
        \\check("user-block", ut.codeBlocks().length === 1 && ut.codeBlocks()[0].text === "ls -l");
        \\
        \\// `codeBlocks` shares the row cache with the renderer, so a changed source must drop it.
        \\const cb = { a1: "```zig\nold\n```" };
        \\const ct = new Transcript({ textOf: (id) => cb[id] || "" });
        \\ct.setOutline([{ id: "a1", type: "assistant" }], null);
        \\const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0));
        \\check("rows-old", rowsHave(ct.rows(40, 0, 100), "old"));
        \\const doc0 = ct._docs.get("a1");
        \\cb.a1 = "```zig\nnew\n```";
        \\check("blocks-new", ct.codeBlocks()[0].text === "new");
        \\check("same-doc", ct._docs.get("a1") === doc0);
        \\check("rows-new", rowsHave(ct.rows(40, 0, 100), "new"));
        \\
        \\// A returned descriptor is a copy, so a caller cannot change the transcript.
        \\const got = t.last("assistant");
        \\got.id = "hacked";
        \\check("no-aliasing", t.last("assistant").id === "a1");
        \\
        \\// The streaming draft is the newest message.
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], { id: "a2", type: "assistant" });
        \\check("draft-is-last", t.last("assistant").id === "a2");
        \\check("empty-last", new Transcript({}).last("assistant") === null);
        \\
        \\// term.copy writes OSC 52 and returns the byte count. It refuses a payload over the cap.
        \\check("copy-ok", term.copy("hi") === 2);
        \\check("copy-utf8-bytes", term.copy("héllo 🙂") === 11);
        \\check("copy-too-large", term.copy("x".repeat(term.clipboardMax + 1)) === -1);
        \\// A non-string argument is a type error, so a stray object never reaches the clipboard.
        \\const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
        \\check("copy-number", throws(() => term.copy(42)));
        \\check("copy-null", throws(() => term.copy(null)));
        \\check("copy-object", throws(() => term.copy({ toString: () => "x" })));
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "copy.js");
    try expectJs(host, "ok");
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "\x1b]52;c;aGk=\x1b\\") != null);
}

test "yuke:ui drag selection spans rows, copies, and clears on a width change" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });
        \\
        \\// Two user turns. A user row is plain text with a two-column gutter.
        \\const body = { u1: "alpha", u2: "bravo" };
        \\let copied = null;
        \\const t = new Transcript({ textOf: (id) => body[id] || "", onSelect: (s) => (copied = s) });
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "u2", type: "user" }], null);
        \\const paint = () => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: 12 }); term.endFrame(); };
        \\paint();
        \\
        \\// Drag inside one row: the gutter is two columns, so column 2 is the first character.
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(5, 0, "drag"));
        \\check("within-row", t.selectedText() === "lp");
        \\
        \\// Row 1 is the blank row after "alpha", so the drag crosses into the second message.
        \\t.onMouse(at(4, 2, "drag"));
        \\// The blank row between the turns stays in the copy as a blank line.
        \\check("across-rows", t.selectedText() === "lpha\n\nbr");
        \\t.onMouse(at(4, 2, "release"));
        \\check("copy-on-release", copied === "lpha\n\nbr");
        \\
        \\// A drag backwards selects the same text, because the ends are ordered.
        \\t.onMouse(at(4, 2, "press"));
        \\t.onMouse(at(3, 0, "drag"));
        \\check("reverse-drag", t.selectedText() === "lpha\n\nbr");
        \\
        \\// The selected part of a visible row carries a range, and the rest of the row does not.
        \\const rows = t.rows(40, 0, 12);
        \\check("row-sel", rows[0].sel && rows[0].sel.from === 1 && rows[0].sel.to === 5);
        \\// The visible row is a copy, so a selection never sticks to the cached row.
        \\t.clearSelection();
        \\check("row-sel-copy", t.rows(40, 0, 12)[0].sel === undefined);
        \\
        \\// A bare click drops the selection instead of copying an empty string.
        \\copied = null;
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(3, 0, "release"));
        \\check("click-clears", t.selection === null && copied === null);
        \\
        \\// A cursor at column 0 of the end row adds no trailing blank line.
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(2, 2, "drag"));
        \\check("no-trailing-newline", t.selectedText() === "lpha\n");
        \\
        \\// A stray drag or release without a press changes nothing.
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(5, 0, "drag"));
        \\t.onMouse(at(5, 0, "release"));
        \\copied = null;
        \\t.onMouse(at(9, 0, "drag"));
        \\check("orphan-drag", t.selectedText() === "lp");
        \\t.onMouse(at(9, 0, "release"));
        \\check("orphan-release", copied === null);
        \\
        \\// An append never moves the source before it, so a selection in the draft survives a delta.
        \\body.a9 = "draft text";
        \\t.setOutline([{ id: "u1", type: "user" }], { id: "a9", type: "assistant" });
        \\paint();
        \\// Rows 0 and 1 belong to "alpha", so row 2 is the first draft row.
        \\t.onMouse(at(3, 2, "press"));
        \\t.onMouse(at(5, 2, "drag"));
        \\check("draft-sel", t.selection !== null && t.selection.anchor.id === "a9");
        \\body.a9 = "draft text and more";
        \\t.setActive("a9");
        \\check("stream-keeps", t.selectedText() === "ra");
        \\// A selection in another message survives a draft delta.
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(5, 0, "drag"));
        \\t.setActive("a9");
        \\check("other-msg-kept", t.selection !== null);
        \\
        \\// An edit before the selection moves the text under it, so the selection drops.
        \\body.a7 = "alpha bravo";
        \\t.setOutline([], { id: "a7", type: "assistant" });
        \\paint();
        \\t.onMouse(at(8, 0, "press"));
        \\t.onMouse(at(13, 0, "drag"));
        \\check("edit-before-sel", t.selectedText() === "bravo");
        \\body.a7 = "xxx alpha bravo";
        \\t.setActive("a7");
        \\check("edit-clears", t.selection === null);
        \\// An append after it keeps the same words.
        \\body.a8 = "alpha bravo";
        \\t.setOutline([], { id: "a8", type: "assistant" });
        \\paint();
        \\t.onMouse(at(8, 0, "press"));
        \\t.onMouse(at(13, 0, "drag"));
        \\body.a8 = "alpha bravo charlie";
        \\t.setActive("a8");
        \\check("append-keeps", t.selectedText() === "bravo");
        \\
        \\// A user turn maps each row back to its source, so a rewrap keeps the same words.
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "u2", type: "user" }], null);
        \\paint();
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(5, 0, "drag"));
        \\check("before-resize", t.selectedText() === "lp");
        \\t.rows(20, 0, 12);
        \\check("keep-user-resize", t.selectedText() === "lp");
        \\
        \\// A markdown turn re-anchors on its source, so the same words stay selected.
        \\body.a2 = "alpha bravo charlie delta echo";
        \\t.setOutline([{ id: "a2", type: "assistant" }], null);
        \\t.rows(40, 0, 12);
        \\paint();
        \\t.onMouse(at(8, 0, "press"));
        \\t.onMouse(at(13, 0, "drag"));
        \\check("wide-sel", t.selectedText() === "bravo");
        \\t.rows(14, 0, 12);
        \\check("keep-on-resize", t.selectedText() === "bravo");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "sel.js");
    try expectJs(host, "ok");
}

test "yuke:ui the transcript seam maps a position to source, screen, and scroll" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 8, 20);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\import { Document } from "yuke:md";
        \\import { prevGrapheme, nextGrapheme } from "yuke:core";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const body = { a1: "alpha bravo charlie delta echo foxtrot golf hotel india" };
        \\const t = new Transcript({ textOf: (id) => body[id] || "" });
        \\t.setOutline([{ id: "a1", type: "assistant" }], null);
        \\const rect = { x: 0, y: 0, w: 20, h: 2 };
        \\const paint = () => { term.beginFrame(); t.draw(rect); term.endFrame(); };
        \\paint();
        \\const count = t.rowCountOf("a1");
        \\check("wrapped", count > rect.h);
        \\
        \\// Every column that carries source maps to an offset that maps back to the same offset.
        \\let bad = 0;
        \\for (let r = 0; r < count; r++) {
        \\  const n = t.rowTextAt("a1", r).length;
        \\  for (let c = 0; c <= n; c++) {
        \\    const off = t.sourceAt({ id: "a1", row: r, col: c });
        \\    if (off < 0) continue;
        \\    const back = t.posAtSource("a1", off);
        \\    if (!back || t.sourceAt(back) !== off) bad++;
        \\  }
        \\}
        \\check("roundtrip", bad === 0);
        \\
        \\// An offset past the end takes the last position, so a selection to the end survives.
        \\check("tail", t.posAtSource("a1", body.a1.length + 99) !== null);
        \\check("no-source", t.sourceAt({ id: "a1", row: count + 5, col: 0 }) === -1);
        \\
        \\// The screen cell counts the gutter, and a row off the viewport has none.
        \\t.pager.toTop();
        \\paint();
        \\const head = t.screenAt({ id: "a1", row: 0, col: 3 });
        \\// The assistant gutter is two columns wide.
        \\check("screen-at", head && head.y === 0 && head.x === 2 + 3);
        \\const last = { id: "a1", row: count - 1, col: 0 };
        \\check("hidden-before", t.screenAt(last) === null);
        \\t.ensureVisible(last);
        \\check("visible-after", t.screenAt(last) !== null);
        \\
        \\// A source offset inside a grapheme snaps to its edge.
        \\{
        \\  const em = new Transcript({ textOf: () => "a😀b" });
        \\  em.setOutline([{ id: "e1", type: "assistant" }], null);
        \\  em.rows(20, 0, 4);
        \\  const p1 = em.posAtSource("e1", 2);
        \\  const line = em.rowTextAt("e1", 0);
        \\  check("grapheme-snap", p1 && (p1.col === line.indexOf("😀") || p1.col === line.indexOf("😀") + 2));
        \\}
        \\
        \\// The blocks carry their source span, so a caller can move by markdown structure.
        \\const doc = new Document();
        \\doc.setText("# H\n\npara\n\n```\nx\n```");
        \\const bs = doc.blocks();
        \\check("blocks", bs.length === 3 && bs[0].kind === "heading" && bs[0].at === 0 && bs[2].kind === "code");
        \\
        \\// A grapheme step crosses an astral pair whole.
        \\check("grapheme-step", nextGrapheme("a𝄞b", 1) === 3 && prevGrapheme("a𝄞b", 3) === 1);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "seam.js");
    try expectJs(host, "ok");
}

test "yuke:composer-vim moves, edits, and puts in normal mode" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { root, Node, View, keymap } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { ChatView } from "yuke:transcript";
        \\import { composerVim, setComposerMode, composerMode } from "yuke:composer-vim";
        \\import { register } from "yuke:vim";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const v = new ChatView({ textOf: () => "" });
        \\root.setRoot(new Node(v));
        \\root.focusView(v);
        \\const off = plugins.use(composerVim);
        \\const t = v.composer.input;
        \\const key = (ch) => ({ type: "key", code: "char", char: ch, text: ch, event: "press", mods: 0 });
        \\// The keys go through the real dispatch, so the bindings and the context both run.
        \\const press = (str) => { for (const ch of str) root.onEvent(key(ch)); };
        \\
        \\t.setText("alpha bravo charlie");
        \\setComposerMode(v.composer, "normal");
        \\press("$");
        \\// Normal mode holds the caret on a character, so it never sits past the last one.
        \\check("dollar", t.caret === 18);
        \\press("bb");
        \\check("back-word", t.caret === 6);
        \\press("w");
        \\check("fwd-word", t.caret === 12);
        \\press("e");
        \\check("word-end", t.caret === 18);
        \\press("0");
        \\check("zero", t.caret === 0);
        \\
        \\// A shifted letter keeps its case, so D is not a pending d.
        \\press("$x");
        \\check("x", t.text === "alpha bravo charli" && t.caret === 17);
        \\press("0w");
        \\press("D");
        \\check("D", t.text === "alpha " && register.text === "bravo charli");
        \\
        \\// "p" puts the register after the caret.
        \\press("$p");
        \\check("put-char", t.text === "alpha bravo charli");
        \\
        \\// "p" leaves the caret on the last character it put.
        \\t.setText("abc");
        \\setComposerMode(v.composer, "normal");
        \\press("gg");
        \\register.set("XY", false);
        \\press("p");
        \\check("put-caret", t.text === "aXYbc" && t.caret === 2);
        \\
        \\// "dd" on the last line takes the newline before it, but the register keeps only the body.
        \\t.setText("one\ntwo");
        \\setComposerMode(v.composer, "normal");
        \\press("$dd");
        \\check("dd-last", t.text === "one" && register.text === "two" && register.linewise);
        \\press("p");
        \\check("put-line", t.text === "one\ntwo");
        \\
        \\// Normal mode holds the caret on a character after every motion.
        \\v.composer.rect = { x: 0, y: 0, w: 40, h: 3 };
        \\t.setText("abcdef\ntwo");
        \\setComposerMode(v.composer, "normal");
        \\press("gg$j");
        \\check("row-clamp", t.caret === t.text.length - 1);
        \\t.setText("one\n");
        \\setComposerMode(v.composer, "normal");
        \\press("G");
        \\check("trailing-newline", t.caret === 2);
        \\
        \\// "x" never joins two lines, and a blank line keeps the register.
        \\t.setText("a\n\nb");
        \\setComposerMode(v.composer, "normal");
        \\press("gg");
        \\press("jx");
        \\check("x-blank-line", t.text === "a\n\nb");
        \\
        \\// An unbound letter inserts nothing in normal mode and runs no command.
        \\t.setText("abc");
        \\setComposerMode(v.composer, "normal");
        \\press("z");
        \\check("swallow", t.text === "abc");
        \\check("named-key-passes", v.composer.onKey({ type: "key", code: "tab", char: "", text: "", event: "press", mods: 0 }) === false);
        \\
        \\// The motions run as bindings, so a binding under the same context reaches the same keys.
        \\{
        \\  let hits = 0;
        \\  const off = keymap.add({ z: () => { hits++; return true; } }, "chat && composer_vim == normal");
        \\  t.setText("abc");
        \\  setComposerMode(v.composer, "normal");
        \\  press("z");
        \\  check("normal-uses-keymap", hits === 1);
        \\  off();
        \\}
        \\
        \\// An unresolved sequence runs its second stroke on its own rather than dropping it.
        \\{
        \\  t.setText("abc def");
        \\  setComposerMode(v.composer, "normal");
        \\  press("$");
        \\  const at = t.caret;
        \\  press("dh");
        \\  check("operator-fallthrough", t.caret === at - 1 && t.text === "abc def");
        \\}
        \\
        \\// Esc reaches its binding while an operator waits, so a mode always has an exit.
        \\{
        \\  setComposerMode(v.composer, "normal");
        \\  press("d");
        \\  check("operator-armed", keymap.pending !== null);
        \\  root.onEvent({ type: "key", code: "esc", char: "", text: "", event: "press", mods: 0 });
        \\  check("operator-esc", keymap.pending === null);
        \\}
        \\
        \\// Insert mode still inserts through the real dispatch.
        \\{
        \\  t.setText("");
        \\  setComposerMode(v.composer, "insert");
        \\  press("hi");
        \\  check("insert-inserts", t.text === "hi");
        \\}
        \\
        \\// The bindings stay off a pane that is not the chat, even while the chat holds normal mode.
        \\{
        \\  class Side extends View { get name() { return "side"; } draw() {} }
        \\  const side = new Side();
        \\  t.setText("abc");
        \\  setComposerMode(v.composer, "normal");
        \\  root.setRoot(Node.branch("row", new Node(side), new Node(v), 0.5));
        \\  root.focusView(side);
        \\  press("x");
        \\  check("normal-needs-chat", t.text === "abc");
        \\  root.setRoot(new Node(v));
        \\  root.focusView(v);
        \\}
        \\
        \\// "i" types again, and an unload leaves the composer plain.
        \\press("i");
        \\check("insert", composerMode(v.composer) === "insert");
        \\setComposerMode(v.composer, "normal");
        \\t.setText("");
        \\off();
        \\check("unloaded", composerMode(v.composer) === "insert");
        \\v.composer.onKey(key("z"));
        \\check("types-after-unload", t.text === "z");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "cvim.js");
    try expectJs(host, "ok");
}

test "yuke:transcript-vim moves a cursor and gives the caret to the transcript" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 20, 24);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { root, Node, keymap } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { ChatView } from "yuke:transcript";
        \\import { transcriptVim } from "yuke:transcript-vim";
        \\import { register } from "yuke:vim";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: "", event: "press", mods: 0 });
        \\
        \\// The shell is not loaded, so a yank must reach the clipboard through the core alone.
        \\const body = { a1: "alpha **bravo** charlie delta" };
        \\let copied = null;
        \\term.copy = (x) => { copied = x; return x.length; };
        \\const v = new ChatView({ textOf: (id) => body[id] || "" });
        \\v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
        \\root.setRoot(new Node(v));
        \\v.rect = { x: 0, y: 0, w: 24, h: 18 };
        \\const paint = () => { term.beginFrame(); v.draw(true); term.endFrame(); };
        \\paint();
        \\
        \\// Without the plugin the composer owns the caret and a bare key types.
        \\const composerCaret = v.cursor();
        \\check("composer-caret", composerCaret && composerCaret.y === v.composer.rect.y);
        \\
        \\const off = plugins.use(transcriptVim);
        \\// The pane takes no cursor until the focus moves, so typing still works.
        \\check("still-composer", v.cursor().y === v.composer.rect.y);
        \\v.focusRegion("transcript");
        \\const c0 = v.cursor();
        \\check("transcript-caret", c0 && c0.visible && c0.y < v.composer.rect.y);
        \\
        \\// A motion moves the caret one cell, and it never reaches the composer text.
        \\const before = v.composer.input.text;
        \\root.onEvent(key("char", "l"));
        \\const c1 = v.cursor();
        \\check("moved-right", c1.x === c0.x + 1);
        \\check("transcript-blocks-composer", v.composer.input.text === before);
        \\root.onEvent(key("char", "h"));
        \\check("moved-left", v.cursor().x === c0.x);
        \\
        \\// "$" goes to the row end and "0" back to its start.
        \\root.onEvent(key("char", "$"));
        \\check("row-end", v.cursor().x > c0.x);
        \\root.onEvent(key("char", "0"));
        \\check("row-start", v.cursor().x === c0.x);
        \\
        \\// The transcript cursor also stays on a character.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "$"));
        \\check("transcript-dollar", v.cursor().x === 2 + v.transcript.rowTextAt("a1", 0).length - 1);
        \\
        \\// "gg" reaches the first row and "G" the last. A shifted letter keeps its case.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\const top = v.cursor().y;
        \\root.onEvent(key("char", "G"));
        \\check("G-moves", v.cursor().y > top);
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\check("gg-returns", v.cursor().y === top);
        \\
        \\// An unbound key still reaches the global keymap.
        \\let global = 0;
        \\const offZ = keymap.add({ z: () => { global++; } });
        \\root.onEvent(key("char", "z"));
        \\check("global-keymap-fallback", global === 1 && v.composer.input.text === before);
        \\offZ();
        \\
        \\// A click places the cursor on the row it landed on and takes the region.
        \\const r = v.transcript.pager.rect();
        \\root.onEvent(key("char", "G"));
        \\const clickBase = v.cursor().y;
        \\v.focusRegion("composer");
        \\const press = (row) => v.onMouse({ type: "mouse", col: r.x + 4, row, button: "left", event: "press", mods: 0 });
        \\press(r.y);
        \\check("click-takes-region", v.focus === "transcript");
        \\check("click-moves-cursor", !!v.cursor() && v.cursor().y === r.y && clickBase !== r.y);
        \\
        \\// A press below the transcript hands the region back to the composer.
        \\press(v.composer.rect.y);
        \\check("click-outside-releases", v.focus === "composer");
        \\v.focusRegion("transcript");
        \\
        \\// "v" starts a selection that the motions extend. Vim visual holds both ends, so the
        \\// character under the cursor stays inside.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "v"));
        \\root.onEvent(key("char", "l"));
        \\root.onEvent(key("char", "l"));
        \\check("visual-inclusive", v.transcript.selectedText() === "alp");
        \\
        \\// "o" puts the cursor on the other end, so the far end grows instead.
        \\const far = v.cursor().x;
        \\root.onEvent(key("char", "o"));
        \\check("swap-ends", v.cursor().x < far);
        \\root.onEvent(key("char", "o"));
        \\check("swap-back", v.cursor().x === far);
        \\
        \\// "y" copies the rendered text and drops the selection.
        \\root.onEvent(key("char", "y"));
        \\check("yank-visual", copied === "alp" && v.transcript.selection === null);
        \\
        \\// "y" alone waits for a second "y", because a motion can follow it.
        \\copied = null;
        \\root.onEvent(key("char", "y"));
        \\check("yank-pending", copied === null);
        \\root.onEvent(key("char", "y"));
        \\check("yank-row", copied === "alpha bravo charlie");
        \\
        \\// "gy" copies the markdown source, so the markup between the ends survives.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "y"));
        \\check("yank-source", copied === "alpha **bravo** charlie");
        \\
        \\// "Y" takes whole rows, so the register is linewise even inside visual mode.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "v"));
        \\root.onEvent(key("char", "l"));
        \\root.onEvent(key("char", "Y"));
        \\check("visual-Y-linewise", register.linewise === true && copied === "alpha bravo charlie");
        \\
        \\// "}" and "{" step by markdown block.
        \\body.a2 = "# Head\n\npara text\n\n- item";
        \\v.transcript.setOutline([{ id: "a1", type: "assistant" }, { id: "a2", type: "assistant" }], null);
        \\paint();
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\const seen = [];
        \\for (let i = 0; i < 4; i++) { root.onEvent(key("char", "}")); seen.push(v.cursor().y); }
        \\check("block-forward", seen.length === 4 && seen[0] < seen[1] && seen[1] < seen[2]);
        \\const back = seen[seen.length - 1];
        \\root.onEvent(key("char", "{"));
        \\check("block-back", v.cursor().y < back);
        \\
        \\// A rewrap moves every row index, so the cursor holds its source character instead.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\// Row 1 holds different words at each width, so its row index alone is not the same text.
        \\root.onEvent(key("char", "j"));
        \\const srcAt = () => v.transcript.sourceAt(v.transcript.posAt(v.cursor().x, v.cursor().y, false));
        \\const srcBefore = srcAt();
        \\v.rect = { x: 0, y: 0, w: 14, h: 18 };
        \\paint();
        \\const srcAfter = srcAt();
        \\check("cursor-survives-rewrap", srcBefore >= 0 && srcAfter === srcBefore);
        \\v.rect = { x: 0, y: 0, w: 24, h: 18 };
        \\paint();
        \\
        \\// A region change clears visual mode and drops its selection.
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "g"));
        \\root.onEvent(key("char", "v"));
        \\root.onEvent(key("char", "l"));
        \\check("visual-selects", v.transcript.selection !== null);
        \\v.focusRegion("composer");
        \\check("region-clears-selection", v.transcript.selection === null);
        \\v.focusRegion("transcript");
        \\root.onEvent(key("char", "l"));
        \\check("region-clears-visual", v.transcript.selection === null);
        \\
        \\// A focus jump from another pane hands the keyboard back to the composer.
        \\const side = { name: "sessions", draw() {}, onKey() { return false; } };
        \\root.setRoot(Node.branch("row", new Node(side), new Node(v), 0.3));
        \\root.focusView(v);
        \\paint();
        \\v.focusRegion("transcript");
        \\check("region-transcript", v.cursor() && v.cursor().y < v.composer.rect.y);
        \\root.focusView(side);
        \\root.focusView(v);
        \\check("jump-composer", v.cursor() && v.cursor().y === v.composer.rect.y);
        \\
        \\// An unload returns the region and the caret to the composer.
        \\v.focusRegion("transcript");
        \\off();
        \\check("unload-region", v.focus === "composer");
        \\check("unload-restores", (v.cursor() || {}).y === v.composer.rect.y);
        \\root.onEvent(key("char", "x"));
        \\check("unload-restores-typing", v.composer.input.text === before + "x");
        \\check("unload-consumes", v.onKey(key("char", "y")) === true && v.composer.input.text === before + "xy");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "tvim.js");
    try expectJs(host, "ok");
}

test "yuke:ui a transcript with no message shows its placeholder" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 8, 30);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\const t = new Transcript({ textOf: () => "", empty: () => [{ text: "new chat" }] });
        \\t.setOutline([], null);
        \\globalThis.count = t.rowCount(30);
        \\term.beginFrame();
        \\t.draw({ x: 0, y: 0, w: 30, h: 8 });
        \\term.endFrame();
    , "empty.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.count"));
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "new chat") != null);
}

test "yuke:ui tool parts render, collapse, copy, and toggle" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { root, Node } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { Transcript, ChatView } from "yuke:transcript";
        \\import { transcriptVim } from "yuke:transcript-vim";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
        \\const rowsGroup = (rs, group) => rs.some((r) => (r.segments || []).some((sg) => sg.group === group) || r.group === group);
        \\const markerOf = (rs) => (rs[0] && rs[0].marker) || "";
        \\const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });
        \\const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: "", event: "press", mods: 0 });
        \\
        \\const parts = {
        \\  done: [{ type: "tool", id: 0, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "alpha\\nbeta", duration_ms: 12 } }],
        \\  run: [{ type: "tool", id: 0, name: "exec", arguments: '{"command":"zig build test"}', state: { type: "running", started_at_ms: 1, output: "compiling" } }],
        \\  err: [{ type: "tool", id: 1, name: "edit", arguments: '{"path":"b.zig"}', state: { type: "error", error: "no match", duration_ms: 3 } }],
        \\  mix: [{ type: "text", id: 0, text: "**hi** there" }, { type: "tool", id: 1, name: "read", arguments: '{"path":"c.zig"}', state: { type: "completed", output: "ok", duration_ms: 1 } }],
        \\  diff: [{ type: "tool", id: 0, name: "edit", arguments: '{"path":"d.zig"}', state: { type: "completed", output: "ok", duration_ms: 2, view: [{ type: "diff", files: [{ path: "d.zig", hunks: [{ old_start: 1, old_lines: 1, new_start: 1, new_lines: 1, lines: ["-old", "+new"] }] }] }] } }],
        \\};
        \\const t = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
        \\t.setOutline([{ id: "done", type: "assistant" }, { id: "run", type: "assistant" }, { id: "err", type: "assistant" }], null);
        \\const paint = (h) => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: h || 12 }); term.endFrame(); };
        \\paint();
        \\
        \\const done = t.rows(40, 0, 4);
        \\check("done-name", rowsHave(done, "read"));
        \\check("done-path", rowsHave(done, "a.zig"));
        \\check("done-state", rowsHave(done, "done"));
        \\check("done-collapsed", markerOf(done) === "▸" && !rowsHave(done, "alpha"));
        \\
        \\const runStart = t._globalRow({ id: "run", row: 0, col: 0 });
        \\const run = t.rows(40, runStart, 6);
        \\check("run-name", rowsHave(run, "exec"));
        \\check("run-expanded", markerOf(run) === "▾" && rowsHave(run, "compiling"));
        \\
        \\const errStart = t._globalRow({ id: "err", row: 0, col: 0 });
        \\const err = t.rows(40, errStart, 6);
        \\check("err-expanded", rowsHave(err, "no match") && rowsGroup(err, "TxToolError"));
        \\
        \\// A click on a collapsed header expands it. A drag does not.
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(3, 0, "release"));
        \\const doneOpen = t.rows(40, 0, 6);
        \\check("click-open", markerOf(doneOpen) === "▾" && rowsHave(doneOpen, "alpha"));
        \\t.onMouse(at(3, 0, "press"));
        \\t.onMouse(at(5, 0, "drag"));
        \\t.onMouse(at(5, 0, "release"));
        \\check("drag-keeps", markerOf(t.rows(40, 0, 6)) === "▾");
        \\
        \\const mix = new Transcript({ textOf: (id) => (id === "mix" ? "**hi** there" : ""), partsOf: (id) => parts[id] || [] });
        \\mix.setOutline([{ id: "mix", type: "assistant" }], null);
        \\term.beginFrame(); mix.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
        \\const mixRows = mix.rows(40, 0, 8);
        \\check("mix-text", rowsHave(mixRows, "hi") && rowsHave(mixRows, "there"));
        \\check("mix-tool", rowsHave(mixRows, "read") && rowsHave(mixRows, "c.zig"));
        \\const srcEnd = mix._sourceOf("mix").length;
        \\mix.select(mix.posAtSource("mix", 0), mix.posAtSource("mix", srcEnd));
        \\const src = mix.selectedSource();
        \\check("mix-source-md", src.indexOf("hi") >= 0 && src.indexOf("there") >= 0);
        \\check("mix-source-tool", src.indexOf("read") >= 0 && src.indexOf("c.zig") >= 0);
        \\
        \\const dt = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
        \\dt.setOutline([{ id: "diff", type: "assistant" }], null);
        \\dt.togglePart("diff", 0);
        \\const diffRows = dt.rows(40, 0, 10);
        \\check("diff-path", rowsHave(diffRows, "d.zig"));
        \\check("diff-del", rowsHave(diffRows, "-old") && rowsGroup(diffRows, "TxToolDel"));
        \\check("diff-add", rowsHave(diffRows, "+new") && rowsGroup(diffRows, "TxToolAdd"));
        \\
        \\const v = new ChatView({ textOf: () => "", partsOf: (id) => parts[id] || [] });
        \\v.transcript.setOutline([{ id: "done", type: "assistant" }], null);
        \\root.setRoot(new Node(v));
        \\v.rect = { x: 0, y: 0, w: 40, h: 12 };
        \\const vpaint = () => { term.beginFrame(); v.draw(true); term.endFrame(); };
        \\vpaint();
        \\plugins.use(transcriptVim);
        \\v.focusRegion("transcript");
        \\vpaint();
        \\check("enter-closed", markerOf(v.transcript.rows(40, 0, 4)) === "▸");
        \\root.onEvent(key("enter"));
        \\check("enter-open", markerOf(v.transcript.rows(40, 0, 6)) === "▾");
        \\const vr = v.transcript.pager.rect();
        \\v.onMouse({ type: "mouse", col: vr.x + 3, row: vr.y, button: "left", event: "press", mods: 0 });
        \\v.onMouse({ type: "mouse", col: vr.x + 3, row: vr.y, button: "left", event: "release", mods: 0 });
        \\check("plugin-click-fold", markerOf(v.transcript.rows(40, 0, 6)) === "▸");
        \\
        \\const longOut = Array.from({ length: 80 }, (_, i) => "line" + i).join("\n");
        \\parts.long = [{ type: "tool", id: 0, name: "exec", arguments: '{"command":"seq"}', state: { type: "completed", output: longOut, duration_ms: 1 } }];
        \\const longT = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
        \\longT.setOutline([{ id: "long", type: "assistant" }], null);
        \\term.beginFrame(); longT.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
        \\longT.onMouse(at(3, 0, "press"));
        \\longT.onMouse(at(3, 0, "release"));
        \\term.beginFrame(); longT.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
        \\const headerAt = longT.screenAt({ id: "long", row: 0, col: 0 });
        \\check("header-on-screen", !!headerAt && headerAt.y >= 0 && headerAt.y < 8);
        \\check("unfold-unstuck", longT.pager.stuck === false);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "ui-components.js");
    try expectJs(host, "ok");
}

test "yuke:ui reasoning auto-collapses and J/K walks parts" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
        \\const markerOf = (rs) => (rs[0] && rs[0].marker) || "";
        \\
        \\const parts = {};
        \\const t = new Transcript({ textOf: (id) => (id === "u" ? "ask" : ""), partsOf: (id) => parts[id] || [] });
        \\
        \\parts.r1 = [{ type: "reasoning", id: 0, text: "because why" }];
        \\t.setOutline([], { id: "r1", type: "assistant" });
        \\term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
        \\let rs = t.rows(40, 0, 10);
        \\check("live-name", rowsHave(rs, "thinking"));
        \\check("live-body", rowsHave(rs, "because") && markerOf(rs) === "▾");
        \\check("thought-style", rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf("because") >= 0 && sg.group === "TxThought")));
        \\
        \\parts.r1 = [{ type: "reasoning", id: 0, text: "because why" }, { type: "text", id: 1, text: "hello" }];
        \\t.setActive("r1");
        \\rs = t.rows(40, 0, 10);
        \\check("draft-keeps-thought", rowsHave(rs, "thinking") && rowsHave(rs, "because") && markerOf(rs) === "▾");
        \\
        \\t.setOutline([{ id: "r1", type: "assistant" }], null);
        \\rs = t.rows(40, 0, 10);
        \\check("commit-hides", rowsHave(rs, "thought") && !rowsHave(rs, "thinking") && markerOf(rs) === "▸" && !rowsHave(rs, "because"));
        \\
        \\t.togglePart("r1", 0);
        \\rs = t.rows(40, 0, 10);
        \\check("override-holds", markerOf(rs) === "▾" && rowsHave(rs, "because"));
        \\
        \\t.setOutline([{ id: "u", type: "user" }, { id: "r1", type: "assistant" }, { id: "u2", type: "user" }], { id: "r2", type: "assistant" });
        \\rs = t.rows(40, t._globalRow({ id: "r1", row: 0, col: 0 }), 8);
        \\check("later-send-keeps-override", markerOf(rs) === "▾" && rowsHave(rs, "because"));
        \\
        \\const num = new Transcript({ textOf: () => "", partsOf: () => [{ type: "reasoning", id: 0, text: "because why" }] });
        \\num.setOutline([{ id: 2, type: "assistant" }], null);
        \\term.beginFrame(); num.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
        \\num.togglePart(2, 0);
        \\num.setOutline([{ id: 2, type: "assistant" }, { id: 3, type: "user" }], { id: 4, type: "assistant" });
        \\check("num-id-later-send", markerOf(num.rows(40, num._globalRow({ id: 2, row: 0, col: 0 }), 8)) === "▾");
        \\
        \\const committed = new Transcript({ textOf: () => "", partsOf: () => [{ type: "reasoning", id: 0, text: "later" }] });
        \\committed.setOutline([{ id: "c", type: "assistant" }], null);
        \\term.beginFrame(); committed.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
        \\check("commit-collapsed", markerOf(committed.rows(40, 0, 6)) === "▸" && rowsHave(committed.rows(40, 0, 6), "thought"));
        \\
        \\parts.hid = [{ type: "redacted_reasoning", id: 0 }, { type: "text", id: 1, text: "visible" }];
        \\const hid = new Transcript({ textOf: () => "visible", partsOf: (id) => parts[id] || [] });
        \\hid.setOutline([{ id: "hid", type: "assistant" }], null);
        \\term.beginFrame(); hid.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
        \\const hrs = hid.rows(40, 0, 8);
        \\check("redacted-skip", rowsHave(hrs, "visible") && !rowsHave(hrs, "thought") && !rowsHave(hrs, "thinking"));
        \\
        \\parts.walk = [
        \\  { type: "reasoning", id: 0, text: "why" },
        \\  { type: "tool", id: 1, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "x", duration_ms: 1 } },
        \\  { type: "text", id: 2, text: "hello" },
        \\];
        \\const w = new Transcript({ textOf: (id) => (id === "u" ? "ask" : ""), partsOf: (id) => parts[id] || [] });
        \\w.setOutline([{ id: "u", type: "user" }, { id: "walk", type: "assistant" }], null);
        \\term.beginFrame(); w.draw({ x: 0, y: 0, w: 40, h: 16 }); term.endFrame();
        \\const p0 = { id: "u", row: 0, col: 0 };
        \\const p1 = w.partStep(p0, 1);
        \\check("jk-reason", p1 && w.partAt(p1) && w.partAt(p1).kind === "reasoning-header");
        \\const p2 = w.partStep(p1, 1);
        \\check("jk-tool", p2 && w.partAt(p2) && w.partAt(p2).kind === "tool-header");
        \\const p3 = w.partStep(p2, 1);
        \\check("jk-text", p3 && w.partAt(p3) && w.partAt(p3).kind === "text");
        \\const back = w.partStep(p3, -1);
        \\check("jk-back", back && back.id === p2.id && back.row === p2.row);
        \\
        \\const pack = new Transcript({ textOf: (id) => (id === "k" ? "kept the tail" : ""), partsOf: () => [] });
        \\pack.setOutline([{ id: "k", type: "compaction" }], null);
        \\term.beginFrame(); pack.draw({ x: 0, y: 0, w: 40, h: 6 }); term.endFrame();
        \\check("compaction", rowsHave(pack.rows(40, 0, 6), "kept the tail"));
        \\
        \\t.setOutline([{ id: "r1", type: "assistant" }], { id: "r2", type: "assistant" });
        \\rs = t.rows(40, t._globalRow({ id: "r1", row: 0, col: 0 }), 8);
        \\check("expand-survives-outline", markerOf(rs) === "▾" && rowsHave(rs, "because"));
        \\
        \\const mix = new Transcript({ textOf: () => "hello", partsOf: () => [{ type: "text", id: 0, text: "hello" }, { type: "tool", id: 1, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "ok", duration_ms: 1 } }] });
        \\mix.setOutline([{ id: "m1", type: "assistant" }], { id: "m1", type: "assistant" });
        \\term.beginFrame(); mix.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
        \\mix.select({ id: "m1", row: 0, col: 0 }, mix.posAtSource("m1", mix._sourceOf("m1").length));
        \\check("mix-had-sel", mix.selectedText() !== "");
        \\mix.setActive("m1");
        \\check("mix-sel-lives", mix.selection != null && mix.selectedText() !== "");
        \\
        \\const et = new Transcript({ textOf: () => "hi", partsOf: () => [{ type: "text", id: 0, text: "hi" }] });
        \\et.setOutline([{ id: "e1", type: "assistant", error: { type: "x", message: "boom" } }], null);
        \\term.beginFrame(); et.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
        \\let er = -1;
        \\const en = et.rowCountOf("e1");
        \\for (let i = 0; i < en; i++) if (et.rowTextAt("e1", i).indexOf("boom") >= 0) er = i;
        \\check("err-row", er >= 0);
        \\et.select({ id: "e1", row: er, col: 0 }, { id: "e1", row: er, col: et.rowTextAt("e1", er).length });
        \\check("err-sel", et.selectedText().indexOf("boom") >= 0);
        \\check("err-src", et.sourceAt({ id: "e1", row: er, col: 1 }) >= 0);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "reason.js");
    try expectJs(host, "ok");
}

test "yuke:md renders the GFM subset and caches finalized blocks" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { renderRows, Document } from "yuke:md";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const has = (rows, group, text) => rows.some((r) => r.segments.some((s) => s.group === group && s.text === text));
        \\
        \\check("inline", has(renderRows("hello **bold** and `code`", 80), "MdStrong", "bold") &&
        \\  has(renderRows("x `y` z", 80), "MdCode", "y"));
        \\check("emphasis", has(renderRows("an *word* here", 80), "MdEm", "word"));
        \\check("heading", has(renderRows("# Title", 80), "MdHeading", "Title"));
        \\check("code", has(renderRows("```js\nx=1\n```", 80), "MdCodeBlock", "x=1"));
        \\check("hr", renderRows("---", 80).some((r) => r.segments.some((s) => s.group === "MdRule")));
        \\check("list", has(renderRows("- a\n- b", 80), "MdListMark", "• "));
        \\check("quote", renderRows("> hi", 80).some((r) => r.segments.some((s) => s.group === "MdQuote")));
        \\const noGroup = (rows, group) => !rows.some((r) => r.segments.some((s) => s.group === group));
        \\// An underscore inside a word is not emphasis (code identifiers stay literal).
        \\check("intraword-underscore", noGroup(renderRows("call foo_bar_baz now", 80), "MdEm"));
        \\// A backslash escapes a marker, so it stays literal text.
        \\check("escape", noGroup(renderRows("not \\*bold\\* here", 80), "MdStrong"));
        \\// A link shows its text, never the URL.
        \\{
        \\  const rows = renderRows("see [docs](http://x) ok", 80);
        \\  check("link-text", has(rows, "MdText", "docs") &&
        \\    !rows.some((r) => r.segments.some((s) => s.text.indexOf("http") >= 0)));
        \\}
        \\// Double backticks let inline code hold a backtick.
        \\check("code-backtick", has(renderRows("use ``a`b`` now", 80), "MdCode", "a`b"));
        \\// Triple markers are strong and emphasis together.
        \\check("strong-em", has(renderRows("***wow***", 80), "MdStrongEm", "wow"));
        \\// Nested emphasis: the inner strong span keeps the outer emphasis.
        \\{
        \\  const rows = renderRows("*x **y** z*", 80);
        \\  check("nested-emph", has(rows, "MdStrongEm", "y") && has(rows, "MdEm", "x") && has(rows, "MdEm", "z"));
        \\}
        \\// A link label keeps the emphasis that encloses it.
        \\check("link-in-emphasis", has(renderRows("*[x](u)* y", 80), "MdEm", "x"));
        \\// A malformed link (a space in the destination) stays literal, not dropped.
        \\check("bad-link", renderRows("[foo](bad url)", 80).some((r) => r.segments.some((s) => s.text.indexOf("bad") >= 0)));
        \\// A table renders a column border.
        \\check("table", renderRows("| a | b |\n|---|---|\n| 1 | 2 |", 80).some((r) => r.segments.some((s) => s.group === "MdTableBorder")));
        \\// Cells align in columns, and a long cell wraps inside its column instead of breaking the row.
        \\const aligned = renderRows("| a | bb |\n|---|---|\n| ccc | d |", 80).map((r) => r.segments.map((s) => s.text).join(""));
        \\check("table-aligned", aligned[0] === "a   │ bb" && aligned[2] === "ccc │ d" && aligned[1] === "────┼───");
        \\const cellWrap = renderRows("| k | value |\n|---|---|\n| x | one two three four five six |", 20).map((r) => r.segments.map((s) => s.text).join(""));
        \\check("table-wraps", cellWrap.length > 3 && cellWrap.every((line) => line.length <= 20) && cellWrap[2].startsWith("x │ one"));
        \\
        \\// A long paragraph wraps to width and keeps every word.
        \\const wrapped = renderRows("alpha bravo charlie delta", 11);
        \\check("wrap", wrapped.length > 1);
        \\
        \\// An unclosed fence stays provisional code and is never cached.
        \\{
        \\  const doc = new Document();
        \\  doc.setText("# H\n\n```\nx=1");
        \\  check("open-fence", has(doc.rows(80), "MdCodeBlock", "x=1"));
        \\  doc.setText("# H\n\n```\nx=2");
        \\  check("open-tail-refreshes", has(doc.rows(80), "MdCodeBlock", "x=2"));
        \\}
        \\
        \\// A finalized block keeps its cache entry when the open tail grows.
        \\{
        \\  const doc = new Document();
        \\  doc.setText("# H\n\npara one");
        \\  doc.rows(80);
        \\  doc.setText("# H\n\npara one two");
        \\  const rows = doc.rows(80);
        \\  check("append-heading", has(rows, "MdHeading", "H"));
        \\  check("append-tail", rows.some((r) => r.segments.some((s) => s.text.indexOf("two") >= 0)));
        \\}
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "md.js");
    try expectJs(host, "ok");
}

test "yuke:md an appended stream parses like a fresh document" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { Document } from "yuke:md";
        \\// Every block kind, with lookahead cases: a setext heading, a table, and a fence that closes late.
        \\const text = "Intro para\nsecond line\n\n# Head\n\nSetext\n===\n\n- one\n- two\n\n1. first\n2. second\n\n> quoted\n> more\n\n" +
        \\  "a | b\n---|---\n1 | 2\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n---\n\nlast **bold** para\nwith a|pipe\n---|---\nx|y\n";
        \\const stream = new Document();
        \\const fails = [];
        \\for (let n = 1; n <= text.length; n++) {
        \\  const head = text.slice(0, n);
        \\  stream.setText(head);
        \\  const fresh = new Document();
        \\  fresh.setText(head);
        \\  const same = JSON.stringify(stream.blocks()) === JSON.stringify(fresh.blocks()) &&
        \\    JSON.stringify(stream.rows(24)) === JSON.stringify(fresh.rows(24)) &&
        \\    JSON.stringify(stream.codeBlocks()) === JSON.stringify(fresh.codeBlocks());
        \\  if (!same) fails.push(n);
        \\}
        \\// A rewrite that is not an append parses from the start again.
        \\stream.setText("changed\n\n" + text);
        \\const fresh = new Document();
        \\fresh.setText("changed\n\n" + text);
        \\if (JSON.stringify(stream.rows(24)) !== JSON.stringify(fresh.rows(24))) fails.push("rewrite");
        \\globalThis.result = fails.length ? "differs at " + fails.join(",") : "ok";
    , "md-stream.js");
    try expectJs(host, "ok");
}

test "yuke:md maps a rendered row back to its markdown source" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { renderRows, Document } from "yuke:md";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const segsOf = (rows) => { const out = []; for (const r of rows) for (const s of r.segments) out.push(s); return out; };
        \\const find = (rows, group, text) => segsOf(rows).find((s) => s.group === group && s.text === text);
        \\
        \\// Every span stays inside the source and holds the text it rendered. A mark hides its markup,
        \\// so it is the one segment whose span does not contain the text.
        \\const mapsBack = (src, rows) => {
        \\  for (const s of segsOf(rows)) {
        \\    if (s.src == null) continue;
        \\    if (s.src < 0 || s.srcEnd <= s.src || s.srcEnd > src.length) return false;
        \\    if (s.mark) continue;
        \\    const span = src.slice(s.src, s.srcEnd);
        \\    // A linear segment is its own source. An escape is the same text behind a backslash.
        \\    if (span !== s.text && span.split("\\").join("") !== s.text) return false;
        \\  }
        \\  return true;
        \\};
        \\const corpus = [
        \\  "hello **bold** and `code`",
        \\  "# Title\n\npara one\npara two",
        \\  "> one\n> two",
        \\  "- alpha\n- bravo",
        \\  "1. one\n2. two",
        \\  "| a | b |\n|---|---|\n| 1 | 2 |",
        \\  "| a\\|b | c |\n|---|---|\n| 1 | 2 |",
        \\  "```js\nlet x = 1;\n```",
        \\  "not \\*bold\\* here",
        \\  "see [docs](http://x) ok",
        \\  "***wow*** and *x **y** z*",
        \\  "---",
        \\  "Setext\n======",
        \\];
        \\for (const src of corpus) {
        \\  const doc = new Document();
        \\  doc.setText(src);
        \\  for (const w of [80, 24, 7]) check("maps-back:" + w + ":" + src.slice(0, 8), mapsBack(src, doc.rows(w)));
        \\}
        \\
        \\// A rendered word maps to the word, and a span still holds the markup between its ends.
        \\{
        \\  const src = "hello **bold** and `code`";
        \\  const rows = renderRows(src, 80);
        \\  const b = find(rows, "MdStrong", "bold");
        \\  const c = find(rows, "MdCode", "code");
        \\  check("strong-src", b && src.slice(b.src, b.srcEnd) === "bold");
        \\  check("code-src", c && src.slice(c.src, c.srcEnd) === "code");
        \\  check("span-keeps-markup", b && c && src.slice(b.src, c.srcEnd) === "bold** and `code");
        \\}
        \\
        \\// An escape renders one character over two, so it keeps the whole markup.
        \\{
        \\  const src = "a \\*b\\* c";
        \\  const star = segsOf(renderRows(src, 80)).find((s) => s.text === "*");
        \\  check("escape-atomic", star && star.srcEnd - star.src === 2 && src.slice(star.src, star.srcEnd) === "\\*");
        \\}
        \\
        \\{
        \\  const src = "alpha bravo charlie delta";
        \\  const rows = renderRows(src, 12);
        \\  const d = find(rows, "MdText", "delta");
        \\  check("wrap-rows", rows.length > 1);
        \\  check("wrap-src", d && d.src === src.indexOf("delta"));
        \\}
        \\
        \\// A paragraph joins its lines with one space, so the second line keeps its offsets.
        \\{
        \\  const src = "one two\nthree four";
        \\  const t = find(renderRows(src, 80), "MdText", "three");
        \\  check("para-line-2", t && t.src === src.indexOf("three"));
        \\}
        \\
        \\// A quote drops the "> " of each line, so a segment splits at the line edge.
        \\{
        \\  const src = "> one\n> two";
        \\  const rows = renderRows(src, 80);
        \\  const t = find(rows, "MdQuote", "two");
        \\  const bar = find(rows, "MdQuote", "▏ ");
        \\  const flat = rows.map((r) => r.segments.map((g) => g.text).join("")).join("");
        \\  // A soft line break is a word gap, so no row ever holds a line feed.
        \\  check("quote-one-line", flat === "▏ one two");
        \\  check("quote-line-2", t && t.src === src.indexOf("two"));
        \\  check("quote-bar", bar && src.slice(bar.src, bar.srcEnd) === "> ");
        \\}
        \\
        \\// A list marker takes the span of the source marker.
        \\{
        \\  const src = "- alpha\n- bravo";
        \\  const rows = renderRows(src, 80);
        \\  const b = find(rows, "MdText", "bravo");
        \\  const mark = segsOf(rows).find((s) => s.group === "MdListMark" && s.src === src.indexOf("- bravo"));
        \\  check("list-item", b && b.src === src.indexOf("bravo"));
        \\  check("list-mark", mark && src.slice(mark.src, mark.srcEnd) === "- ");
        \\}
        \\
        \\check("fence-src", (() => {
        \\  const src = "```js\nlet x = 1;\n```";
        \\  const c = find(renderRows(src, 80), "MdCodeBlock", "let x = 1;");
        \\  return c && src.slice(c.src, c.srcEnd) === "let x = 1;";
        \\})());
        \\check("hr-src", (() => {
        \\  const r = renderRows("---", 10)[0].segments[0];
        \\  return r.src === 0 && r.srcEnd === 3;
        \\})());
        \\
        \\// An escaped pipe renders as one character and keeps the whole markup, like any escape.
        \\{
        \\  const src = "| a\\|b | c |\n|---|---|\n| 1 | 2 |";
        \\  const rows = renderRows(src, 80);
        \\  const one = find(rows, "MdText", "1");
        \\  const pipe = segsOf(rows).find((s) => s.text === "|");
        \\  check("table-cell", one && one.src === src.indexOf("| 1 |") + 2);
        \\  check("table-escape", pipe && src.slice(pipe.src, pipe.srcEnd) === "\\|");
        \\}
        \\
        \\// A closer consumes its run from the start, so the leftover marker keeps the true offset.
        \\{
        \\  const src = "**x***";
        \\  const star = segsOf(renderRows(src, 80)).find((s) => s.text === "*");
        \\  check("leftover-delim", star && star.src === 5);
        \\}
        \\
        \\// A hard break by grapheme keeps each piece on its own offset.
        \\{
        \\  const wide = segsOf(renderRows("日本語", 2)).filter((s) => s.src != null);
        \\  check("grapheme-rows", wide.length === 3);
        \\  check("grapheme-offsets", wide.every((s, k) => s.src === k && s.srcEnd === k + 1));
        \\  const src = "a𝄞b";
        \\  const astral = segsOf(renderRows(src, 1)).filter((s) => s.src != null);
        \\  check("astral-pieces", astral.length === 3);
        \\  check("astral-offsets", astral.every((s) => src.slice(s.src, s.srcEnd) === s.text));
        \\}
        \\
        \\// Two blocks can hold the same text, so the second one keeps its own source position.
        \\{
        \\  const src = "hi\n\nbye\n\nhi\n\nend";
        \\  const doc = new Document();
        \\  doc.setText(src);
        \\  const his = segsOf(doc.rows(80)).filter((s) => s.text === "hi");
        \\  check("dup-blocks", his.length === 2 && his[0].src === 0 && his[1].src === src.lastIndexOf("hi"));
        \\}
        \\
        \\{
        \\  const doc = new Document();
        \\  doc.setText("# H\n\npara one");
        \\  doc.rows(80);
        \\  doc.setText("# H\n\npara one two");
        \\  const h = find(doc.rows(80), "MdHeading", "H");
        \\  check("stream-offsets", h && h.src === 2);
        \\}
        \\
        \\// The offsets index the normalized text, so a CRLF source reads through sourceText.
        \\{
        \\  const doc = new Document();
        \\  doc.setText("one two\r\nthree");
        \\  const t = find(doc.rows(80), "MdText", "three");
        \\  check("crlf-src", t && doc.sourceText().slice(t.src, t.srcEnd) === "three");
        \\}
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "mdsrc.js");
    try expectJs(host, "ok");
}

test "yuke:ui a selection maps back to the markdown source" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript, rowText } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });
        \\
        \\const body = { u1: "plain user text", a1: "hello **bold** and `code`", a2: "- alpha" };
        \\const t = new Transcript({ textOf: (id) => body[id] || "" });
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }, { id: "a2", type: "assistant" }], null);
        \\term.beginFrame();
        \\t.draw({ x: 0, y: 0, w: 40, h: 12 });
        \\term.endFrame();
        \\
        \\// Take the columns from the drawn rows, so the test does not depend on the layout.
        \\const rows = t.rows(40, 0, 12);
        \\const colOf = (row, s) => (rows[row].indent || 0) + rowText(rows[row]).indexOf(s);
        \\const endOf = (row) => (rows[row].indent || 0) + rowText(rows[row]).length;
        \\
        \\check("no-selection", t.selectedSource() === "");
        \\
        \\// Row 2 is the assistant paragraph, past the user turn and its blank row.
        \\t.onMouse(at(colOf(2, "bold"), 2, "press"));
        \\t.onMouse(at(endOf(2), 2, "drag"));
        \\check("rendered-text", t.selectedText() === "bold and code");
        \\// The copy keeps the rendered text; the source keeps the markup between the two ends.
        \\check("source-text", t.selectedSource() === "bold** and `code");
        \\
        \\// One word inside a code span maps to that word, not to the backticks.
        \\t.onMouse(at(colOf(2, "code"), 2, "press"));
        \\t.onMouse(at(endOf(2), 2, "drag"));
        \\check("inside-code", t.selectedText() === "code" && t.selectedSource() === "code");
        \\
        \\// A bullet hides its markup, so one character of it still maps to the whole marker.
        \\t.onMouse(at(colOf(4, "•"), 4, "press"));
        \\t.onMouse(at(colOf(4, "•") + 1, 4, "drag"));
        \\check("mark-whole", t.selectedText() === "•" && t.selectedSource() === "- ");
        \\
        \\// A user turn is plain text, so its source is what it renders.
        \\t.onMouse(at(colOf(0, "plain"), 0, "press"));
        \\t.onMouse(at(colOf(0, "plain") + 5, 0, "drag"));
        \\check("user-plain", t.selectedText() === "plain" && t.selectedSource() === "plain");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "selsrc.js");
    try expectJs(host, "ok");
}

test "yuke:ui List itemHeight, fzy ranking, and Transcript rows" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { List } from "yuke:ui";
        \\import { Transcript } from "yuke:transcript";
        \\import { fuzzyMatch, fuzzyRank } from "yuke:fzy";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// A two-line list shows floor(h / itemHeight) items and scrolls in item units.
        \\const l = new List({ items: [0, 1, 2, 3, 4, 5], itemHeight: 2 });
        \\l.moveToEdge(1);
        \\check("sel-end", l.selectedIndex() === 5);
        \\l.ensureVisible(6);
        \\check("scroll-bottom", l.scroll === 3);
        \\l.moveToEdge(-1);
        \\l.ensureVisible(6);
        \\check("scroll-top", l.scroll === 0 && l.selectedIndex() === 0);
        \\
        \\// fzy requires a subsequence and prefers a word boundary.
        \\check("nomatch", fuzzyMatch("abc", "xyz") === null);
        \\check("empty", fuzzyMatch("abc", "") === 0);
        \\const ranked = fuzzyRank(["afboo", "foo_bar", "random"], "fb", String);
        \\check("boundary-first", ranked[0] === "foo_bar");
        \\const dog = fuzzyRank(["cat", "dog"], "og", String);
        \\check("subsequence", dog.length === 1 && dog[0] === "dog");
        \\check("over-long-cap", fuzzyMatch("a".repeat(1025), "a") === -Infinity);
        \\
        \\// A user turn is a tinted band with a gutter marker; an assistant turn renders markdown.
        \\const texts = { u1: "hello world", a1: "**bold** text" };
        \\const t = new Transcript({ textOf: (id) => texts[id] || "" });
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], null);
        \\const rows = t.rows(40, 0, 100);
        \\check("user-band", rows.some((r) => r.marker === "⟩" && r.bg === "TxUser"));
        \\check("assistant-md", rows.some((r) => r.segments && r.segments.some((s) => s.group === "MdStrong" && s.text === "bold")));
        \\
        \\// A draft delta re-renders the assistant turn through yuke:md.
        \\texts.a2 = "streamed";
        \\t.setActive("a2");
        \\const rows2 = t.rows(40, 0, 100);
        \\check("draft", rows2.some((r) => r.segments && r.segments.some((s) => s.text.indexOf("streamed") >= 0)));
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "ui.js");
    try expectJs(host, "ok");
}

test "yuke:ui Composer grows, pastes in one edit, and owns the vertical keys" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { Composer } from "yuke:ui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, extra) => Object.assign({ type: "key", code, char: "", text: "", mods: 0 }, extra);
        \\const paste = (t) => ({ type: "paste", text: t });
        \\
        \\// The prompt takes two cells, so a width of 12 wraps the text at 10.
        \\const c = new Composer({ onSubmit: () => true });
        \\c.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\check("empty-one-row", c.height(12) === 1);
        \\
        \\// One paste is one edit, and the text keeps its newline.
        \\check("paste-taken", c.onKey(paste("hello world\nsecond")) === true);
        \\check("paste-text", c.text === "hello world\nsecond");
        \\check("paste-caret", c.input.caret === c.text.length);
        \\check("grew", c.height(12) === 3);
        \\
        \\// A newline key adds a line. Enter still submits.
        \\c.onKey(key("enter", { mods: 2 }));
        \\check("alt-enter", c.text === "hello world\nsecond\n");
        \\check("grew-again", c.height(12) === 4);
        \\
        \\// The composer never returns false for a vertical key, so the transcript never scrolls.
        \\c.input.caret = c.text.length;
        \\check("up-taken", c.onKey(key("up")) === true);
        \\check("up-moved", c.input.caret < c.text.length);
        \\const mid = c.input.caret;
        \\check("down-taken", c.onKey(key("down")) === true);
        \\check("down-moved", c.input.caret !== mid);
        \\c.input.caret = 0;
        \\c.onKey(key("up"));
        \\check("up-at-top", c.input.caret === 0);
        \\
        \\// The height stops at maxRows for text the user typed.
        \\const big = new Composer();
        \\big.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\big.text = "a\n".repeat(20);
        \\check("capped", big.height(12) === big.maxRows);
        \\
        \\// Submit clears the buffer, so the composer shrinks back to one row.
        \\const sent = [];
        \\const s = new Composer({ onSubmit: (t) => { sent.push(t); } });
        \\s.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\s.onKey(paste("one\ntwo"));
        \\s.onKey(key("enter"));
        \\check("submitted", sent.length === 1 && sent[0] === "one\ntwo");
        \\check("cleared", s.text === "" && s.height(12) === 1);
        \\
        \\// setText fires onChange, so a programmatic set never leaves a stale wrap.
        \\s.text = "a\nb\nc";
        \\check("set-text-rewrapped", s.height(12) === 3);
        \\
        \\// A vertical move holds the goal column across a short row.
        \\const goal = new Composer();
        \\goal.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\goal.text = "12345\nx\n12345";
        \\goal.input.caret = 5;
        \\goal.onKey(key("down"));
        \\check("goal-short-row", goal.input.caret === 7);
        \\goal.onKey(key("down"));
        \\check("goal-restored", goal.input.caret === 13);
        \\// A horizontal key drops the goal column.
        \\goal.input.caret = 5;
        \\goal.onKey(key("down"));
        \\goal.onKey(key("left"));
        \\goal.onKey(key("down"));
        \\check("goal-dropped", goal.input.caret === 8);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "composer.js");
    try expectJs(host, "ok");
}

test "yuke:ui Transcript draws markdown segments through the pager" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 6, 24);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript, ChatView } from "yuke:transcript";
        \\const t = new Transcript({ textOf: () => "**hi** there" });
        \\t.setOutline([{ id: "a1", type: "assistant" }], null);
        \\term.beginFrame();
        \\t.draw({ x: 0, y: 0, w: 24, h: 6 });
        \\term.endFrame();
        \\// The pane takes its status line from the caller, so the kit holds no app state.
        \\const v = new ChatView({ textOf: () => "body" });
        \\v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
        \\v.rect = { x: 0, y: 0, w: 24, h: 6 };
        \\term.beginFrame();
        \\v.draw(true);
        \\term.endFrame();
    , "draw.js");
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "there") != null);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "─") != null);
}

test "yuke:ui Composer collapses a large paste and still submits the whole text" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { Composer } from "yuke:ui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, extra) => Object.assign({ type: "key", code, char: "", text: "", mods: 0 }, extra);
        \\const paste = (t) => ({ type: "paste", text: t });
        \\const big = "one\ntwo\nthree\nfour";
        \\
        \\const sent = [];
        \\const c = new Composer({ onSubmit: (t) => { sent.push(t); } });
        \\c.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\
        \\// The text keeps the paste. Only the screen shows a label.
        \\c.onKey(paste(big));
        \\check("text-whole", c.text === big);
        \\check("one-span", c.spans.length === 1);
        \\check("label", c._projection().text === "[Pasted text #1 +4 lines]");
        \\check("one-row", c.height(40) === 1);
        \\
        \\// A short paste stays plain text.
        \\c.onKey(paste("tail"));
        \\check("short-plain", c.spans.length === 1 && c.text === big + "tail");
        \\
        \\// The submit sends the paste and never the label.
        \\c.onKey(key("enter"));
        \\check("submitted-whole", sent.length === 1 && sent[0] === big + "tail");
        \\check("spans-cleared", c.spans.length === 0 && c.text === "");
        \\
        \\// A one-line paste over the character threshold counts characters.
        \\const line = new Composer();
        \\line.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\line.onKey(paste("z".repeat(200)));
        \\check("chars-label", line._projection().text === "[Pasted text #1 +200 chars]");
        \\
        \\// A newline at the end closes the last line, so a four-line paste is not five.
        \\const nl = new Composer();
        \\nl.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\nl.onKey(paste("one\ntwo\nthree\nfour\n"));
        \\check("trailing-newline", nl._projection().text === "[Pasted text #1 +4 lines]");
        \\
        \\// Backspace at the end drops the whole block, and the numbering keeps counting up.
        \\const del = new Composer();
        \\del.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\del.onKey(paste(big));
        \\del.onKey(key("backspace"));
        \\check("atomic-delete", del.text === "" && del.spans.length === 0);
        \\del.onKey(paste(big));
        \\check("id-not-reused", del._projection().text === "[Pasted text #2 +4 lines]");
        \\
        \\// The caret steps over a span instead of into it.
        \\const step = new Composer();
        \\step.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\step.onKey(paste(big));
        \\step.onKey(key("left"));
        \\check("step-over", step.input.caret === 0);
        \\step.onKey(key("right"));
        \\check("step-back", step.input.caret === big.length);
        \\
        \\// The same paste beside its label expands it. Elsewhere it makes a second block.
        \\const again = new Composer();
        \\again.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\again.onKey(paste(big));
        \\again.onKey(paste(big));
        \\check("expanded", again.spans.length === 0 && again.text === big);
        \\const two = new Composer();
        \\two.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\two.text = "hi";
        \\two.onKey(paste(big));
        \\two.input.caret = 0; // away from the span, which now starts at 2
        \\two.onKey(paste(big));
        \\check("second-block", two.spans.length === 2 && two.text === big + "hi" + big);
        \\
        \\// ctrl+w at the end drops the whole block instead of a word inside the paste.
        \\const word = new Composer();
        \\word.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\word.onKey(paste("alpha beta\ngamma delta\nepsilon zeta"));
        \\word.onKey(key("w", { char: "w", text: "w", mods: 4 }));
        \\check("ctrl-w-atomic", word.text === "" && word.spans.length === 0);
        \\
        \\// The content decides which side expands, so a different span on the left cannot block it.
        \\const side = new Composer();
        \\side.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\const other = "aaa\nbbb\nccc";
        \\side.onKey(paste(other));
        \\side.onKey(paste(big));
        \\side.input.caret = other.length; // between the two labels
        \\side.onKey(paste(big));
        \\check("right-side-expands", side.spans.length === 1 && side.spans[0].end === other.length);
        \\
        \\// An edit that reaches into a span drops the label and shows the paste.
        \\const cut = new Composer();
        \\cut.rect = { x: 0, y: 0, w: 40, h: 6 };
        \\cut.onKey(paste(big));
        \\cut.onKey(key("u", { char: "u", text: "u", mods: 4 }));
        \\check("edit-detaches", cut.spans.length === 0 && cut.text === "");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "paste.js");
    try expectJs(host, "ok");
}

test "yuke:ui Composer draws a wrapped row whole and puts the caret on it" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 4, 7);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    // The prompt takes two cells of the seven, so "hello world" wraps at five.
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Composer } from "yuke:ui";
        \\const c = new Composer();
        \\c.rect = { x: 0, y: 0, w: 7, h: 2 };
        \\c.text = "hello world";
        \\term.beginFrame();
        \\c.draw(true);
        \\const cur = c.cursor();
        \\term.endFrame();
        \\globalThis.result = cur.x === 2 + 5 - 1 && cur.y === 1 && cur.visible ? "ok" : "x=" + cur.x + " y=" + cur.y;
    , "composer_draw.js");

    // The hanging space must not turn the row into an ellipsis.
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "…") == null);

    try expectJs(host, "ok");
}

test "yuke:client exposes the engine surface and answers a closed session" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\const surface = ["request", "sessionList", "sessionOpen", "sessionClose",
        \\  "sessionOutline", "sessionText", "sessionTextPage", "sessionParts", "sessionPart", "partTextPage",
        \\  "sessionSendInput", "sessionCancelRun", "sessionCreate", "catalogList", "catalogReload",
        \\  "authList", "authLogin", "authCancelLogin", "authSetApiKey", "authRemove"]
        \\  .every((k) => typeof client[k] === "function");
        \\// No engine is attached in a unit test, so a view read answers its empty projection.
        \\const closed = client.sessionOutline("00".repeat(16)) === null;
        \\globalThis.result = surface && closed ? "ok" : "fail";
    , "c.js");
    try expectJs(host, "ok");
}

test "yuke:defaults boots the shell, seeds the session feed, and wires commands" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 24, 80);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    paint.bind(host);

    // The frontend boot provides the terminal capability, so the test boots the same way.
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import "yuke:core";
        \\import "yuke:defaults";
        \\plugins.use(tuiPlugin);
    , "boot.js");

    const loop = @import("loop.zig");
    // No engine is attached here, so boot renders the empty chat and its hint.
    try loop.start(host);
    try loop.stepTick(host);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "new chat") != null);

    // the command registry and the vim toggle are wired.
    try host.evalModule(
        \\import { command, root, status, keymap } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { term } from "yuke:term";
        \\import { chat } from "yuke:defaults";
        \\import { chats, chatOf } from "yuke:chat";
        \\import { feedOf } from "yuke:sessions";
        \\const fail = [];
        \\// The shell loads the notice as a plugin, so its segment and listeners can be taken back out.
        \\if (!plugins.get("notice")) fail.push("notice-plugin");
        \\if (!plugins.get("command-ui")) fail.push("command-ui-plugin");
        \\if (!plugins.get("catalog")) fail.push("catalog-plugin");
        \\if (!plugins.get("chat")) fail.push("chat-plugin");
        \\if (!plugins.get("explorer")) fail.push("explorer-plugin");
        \\if (!command.available("catalog:reload")) fail.push("catalog-reload-command");
        \\
        \\
        \\// The status bar reports a pending key.
        \\{
        \\  root.focusView(chat.view);
        \\  // A `g` prefix only arms outside the composer, so the transcript takes the focus first.
        \\  chat.view.focus = "transcript";
        \\  const g = { type: "key", code: "char", char: "g", text: "g", event: "press", mods: 0 };
        \\  const beforeG = status.side("right");
        \\  root.onEvent(g);
        \\  if (keymap.pendingLabel() !== "g") fail.push("showcmd-armed");
        \\  if (status.side("right") === beforeG) fail.push("showcmd-on");
        \\  root.onEvent(g);
        \\  if (keymap.pendingLabel() !== "") fail.push("showcmd-off");
        \\  chat.view.focus = "composer";
        \\  root.focusView(chat.view);
        \\}
        \\// Tab moves the region focus with no vim plugin loaded.
        \\{
        \\  const tab = { type: "key", code: "tab", char: "", text: "", event: "press", mods: 0 };
        \\  if (chat.view.focus !== "composer") fail.push("boot-region");
        \\  root.onEvent(tab);
        \\  if (chat.view.focus !== "transcript") fail.push("tab-to-transcript");
        \\  root.onEvent(tab);
        \\  if (chat.view.focus !== "composer") fail.push("tab-back");
        \\}
        \\command.perform("ui:palette");
        \\if (root.overlays.length !== 1) fail.push("palette");
        \\root.popOverlay();
        \\// PageUp scrolls the history while the composer types, through the nav binding.
        \\{
        \\  root.focusView(chat.view);
        \\  if (root.navTarget() !== chat.transcript.pager) fail.push("chat-nav-target");
        \\  let paged = 0;
        \\  const realPage = chat.transcript.pager.navPage.bind(chat.transcript.pager);
        \\  chat.transcript.pager.navPage = (d) => { paged = d; return realPage(d); };
        \\  root.onEvent({ type: "key", code: "page_up", char: "", text: "", event: "press", mods: 0 });
        \\  if (paged !== -1) fail.push("pageup-while-typing");
        \\  chat.transcript.pager.navPage = realPage;
        \\}
        \\
        \\// The catalog readings must come through the shell's own wiring, not a test's own callbacks.
        \\{
        \\  const feed = feedOf();
        \\  feed.seed({ items: [{ session: { id: "probe", model: "wired-model", updated_at_ms: 1 }, activity: { context_usage: { input: 2500 } } }] });
        \\  chat.sessionId = "probe";
        \\  const right = status.side("right");
        \\  if (right.indexOf("wired-model") < 0) fail.push("catalog-entry-wired");
        \\  if (right.indexOf("2.5k ctx") < 0) fail.push("catalog-usage-wired");
        \\
        \\  // Closing the session clears the reading, so the status does not name a gone session.
        \\  chat.sessionGone();
        \\  chat.sessionId = null;
        \\  feed.clear();
        \\  if (status.side("right").indexOf("wired-model") >= 0) fail.push("catalog-entry-clears");
        \\}
        \\
        \\
        \\// The split command builds a real chat pane, and a tree with no leaf keeps no orphan.
        \\{
        \\  const before = chats.size;
        \\  command.perform("window:split-right");
        \\  if (chats.size !== before + 1) fail.push("split-makes-a-chat");
        \\  if (chatOf(root.active) == null) fail.push("split-focuses-the-new-chat");
        \\  command.perform("window:close");
        \\  if (chats.size !== before) fail.push("close-releases-the-chat");
        \\  const saved = root.root_node;
        \\  root.setRoot(null);
        \\  const empty = chats.size;
        \\  command.perform("window:split-right");
        \\  if (chats.size !== empty) fail.push("failed-split-keeps-no-orphan");
        \\  root.setRoot(saved);
        \\}
        \\// The shell's own plugin owns the pending-key reading, so an unload takes it away.
        \\{
        \\  root.focusView(chat.view);
        \\  // A test-owned prefix outlives the shell's bindings, so the pending stroke survives disposal.
        \\  const offPrefix = keymap.add({ "f9 x": () => true });
        \\  const f9 = { type: "key", code: "f9", char: "", text: "", event: "press", mods: 0 };
        \\  root.onEvent(f9);
        \\  if (status.side("right").indexOf("f9") < 0) fail.push("showcmd-drawn");
        \\  keymap.pending = null;
        \\  plugins.dispose("app-keys");
        \\  root.onEvent(f9);
        \\  if (keymap.pendingLabel() !== "f9") fail.push("showcmd-still-pending");
        \\  if (status.side("right").indexOf("f9") >= 0) fail.push("showcmd-unloads");
        \\  keymap.pending = null;
        \\  offPrefix();
        \\  root.focusView(chat.view);
        \\}
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "act.js");
    try expectJs(host, "ok");
}

test "a style link cycle falls back instead of spinning" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { style } from "yuke:core";
        \\style.groups.Cycle = { link: "Pong" };
        \\style.groups.Pong = { link: "Cycle" };
        \\style.groups.Selfie = { link: "Selfie" };
        \\style.groups.Dangling = { link: "Missing" };
        \\style.invalidate();
        \\const normal = style.resolve("Normal");
        \\globalThis.result = (
        \\  style.resolve("Cycle").fg === normal.fg &&
        \\  style.resolve("Selfie").fg === normal.fg &&
        \\  style.resolve("Dangling").fg === normal.fg &&
        \\  style.resolve("YukeHeader").fg === "reset" &&
        \\  style.resolve("YukeHeader").dim === true
        \\) ? 1 : 0;
    , "cycle.js");
    try expectJsInt(host, 1);
}

test "an overlay without a hook is consumed, not a fault" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 2, 8);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    // The overlay implements `draw` and no other hook.
    try host.evalModule(
        \\import { View, root, text } from "yuke:core";
        \\globalThis.seen = 0;
        \\class Base extends View {
        \\  get name() { return "base"; }
        \\  draw() { text(0, 0, "b", "Normal"); }
        \\  onKey(ev) { globalThis.seen++; return true; }
        \\}
        \\root.setActive(new Base());
        \\root.pushOverlay({ draw() { text(0, 1, "o", "Normal"); } });
        \\globalThis.root = root;
    , "overlay.js");

    const loop = @import("loop.zig");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.seen"));

    try host.eval("globalThis.root.popOverlay();", "pop.js");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen"));
}

test "an unusable view or layer is rejected at the call" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { View, root } from "yuke:core";
        \\class Ok extends View { draw() {} }
        \\const reject = (fn, want) => {
        \\  try { fn(); } catch (e) {
        \\    if (e instanceof TypeError && e.message === want) globalThis.threw++;
        \\  }
        \\};
        \\globalThis.threw = 0;
        \\const view = "a view needs a draw method";
        \\const layer = "pushOverlay needs a layer with a draw method";
        \\for (const bad of [{}, { draw: 1 }]) reject(() => root.setActive(bad), view);
        \\root.setActive(new Ok());
        \\reject(() => root.split("row", {}), view);
        \\for (const bad of [null, {}, { draw: true }]) reject(() => root.pushOverlay(bad), layer);
        \\root.setActive(null);
        \\globalThis.cleared = root.active === null ? 1 : 0;
    , "reject.js");
    try std.testing.expectEqual(@as(i32, 6), try host.evalInt("globalThis.threw"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.cleared"));
}

test "a route sends an event to the keymap before the view" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 2, 8);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);
    const loop = @import("loop.zig");

    // The pane records a "V" when it reads, and the binding records a "K".
    try host.evalModule(
        \\import { View, root, keymap, route } from "yuke:core";
        \\globalThis.hits = "";
        \\class Pane extends View {
        \\  contexts() { return ["pane", "inner"]; }
        \\  draw() {}
        \\  onKey(ev) { globalThis.hits += "V"; return true; }
        \\}
        \\root.setActive(new Pane());
        \\keymap.add({ a: () => { globalThis.hits += "K"; } });
        \\globalThis.route = route;
        \\globalThis.d1 = null;
        \\globalThis.d2 = null;
    , "route.js");

    const press = struct {
        fn go(h: *Host) !void {
            try loop.step(h, .{ .key_press = .{ .codepoint = 'a' } });
            try h.eval("globalThis.result = globalThis.hits;", "r.js");
        }
    }.go;

    // With no route the view reads first, which is the behavior before a plugin loads.
    try press(host);
    try expectJs(host, "V");

    // A keymap route skips the view entirely.
    try host.eval("globalThis.d1 = globalThis.route.add(\"keymap\");", "a1.js");
    try press(host);
    try expectJs(host, "VK");

    // A deeper context outranks the unscoped route.
    try host.eval("globalThis.d2 = globalThis.route.add(\"view\", \"inner\");", "a2.js");
    try press(host);
    try expectJs(host, "VKV");

    // The disposer uncovers the route it hid.
    try host.eval("globalThis.d2();", "d2.js");
    try press(host);
    try expectJs(host, "VKVK");

    // Depth ranks over registration order, so the older deep route still wins.
    try host.eval(
        \\globalThis.d1();
        \\globalThis.d2 = globalThis.route.add("view", "inner");
        \\globalThis.d1 = globalThis.route.add("keymap");
    , "order.js");
    try press(host);
    try expectJs(host, "VKVKV");

    // A keymap route drops a paste, because no pane below it reads the event.
    try host.eval("globalThis.d2();", "d2b.js");
    try loop.stepPaste(host, "x");
    try host.eval("globalThis.result = globalThis.hits;", "r.js");
    try expectJs(host, "VKVKV");

    // With the route gone the paste reaches the view again.
    try host.eval("globalThis.d1();", "d1.js");
    try loop.stepPaste(host, "x");
    try host.eval("globalThis.result = globalThis.hits;", "r.js");
    try expectJs(host, "VKVKVV");

    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
}

test "route.add rejects a destination it cannot serve" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { route } from "yuke:core";
        \\globalThis.threw = 0;
        \\for (const bad of ["view ", "KEYMAP", "", null, 1]) {
        \\  try { route.add(bad); } catch (e) {
        \\    if (e.message === "route.add: where must be keymap or view") globalThis.threw++;
        \\  }
        \\}
        \\globalThis.result = String(globalThis.threw) + ":" + String(route.reader());
    , "reject.js");
    try expectJs(host, "5:view");
}

test "the composer route stays off while another pane has focus" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // `composer_vim` reads the mode from any chat, so only the `chat` atom can gate the route.
    try host.evalModule(
        \\import { root, Node, View } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { ChatView } from "yuke:transcript";
        \\import { composerVim, setComposerMode } from "yuke:composer-vim";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\let seen = 0;
        \\class Side extends View {
        \\  contexts() { return ["side"]; }
        \\  draw() {}
        \\  onKey(ev) { seen++; return true; }
        \\}
        \\const v = new ChatView({ textOf: () => "" });
        \\const side = new Side();
        \\root.setRoot(Node.branch("row", new Node(side), new Node(v), 0.3));
        \\root.focusView(v);
        \\const off = plugins.use(composerVim);
        \\const t = v.composer.input;
        \\const key = (ch) => ({ type: "key", code: "char", char: ch, text: ch, event: "press", mods: 0 });
        \\const press = (str) => { for (const ch of str) root.onEvent(key(ch)); };
        \\
        \\t.setText("abcd");
        \\setComposerMode(v.composer, "normal");
        \\// Put the caret on a character, because "x" past the last one deletes nothing.
        \\press("$");
        \\
        \\// The chat holds focus, so the route sends "x" to the binding and the composer edits.
        \\let before = t.text;
        \\press("x");
        \\check("chat-edits", t.text !== before);
        \\check("chat-keeps-side", seen === 0);
        \\
        \\// The side pane holds focus, so the route no longer matches and the pane reads the key.
        \\root.focusView(side);
        \\before = t.text;
        \\press("x");
        \\check("side-reads", seen === 1);
        \\check("side-leaves-composer", t.text === before);
        \\
        \\// Focus returns to the chat and the route matches again.
        \\root.focusView(v);
        \\before = t.text;
        \\press("x");
        \\check("chat-again", t.text !== before);
        \\check("side-untouched", seen === 1);
        \\
        \\off();
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "route-panes.js");
    try expectJs(host, "ok");
}

test "a pane focus and a terminal focus are separate events" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 4, 16);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);
    const loop = @import("loop.zig");

    // `focus.changed` is the terminal window and `pane.focused` is a leaf inside the layout.
    try host.evalModule(
        \\import { root, Node, View, events } from "yuke:core";
        \\class A extends View { get name() { return "a"; } draw() {} }
        \\class B extends View { get name() { return "b"; } draw() {} }
        \\const a = new A();
        \\const b = new B();
        \\root.setRoot(Node.branch("row", new Node(a), new Node(b), 0.5));
        \\root.focusView(a);
        \\globalThis.log = "";
        \\events.on("pane.focused", (v) => { globalThis.log += "P" + v.name; });
        \\events.on("focus.changed", (ev) => { globalThis.log += "T" + (ev.focused ? "1" : "0"); });
        \\globalThis.root = root;
        \\globalThis.a = a;
        \\globalThis.b = b;
    , "focus.js");

    // The terminal loses and regains focus, which moves no pane.
    try loop.step(host, .focus_in);
    try loop.step(host, .focus_out);
    try host.eval("globalThis.result = globalThis.log;", "r.js");
    try expectJs(host, "T1T0");

    // A pane focus reports the view that took it.
    try host.eval("globalThis.root.focusView(globalThis.b); globalThis.result = globalThis.log;", "b.js");
    try expectJs(host, "T1T0Pb");

    // The focused pane stays focused, so a repeat reports nothing.
    try host.eval("globalThis.root.focusView(globalThis.b); globalThis.result = globalThis.log;", "b2.js");
    try expectJs(host, "T1T0Pb");

    try host.eval("globalThis.root.focusView(globalThis.a); globalThis.result = globalThis.log;", "a.js");
    try expectJs(host, "T1T0PbPa");
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
}

test "the chat pane names the region that reads the keyboard" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { root, Node, context } from "yuke:core";
        \\import { ChatView } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: char || "", event: "press", mods: 0 });
        \\
        \\const v = new ChatView({ textOf: () => "" });
        \\root.setRoot(new Node(v));
        \\root.focusView(v);
        \\// Count where each key lands, which is the routing contract itself.
        \\let toC = 0;
        \\const rc = v.composer.onKey.bind(v.composer);
        \\v.composer.onKey = (ev) => { toC++; return rc(ev); };
        \\
        \\check("default-region", v.focus === "composer");
        \\// The region is an atom below `chat`, so a binding on it outranks one on the pane.
        \\check("stack-composer", context.stack().join(",") === "root,chat,composer");
        \\
        \\// The composer takes a printable key.
        \\v.onKey(key("char", "a"));
        \\check("printable-reaches-composer", toC === 1);
        \\
        \\// A key the composer declines leaves the pane, so a nav binding can scroll while you type.
        \\check("composer-decline-leaves-pane", v.onKey(key("page_up")) === false && toC === 2);
        \\
        \\// The pane offers the transcript pager whichever region reads the keyboard.
        \\check("nav-target", v.navTarget() === v.transcript.pager);
        \\
        \\// A focused transcript reads nothing here, because the keymap navigates it.
        \\v.focusRegion("transcript");
        \\check("stack-transcript", context.stack().join(",") === "root,chat,transcript");
        \\const before = v.composer.input.text;
        \\check("transcript-owns", v.onKey(key("char", "b")) === false && toC === 2);
        \\check("transcript-blocks-composer", v.composer.input.text === before);
        \\
        \\// The caret belongs to the focused region. A stub stands in for a laid-out composer.
        \\v.composer.cursor = () => ({ x: 1, y: 2, visible: true });
        \\check("caret-hidden", v.cursor() === null);
        \\v.focusRegion("composer");
        \\check("composer-caret-restored", (v.cursor() || {}).x === 1);
        \\
        \\// A pane focus returns the keyboard to the composer.
        \\v.focusRegion("transcript");
        \\v.onFocus();
        \\check("pane-focus-resets", v.focus === "composer");
        \\
        \\let threw = 0;
        \\try { v.focusRegion("sessions"); } catch (e) { if (e instanceof TypeError) threw = 1; }
        \\check("reject-region", threw === 1 && v.focus === "composer");
        \\
        \\// A new tree runs `onFocus`, so a remounted pane starts in the composer.
        \\v.focusRegion("transcript");
        \\root.setRoot(new Node(v));
        \\check("remount-resets", v.focus === "composer");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "region.js");
    try expectJs(host, "ok");
}

test "a focused transcript takes the keys even while the composer sits in normal mode" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 20, 24);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    // Both layers can be on at once. The region atom decides, so the load order cannot.
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { root, Node, keymap } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { ChatView } from "yuke:transcript";
        \\import { composerVim, setComposerMode, composerMode } from "yuke:composer-vim";
        \\import { transcriptVim } from "yuke:transcript-vim";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (char) => ({ type: "key", code: "char", char: char, text: char, event: "press", mods: 0 });
        \\const body = { a1: "alpha bravo charlie\nsecond line here\nthird line xx" };
        \\
        \\const run = (order) => {
        \\  const v = new ChatView({ textOf: (id) => body[id] || "" });
        \\  v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
        \\  root.setRoot(new Node(v));
        \\  root.focusView(v);
        \\  v.rect = { x: 0, y: 0, w: 24, h: 18 };
        \\  term.beginFrame(); v.draw(true); term.endFrame();
        \\  const offs = order === "composer-first"
        \\    ? [plugins.use(composerVim), plugins.use(transcriptVim)]
        \\    : [plugins.use(transcriptVim), plugins.use(composerVim)];
        \\  v.composer.input.setText("hello\nworld");
        \\  setComposerMode(v.composer, "normal");
        \\  v.focusRegion("transcript");
        \\  // The composer stays in normal mode, so both layers really are live.
        \\  const both = composerMode(v.composer) === "normal";
        \\  const c0 = v.cursor();
        \\  const caret0 = v.composer.input.caret;
        \\  root.onEvent(key("j"));
        \\  const movedTranscript = !!(v.cursor() && c0 && v.cursor().y !== c0.y);
        \\  const movedComposer = v.composer.input.caret !== caret0;
        \\  // An unscoped nav binding loses to the deeper vim context while the motion can still move.
        \\  root.onEvent(key("k"));
        \\  root.onEvent(key("k"));
        \\  let bare = 0;
        \\  const offBare = keymap.add({ j: () => { bare++; return true; } });
        \\  const yTop = v.cursor() ? v.cursor().y : -1;
        \\  root.onEvent(key("j"));
        \\  const bareLost = bare === 0 && !!v.cursor() && v.cursor().y !== yTop;
        \\  offBare();
        \\  // A composer binding must not fire at all while the transcript holds the region.
        \\  root.onEvent(key("i"));
        \\  const leaked = composerMode(v.composer) !== "normal";
        \\  // Back in the composer the same key belongs to the other layer again.
        \\  v.focusRegion("composer");
        \\  const caret1 = v.composer.input.caret;
        \\  root.onEvent(key("j"));
        \\  const composerBack = v.composer.input.caret !== caret1;
        \\  // Insert mode must still type, so no transcript binding may own the whole pane.
        \\  setComposerMode(v.composer, "insert");
        \\  const len0 = v.composer.input.text.length;
        \\  root.onEvent(key("h"));
        \\  const typed = v.composer.input.text.length === len0 + 1;
        \\  for (const o of offs) o();
        \\  if (!both) return "not-both";
        \\  if (!bareLost) return "unscoped-binding-won";
        \\  if (leaked) return "composer-leaked";
        \\  if (!typed) return "typing-broken";
        \\  if (!composerBack) return "composer-dead";
        \\  return movedTranscript && !movedComposer ? "transcript" : movedComposer ? "composer" : "neither";
        \\};
        \\
        \\for (const order of ["composer-first", "transcript-first"]) {
        \\  const got = run(order);
        \\  if (got !== "transcript") fail.push(order + "=" + got);
        \\}
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "both.js");
    try expectJs(host, "ok");
}

test "a slot lets a plugin answer for a widget it does not own" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { slot, events } from "yuke:core";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\class Base { label() { return slot.get(this, "label") ?? "base"; } }
        \\class Sub extends Base {}
        \\const b = new Base();
        \\const sub = new Sub();
        \\
        \\check("default", b.label() === "base");
        \\const d1 = slot.add(Base, "label", () => "one");
        \\check("supplied", b.label() === "one");
        \\// A subclass reads the slot its base class declares.
        \\check("subclass", sub.label() === "one");
        \\
        \\const d2 = slot.add(Base, "label", () => "two");
        \\check("newest-wins", b.label() === "two");
        \\
        \\// A null answer passes the slot on rather than claiming it.
        \\const d3 = slot.add(Base, "label", () => null);
        \\check("declines", b.label() === "two");
        \\d3();
        \\
        \\// A disposer uncovers the provider it hid.
        \\d2();
        \\check("uncovered", b.label() === "one");
        \\d1();
        \\check("restored", b.label() === "base");
        \\
        \\// The provider reads the instance, so one class can answer differently per object.
        \\const d4 = slot.add(Base, "label", (obj) => (obj === sub ? "sub" : null));
        \\check("per-instance", sub.label() === "sub" && b.label() === "base");
        \\d4();
        \\
        \\// A provider that disposes itself must not hide the provider behind it.
        \\const d7 = slot.add(Base, "label", () => "older");
        \\let d8;
        \\d8 = slot.add(Base, "label", () => { d8(); return null; });
        \\check("self-dispose-keeps-next", b.label() === "older");
        \\d7();
        \\
        \\// A subclass provider wins before a base provider, whatever the registration order.
        \\const dBase = slot.add(Base, "label", () => "from-base");
        \\const dSub = slot.add(Sub, "label", () => "from-sub");
        \\check("subclass-outranks-base", sub.label() === "from-sub" && b.label() === "from-base");
        \\dSub();
        \\check("subclass-falls-back", sub.label() === "from-base");
        \\dBase();
        \\
        \\// A throwing provider is reported and skipped, so the frame survives it.
        \\let errs = 0;
        \\const offErr = events.on("ext.error", () => { errs++; });
        \\const d5 = slot.add(Base, "label", () => { throw new Error("bad"); });
        \\const d6 = slot.add(Base, "label", () => null);
        \\check("throw-skipped", b.label() === "base" && errs === 1);
        \\d5();
        \\d6();
        \\offErr();
        \\
        \\// The last disposer leaves no registration behind.
        \\check("no-residue", !slot._map.has(Base.prototype) && !slot._map.has(Sub.prototype));
        \\
        \\let threw = 0;
        \\try { slot.add({}, "x", () => 1); } catch (e) { if (e instanceof TypeError) threw++; }
        \\try { slot.add(Base, "x", 1); } catch (e) { if (e instanceof TypeError) threw++; }
        \\check("reject", threw === 2 && b.label() === "base");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "slot.js");
    try expectJs(host, "ok");
}

test "composer-vim supplies the prompt glyph through the slot" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { root, Node } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { ChatView } from "yuke:transcript";
        \\import { composerVim, setComposerMode } from "yuke:composer-vim";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const v = new ChatView({ textOf: () => "" });
        \\root.setRoot(new Node(v));
        \\root.focusView(v);
        \\
        \\const own = v.composer._prompt();
        \\// The layer starts in normal mode, so the glyph changes as soon as it loads.
        \\const off = plugins.use(composerVim);
        \\check("normal-glyph", v.composer._prompt() === "▪ " && own !== "▪ ");
        \\setComposerMode(v.composer, "insert");
        \\check("insert-keeps-own", v.composer._prompt() === own);
        \\setComposerMode(v.composer, "normal");
        \\check("normal-again", v.composer._prompt() === "▪ ");
        \\
        \\// The unload removes the provider, so normal mode no longer changes the glyph.
        \\off();
        \\setComposerMode(v.composer, "normal");
        \\check("unload-restores", v.composer._prompt() === own);
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "prompt.js");
    try expectJs(host, "ok");
}

test "a modal picker reads the shared nav keys and seals the keymap" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The keys travel through the real dispatch, so the modal boundary is part of the test.
    try host.evalModule(
        \\import { root, keymap } from "yuke:core";
        \\import { ui } from "yuke:ui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: char || "", event: "press", mods: 0 });
        \\const { content, close } = ui.select(["a", "b", "c", "d", "e"], { format: (x) => ({ text: String(x) }) });
        \\const press = (code, char) => root.onEvent(key(code, char));
        \\const sel = () => content.list.selected();
        \\
        \\press("char", "j");
        \\check("picker-j", sel() === "b");
        \\press("down");
        \\check("picker-down", sel() === "c");
        \\press("char", "k");
        \\check("picker-k", sel() === "b");
        \\press("up");
        \\check("picker-up", sel() === "a");
        \\press("char", "G");
        \\check("picker-G", sel() === "e");
        \\press("home");
        \\check("picker-home", sel() === "a");
        \\press("end");
        \\check("picker-end", sel() === "e");
        \\
        \\// The paging keys came back with the shared table, so a modal pages like the app.
        \\press("ctrl+u");
        \\check("picker-ctrl-u", sel() !== "e");
        \\press("ctrl+d");
        \\check("picker-ctrl-d", sel() === "e");
        \\press("page_up");
        \\check("picker-page-up", sel() !== "e");
        \\press("page_down");
        \\check("picker-page-down", sel() === "e");
        \\
        \\// A menu keeps its source and its selection, so a plugin that calls the finder path cannot reorder it.
        \\press("char", "G");
        \\content.refilter();
        \\check("menu-refilter-keeps-selection", sel() === "e");
        \\content.setSource(["x", "y"]);
        \\check("menu-set-source", content.selected() === "x");
        \\check("menu-no-query", content.query === "");
        \\
        \\// A plugin may destructure the kit, so `select` must not depend on its receiver.
        \\const { select } = ui;
        \\const loose = select(["p", "q"], { format: x => ({ text: String(x) }) });
        \\check("detached-select", loose.content.selected() === "p");
        \\loose.close();
        \\
        \\// A menu edits no query, so the setter changes neither the text nor the rows.
        \\content.query = "zz";
        \\check("menu-query-setter", content.query === "" && content.selected() === "x");
        \\
        \\// A cancel always closes, in both modes, and `onCancel` only reports it.
        \\let told = 0;
        \\const deep = root.overlays.length;
        \\const menu = ui.select(["m"], { format: x => ({ text: String(x) }), onCancel: () => { told++; } });
        \\press("esc");
        \\check("menu-cancel-closes", root.overlays.length === deep && told === 1);
        \\const find = ui.pick({ items: ["f"], format: x => ({ text: String(x) }), onCancel: () => { told++; } });
        \\press("esc");
        \\check("finder-cancel-closes", root.overlays.length === deep && told === 2);
        \\
        \\// A modal layer seals the keymap, so an app binding cannot fire underneath it.
        \\let leaked = 0;
        \\const off = keymap.add({ f9: () => { leaked++; } });
        \\press("f9");
        \\check("modal-seals-keymap", leaked === 0);
        \\off();
        \\
        \\close();
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "picker.js");
    try expectJs(host, "ok");
}

test "a finder answers the whole picker contract" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { root } from "yuke:core";
        \\import { ui } from "yuke:ui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: char || "", event: "press", mods: 0 });
        \\const press = (code, char) => root.onEvent(key(code, char));
        \\const items = [{ id: "ay" }, { id: "bee" }, { id: "sea" }];
        \\
        \\// The chat model picker preselects the open model this way, so a finder must answer it.
        \\let taken = null;
        \\let at = -1;
        \\const p = ui.pick({
        \\  items,
        \\  key: it => it.id,
        \\  filterText: it => it.id,
        \\  format: it => ({ text: it.id }),
        \\  needsTick: { periodMs: 40 },
        \\  keymap: { "ctrl+g": "bottom" },
        \\  onAccept: (it, i) => { taken = it.id; at = i; },
        \\});
        \\check("selectKey", p.content.selectKey("sea") && p.content.selected().id === "sea");
        \\
        \\// `needsTick` reaches the window, so a finder that wants a timer gets one.
        \\const t = p.win.needsTick();
        \\check("needsTick", t !== null && t.periodMs === 40);
        \\
        \\// A string binding names a default action; only the shared class answers one.
        \\p.content.selectKey("ay");
        \\press("ctrl+g");
        \\check("string-action", p.content.selected().id === "sea");
        \\
        \\// The query still filters, so the finder half did not regress.
        \\press("char", "b");
        \\check("query", p.content.query === "b" && p.content.selected().id === "bee");
        \\
        \\// The accept carries the row index, and a pick that `onAccept` opens stays on top. The chat model step chains this way.
        \\const depth = root.overlays.length;
        \\let chained = null;
        \\p.content.onAccept = (it, i) => {
        \\  taken = it.id;
        \\  at = i;
        \\  chained = ui.pick({ items: [{ id: "level" }], key: x => x.id, format: x => ({ text: x.id }) });
        \\};
        \\press("enter");
        \\check("accepted", taken === "bee" && at === 0);
        \\check("chained-on-top", root.overlays.length === depth && root.overlays[root.overlays.length - 1] === chained.win);
        \\chained.close();
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "finder.js");
    try expectJs(host, "ok");
}

test "a tickable registered through a plugin leaves when the plugin unloads" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\// A service starts and stops only after the shell starts, the way `onStart` already worked.
        \\root.onEvent({ type: "start" });
        \\
        \\const log = [];
        \\const svc = { onStart() { log.push("start"); }, onStop() { log.push("stop"); } };
        \\const before = root.tickables.length;
        \\plugins.use({ name: "svc-test", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(svc); } });
        \\check("added", root.hasTickable(svc) && root.tickables.length === before + 1);
        \\check("started", log.join(",") === "start");
        \\plugins.dispose("svc-test");
        \\check("removed", !root.hasTickable(svc) && root.tickables.length === before);
        \\check("stopped", log.join(",") === "start,stop");
        \\
        \\// Two owners share one entry, so one unload cannot stop what the other still holds.
        \\log.length = 0;
        \\plugins.use({ name: "own-a", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(svc); } });
        \\plugins.use({ name: "own-b", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(svc); } });
        \\check("shared-starts-once", log.join(",") === "start");
        \\plugins.dispose("own-a");
        \\check("shared-holds", root.hasTickable(svc) && log.join(",") === "start");
        \\plugins.dispose("own-b");
        \\check("shared-stops-last", !root.hasTickable(svc) && log.join(",") === "start,stop");
        \\
        \\// A throwing `onStart` registers nothing, so a failed scope leaves no service behind.
        \\const bad = { onStart() { throw new Error("bad start"); } };
        \\let threw = 0;
        \\try { plugins.use({ name: "bad", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(bad); } }); } catch (e) { threw = 1; }
        \\check("bad-start-rejected", threw === 1 && !root.hasTickable(bad) && !plugins.get("bad"));
        \\
        \\// A throwing `onStop` still restores the tick state.
        \\let synced = 0;
        \\const realSync = root.syncTick.bind(root);
        \\root.syncTick = () => { synced++; return realSync(); };
        \\const noisy = { needsTick() { return { periodMs: 5 }; }, onStop() { throw new Error("bad stop"); } };
        \\root.addTickable(noisy);
        \\const s0 = synced;
        \\let stopThrew = 0;
        \\try { root.removeTickable(noisy); } catch (e) { stopThrew = 1; }
        \\check("bad-stop-syncs", stopThrew === 1 && !root.hasTickable(noisy) && synced > s0);
        \\root.syncTick = realSync;
        \\
        \\// A service that removes itself inside `needsTick` must not still receive `tick`.
        \\let ticks = 0;
        \\let armed = false;
        \\const selfRemove = {
        \\  needsTick() { if (armed) root.removeTickable(selfRemove); return { periodMs: 1 }; },
        \\  tick() { ticks++; },
        \\};
        \\root.addTickable(selfRemove);
        \\armed = true;
        \\root.tickLayers();
        \\check("self-remove-skips-tick", ticks === 0 && !root.hasTickable(selfRemove));
        \\
        \\// A repeated removal is safe, so a disposer can run twice.
        \\root.addTickable(svc);
        \\root.removeTickable(svc);
        \\root.removeTickable(svc);
        \\check("idempotent", !root.hasTickable(svc) && root.tickables.length === before);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "service.js");
    try expectJs(host, "ok");
}

test "a tickable removed during startup never starts" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // One `onStart` can remove a service the pass has not reached, so that service never starts.
    try host.evalModule(
        \\import { root } from "yuke:core";
        \\const log = [];
        \\const b = { onStart() { log.push("b-start"); }, onStop() { log.push("b-stop"); } };
        \\const a = { onStart() { log.push("a-start"); root.removeTickable(b); } };
        \\root.addTickable(a);
        \\root.addTickable(b);
        \\root.onEvent({ type: "start" });
        \\globalThis.result = log.join(",") + "|" + (root.hasTickable(b) ? "held" : "gone");
    , "startup.js");
    try expectJs(host, "a-start|gone");
}

test "the nav vocabulary cannot drift after the shell binds it" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The shell copies the table once and a modal reads it per key, so it must not be writable.
    try host.evalModule(
        \\import { NAV_KEYS } from "yuke:ui";
        \\let threw = 0;
        \\try { NAV_KEYS.j = () => {}; } catch (e) { if (e instanceof TypeError) threw++; }
        \\try { NAV_KEYS.zz = () => {}; } catch (e) { if (e instanceof TypeError) threw++; }
        \\try { delete NAV_KEYS.k; } catch (e) { if (e instanceof TypeError) threw++; }
        \\globalThis.result = String(threw) + ":" + (typeof NAV_KEYS.j) + ":" + (typeof NAV_KEYS.k);
    , "frozen.js");
    try expectJs(host, "3:function:function");
}

test "the notice plugin draws and listens only while it is loaded" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The message object outlives the plugin; only the registrations come and go.
    try host.evalModule(
        \\import { root, status, copy } from "yuke:core";
        \\import { term } from "yuke:term";
        \\import { plugins } from "yuke:ext";
        \\import { notice, noticePlugin } from "yuke:notice";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\term.copy = (x) => x.length;
        \\
        \\check("silent-before-load", status.side("left").indexOf("copied") < 0);
        \\plugins.use(noticePlugin);
        \\
        \\copy("hello", "reply");
        \\check("reports-a-copy", notice.text.indexOf("copied reply") === 0);
        \\check("draws-on-status", status.side("left").indexOf("copied reply") >= 0);
        \\copy("again", "source");
        \\check("reports-every-copy", notice.text.indexOf("copied source") === 0);
        \\
        \\// The next key press clears the message, so it never outstays its keystroke.
        \\root.onEvent({ type: "key", code: "char", char: "a", text: "a", event: "press", mods: 0 });
        \\check("clears-on-key", notice.text === "");
        \\
        \\// An unload takes the status segment and both listeners with it.
        \\notice.show("held");
        \\plugins.dispose("notice");
        \\check("unload-drops-segment", status.side("left").indexOf("held") < 0);
        \\copy("world", "reply");
        \\check("unload-stops-listening", notice.text === "held");
        \\root.onEvent({ type: "key", code: "char", char: "b", text: "b", event: "press", mods: 0 });
        \\check("unload-stops-clearing", notice.text === "held");
        \\
        \\// A reload starts clean, so it never shows the message the unload left behind.
        \\plugins.use(noticePlugin);
        \\check("reload-starts-clean", notice.text === "" && status.side("left").indexOf("held") < 0);
        \\
        \\// A key release must not clear a message a copy raised between press and release.
        \\copy("x", "reply");
        \\root.onEvent({ type: "key", code: "char", char: "c", text: "c", event: "release", mods: 0 });
        \\check("release-keeps-notice", notice.text.indexOf("copied reply") === 0);
        \\
        \\// The empty and oversize branches each report their own message.
        \\copy("", "reply");
        \\check("empty-copy", notice.text === "nothing to copy");
        \\term.copy = () => -1;
        \\copy("big", "reply");
        \\check("oversize-copy", notice.text.indexOf("too large to copy") === 0);
        \\term.copy = (x) => x.length;
        \\
        \\// Showing and clearing must each ask for a repaint, or the message never reaches the screen.
        \\notice.clear();
        \\root._needsDraw = false;
        \\notice.show("repaint me");
        \\check("show-repaints", root._needsDraw === true);
        \\root._needsDraw = false;
        \\notice.clear();
        \\check("clear-repaints", root._needsDraw === true);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "notice.js");
    try expectJs(host, "ok");
}

test "the session feed caches its derived reads until a change" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { events } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { sessionsPlugin, feedOf, newestLocalModelSession } from "yuke:sessions";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\plugins.use(sessionsPlugin, {});
        \\
        \\const feed = feedOf();
        \\const mk = (id, model, at) => ({ session: { id, model, reasoning: "", updated_at_ms: at }, activity: null });
        \\
        \\// The model status segment reads this on every frame, so it must be cached and correct.
        \\feed.clear();
        \\check("no-feed-no-model", newestLocalModelSession() === null);
        \\feed.seed({ items: [mk("a", "old-model", 100), mk("b", "", 900), mk("c", "new-model", 500)] });
        \\// "b" is newest but names no model, so the newest session that names one wins.
        \\check("newest-with-model", (newestLocalModelSession() || {}).id === "c");
        \\
        \\// The cache must stop the scan, not merely return the same answer.
        \\let scans = 0;
        \\const realValues = feed.items.values.bind(feed.items);
        \\feed.items.values = () => { scans++; return realValues(); };
        \\newestLocalModelSession();
        \\check("cache-avoids-scan", scans === 0);
        \\feed.seed({ items: [mk("d", "later-model", 1000)] });
        \\check("recomputes-after-change", (newestLocalModelSession() || {}).id === "d");
        \\check("rescans-after-change", scans === 1);
        \\feed.items.values = realValues;
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "sessions.js");
    try expectJs(host, "ok");
}

test "the command ui registers its palette as one plugin" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The slice owns the palette, so an unload takes the command, the key, and an open overlay.
    try host.evalModule(
        \\import { command, keymap, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { commandUiPlugin } from "yuke:command-ui";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\check("absent-before-load", !command.available("ui:palette"));
        \\
        \\plugins.use(commandUiPlugin);
        \\check("commands-registered", command.available("ui:palette"));
        \\// The binding must name the palette, not merely exist.
        \\check("key-bound", (keymap.describe("ctrl+p").winner || {}).binding === "ui:palette");
        \\
        \\const before = root.overlays.length;
        \\command.perform("ui:palette");
        \\check("palette-opens", root.overlays.length === before + 1);
        \\root.popOverlay();
        \\
        \\plugins.dispose("command-ui");
        \\check("unload-drops-commands", !command.available("ui:palette"));
        \\check("unload-drops-key", keymap.describe("ctrl+p").winner === null);
        \\
        \\// An unload must take this module's open overlays with it, or they keep taking keys.
        \\plugins.use(commandUiPlugin);
        \\command.perform("ui:palette");
        \\check("palette-open-again", root.overlays.length === before + 1);
        \\plugins.dispose("command-ui");
        \\check("unload-pops-overlay", root.overlays.length === before);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "cmdui.js");
    try expectJs(host, "ok");
}

test "the palette lists only the commands that carry metadata" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // A keymap target is not a user action, so the palette must skip it and sort the rest by title.
    try host.evalModule(
        \\import { command, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { commandUiPlugin } from "yuke:command-ui";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\plugins.use(commandUiPlugin);
        \\
        \\const off = command.add(null, { "test:shown": () => {}, "test:plumbing": () => {}, "test:first": () => {} }, {
        \\  "test:shown": { title: "Zed", description: "the last one" },
        \\  "test:first": { title: "Alpha", description: "the first one" },
        \\});
        \\const listed = command.list().map((c) => c.name);
        \\check("list-skips-plumbing", listed.indexOf("test:plumbing") < 0);
        \\check("list-sorts-by-title", listed.indexOf("test:first") < listed.indexOf("test:shown"));
        \\
        \\command.perform("ui:palette");
        \\const p = root.overlays[root.overlays.length - 1].content;
        \\check("palette-shows-meta", p.selectKey("test:shown") && p.selected().description === "the last one");
        \\check("palette-hides-plumbing", !p.selectKey("test:plumbing"));
        \\check("palette-hides-itself", !p.selectKey("ui:palette"));
        \\root.popOverlay();
        \\off();
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "meta.js");
    try expectJs(host, "ok");
}

test "the slash menu follows the composer, completes, runs, and leaves a message alone" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import "yuke:defaults";
        \\plugins.use(tuiPlugin);
    , "boot.js");
    // The float never takes the focus, and the rules for Tab, Enter, Escape, and a plain message all hold.
    try host.evalModule(
        \\import { command, root, keymap } from "yuke:core";
        \\import { ui } from "yuke:ui";
        \\import { Chat } from "yuke:chat";
        \\import { chat } from "yuke:defaults";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
        \\root.focusView(chat.view);
        \\chat.view.focus = "composer";
        \\const sent = [];
        \\chat.startChat = (text) => { sent.push(text); return true; };
        \\let ran = null;
        \\const off = command.add(null, { "test:echo": (arg) => { ran = arg === undefined ? "" : arg; } },
        \\  { "test:echo": { title: "Echo", description: "d", slash: "echo", args: true } });
        \\const rowsOf = () => root.overlays[0].content.list.items;
        \\
        \\chat.composer.text = "/";
        \\check("opens", root.overlays.length === 1 && root.overlays[0].modal === false);
        \\check("composer-keeps-focus", root.focused === chat.view);
        \\check("lists-slash-entries", rowsOf().length > 3 && rowsOf().every((e) => e.slash));
        \\chat.composer.text = "/ech";
        \\check("filters", rowsOf().length >= 1 && rowsOf()[0].slash === "echo");
        \\root.onEvent(key("tab"));
        \\check("tab-completes-with-space", chat.composer.text === "/echo ");
        \\check("space-closes", root.overlays.length === 0);
        \\chat.composer.text = "/ech";
        \\root.onEvent(key("enter"));
        \\check("enter-runs", ran === "" && chat.composer.text === "");
        \\check("enter-closes", root.overlays.length === 0);
        \\ran = null;
        \\chat.composer.text = "/ech";
        \\root.onEvent(key("esc"));
        \\check("esc-closes", root.overlays.length === 0 && chat.composer.text === "/ech");
        \\chat.composer.text = "/echo";
        \\check("edit-reopens", root.overlays.length === 1);
        \\root.onEvent(key("esc"));
        \\check("send-runs-known", chat.send("/echo hello world") === true && ran === "hello world");
        \\check("send-unknown-is-message", chat.send("/foo bar") === true && sent[sent.length - 1] === "/foo bar");
        \\check("double-slash-is-message", chat.send("//x") === true && sent[sent.length - 1] === "//x");
        \\check("path-is-message", chat.send("/tmp/x") === true && sent[sent.length - 1] === "/tmp/x");
        \\chat.composer.text = "/tmp/x";
        \\check("path-opens-nothing", root.overlays.length === 0);
        \\chat.composer.text = "/zzzz";
        \\check("no-match-opens-nothing", root.overlays.length === 0);
        \\chat.composer.text = "/ech";
        \\chat.view.focus = "transcript";
        \\chat.view.focusRegion("composer");
        \\chat.view.focusRegion("transcript");
        \\check("transcript-focus-closes", root.overlays.length === 0);
        \\chat.view.focusRegion("composer");
        \\chat.composer.text = "";
        \\// A dialog on top keeps the float shut, so a restored draft never opens a menu under it.
        \\const modal = ui.pick({ items: [] });
        \\chat.composer.text = "/ech";
        \\check("no-float-under-modal", root.overlays.length === 1 && root.overlays[0] === modal.win);
        \\root.popOverlay(modal.win);
        \\chat.composer.text = "";
        \\// Escape dismisses in one pane only, so the same text in another pane still opens its menu.
        \\chat.composer.text = "/ech";
        \\root.onEvent(key("esc"));
        \\const other = new Chat();
        \\root.split("row", other.view);
        \\root.focusView(other.view);
        \\other.view.focusRegion("composer");
        \\other.composer.text = "/ech";
        \\check("dismissal-is-per-pane", root.overlays.length === 1);
        \\other.composer.text = "";
        \\root.close();
        \\root.focusView(chat.view);
        \\chat.view.focusRegion("composer");
        \\chat.composer.text = "";
        \\// A pending chord takes the next key before the float, so Tab completes nothing here.
        \\chat.composer.text = "/ech";
        \\root.onEvent(key("char", { char: "k", mods: 4 }));
        \\check("chord-armed", keymap.pendingLabel() === "ctrl+k");
        \\root.onEvent(key("tab"));
        \\check("chord-beats-float", chat.composer.text === "/ech" && keymap.pendingLabel() === "");
        \\chat.view.focusRegion("composer");
        \\chat.composer.text = "";
        \\// A command that left the registry while its row showed runs nothing and keeps the draft.
        \\const gone = command.add(null, { "test:gone": () => {} }, { "test:gone": { title: "Gone", description: "d", slash: "gone" } });
        \\chat.composer.text = "/gone";
        \\check("gone-listed", root.overlays.length === 1);
        \\gone();
        \\root.onEvent(key("enter"));
        \\check("gone-keeps-draft", chat.composer.text === "/gone" && root.overlays.length === 0);
        \\chat.composer.text = "";
        \\off();
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "slash.js");
    try expectJs(host, "ok");
}

test "the auth plugin logs in with a device code or a key, logs out, and guards the model picker" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import "yuke:defaults";
        \\plugins.use(tuiPlugin);
    , "boot.js");
    // `client` is one object, so the test replaces the auth calls and drives the dialogs with keys.
    try host.evalModule(
        \\import { command, root, events } from "yuke:core";
        \\import { client } from "yuke:client";
        \\import { notice } from "yuke:notice";
        \\import { chat } from "yuke:defaults";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
        \\const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
        \\const finished = (login_id, outcome) => events.emit("auth.login_finished", { type: "index", facts: ["auth.login_finished"],
        \\  auth: [{ method: "auth.login_finished", params: { login_id, provider_id: "codex", outcome } }] });
        \\root.focusView(chat.view);
        \\const calls = [];
        \\client.catalogReload = () => Promise.resolve({ changed: false });
        \\client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", models: [],
        \\  providers: [{ id: "codex", name: "Codex", state: "needs_credential" }, { id: "minimax", name: "MiniMax", state: "ready" }] });
        \\client.authList = () => Promise.resolve({ providers: [
        \\  { provider_id: "codex", can_login: true }, { provider_id: "minimax", credential_kind: "api_key", can_login: false }] });
        \\client.authLogin = (id) => { calls.push("login:" + id); return Promise.resolve({ login_id: "L1", verification_url: "https://x/y", user_code: "AB-CD" }); };
        \\client.authCancelLogin = (id) => { calls.push("cancel:" + id); return Promise.resolve({}); };
        \\client.authSetApiKey = (id, k) => { calls.push("key:" + id + ":" + k); return Promise.resolve({}); };
        \\client.authRemove = (id) => { calls.push("remove:" + id); return Promise.resolve({}); };
        \\
        \\// /login lists both providers with the kind and the state of each.
        \\command.perform("auth:login");
        \\await settle();
        \\check("login-lists", root.overlays.length === 1);
        \\const picker = root.overlays[0].content;
        \\check("login-rows", picker.list.items.length === 2);
        \\check("login-state", picker.selectKey("codex") && picker.selected().state === "needs_credential");
        \\root.onEvent(key("enter"));
        \\await settle();
        \\check("device-dialog", root.overlays.length === 1 && calls.includes("login:codex"));
        \\// The outcome of another login leaves the dialog open; the outcome of this one closes it with its message.
        \\finished("L9", { type: "succeeded" });
        \\check("other-login-ignored", root.overlays.length === 1);
        \\finished("L1", { type: "failed", message: "denied" });
        \\check("failure-closes", root.overlays.length === 0 && notice.text === "login failed · denied");
        \\
        \\// An unknown name is a notice, not a list.
        \\command.perform("auth:login", "nope");
        \\await settle();
        \\check("unknown-name", root.overlays.length === 0 && notice.text === "no provider named nope");
        \\
        \\// A direct `/login codex` skips the list, and Escape cancels through the engine.
        \\command.perform("auth:login", "codex");
        \\await settle();
        \\check("direct-opens-dialog", root.overlays.length === 1);
        \\root.onEvent(key("esc"));
        \\check("esc-cancels", root.overlays.length === 0 && calls.includes("cancel:L1"));
        \\
        \\// A key provider gets the masked prompt, and Enter stores the key.
        \\command.perform("auth:login", "minimax");
        \\await settle();
        \\check("key-prompt", root.overlays.length === 1);
        \\const prompt = root.overlays[0].content;
        \\root.onEvent(key("char", { char: "s", text: "s" }));
        \\root.onEvent({ type: "paste", text: "k" });
        \\check("masked", prompt.input.text === "sk" && prompt.shown(prompt.input.text) === "••");
        \\root.onEvent(key("enter"));
        \\await settle();
        \\check("key-stored", root.overlays.length === 0 && calls.includes("key:minimax:sk"));
        \\
        \\// /logout lists only the provider that holds a credential.
        \\command.perform("auth:logout");
        \\await settle();
        \\check("logout-lists-one", root.overlays.length === 1 && root.overlays[0].content.list.items.length === 1);
        \\root.onEvent(key("enter"));
        \\await settle();
        \\check("logout-removes", root.overlays.length === 0 && calls.includes("remove:minimax"));
        \\// A key from the environment is not in the file, so the engine refuses and the notice says where it lives.
        \\client.authRemove = () => { const e = new Error("unknown provider"); e.code = "unknown_provider"; return Promise.reject(e); };
        \\command.perform("auth:logout", "minimax");
        \\await settle();
        \\check("env-key-notice", notice.text.indexOf("in the environment") > 0);
        \\
        \\// The model picker dims a model whose provider needs a credential, and accepting it starts the login.
        \\client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r2", providers: [{ id: "codex", name: "Codex", state: "needs_credential" }],
        \\  models: [{ id: "gpt", provider: "codex", selector: "codex/gpt", name: "gpt", reasoning_levels: [], default_reasoning: "", cost: {} }] });
        \\command.perform("model:pick");
        \\await settle();
        \\check("model-picker", root.overlays.length === 1);
        \\const models = root.overlays[0].content;
        \\check("model-dimmed", models.list.items.length === 1 && models.opts.format(models.list.items[0]).group === "UIDim");
        \\root.onEvent(key("enter"));
        \\await settle();
        \\check("model-accept-logs-in", root.overlays.length === 1 && calls[calls.length - 1] === "login:codex");
        \\root.onEvent(key("esc"));
        \\check("dialog-closed", root.overlays.length === 0);
        \\// A provider without a route cannot log in, so the picker stops with the reason.
        \\client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r3", providers: [{ id: "codex", name: "Codex", state: "needs_route" }],
        \\  models: [{ id: "gpt", provider: "codex", selector: "codex/gpt", name: "gpt", reasoning_levels: ["low", "high"], default_reasoning: "low", cost: {} }] });
        \\command.perform("model:pick");
        \\await settle();
        \\root.onEvent(key("enter"));
        \\await settle();
        \\check("route-stops", root.overlays.length === 0 && notice.text.indexOf("needs a route") > 0);
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "auth.js");
    try expectJs(host, "ok");
}

test "the activity module reads back on the fact, overlays the chat entry, and an interrupt keeps the queue" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import "yuke:defaults";
        \\plugins.use(tuiPlugin);
    , "boot.js");
    try host.evalModule(
        \\import { root, events } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { client } from "yuke:client";
        \\import { feedOf } from "yuke:sessions";
        \\import { activityOf, isWorking } from "yuke:activity";
        \\import { chatEntry } from "yuke:chat";
        \\import { chat } from "yuke:defaults";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const idle = { state: { type: "idle" }, queued: 0, context_usage: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, pending_compaction: null };
        \\const running = { ...idle, state: { type: "running", run_id: 1, started_at_ms: 5 }, queued: 2 };
        \\let reads = 0;
        \\let answer = running;
        \\client.sessionActivity = () => { reads++; return answer; };
        \\const cancels = [];
        \\client.sessionCancelRun = (id, clear) => { cancels.push([id, clear]); return Promise.resolve({ cleared_inputs: [] }); };
        \\feedOf().seed({ items: [{ session: { id: "s1", model: "m", updated_at_ms: 1 }, activity: idle }] });
        \\const seen = [];
        \\events.on("activity.changed", (id, a) => seen.push(id + ":" + (a ? a.state.type : "null")));
        \\root.focusView(chat.view);
        \\chat.open("s1");
        \\check("open-reads", reads === 1 && isWorking(activityOf("s1")) && activityOf("s1").queued === 2);
        \\check("entry-overlays", chatEntry().activity === running && chatEntry().session.model === "m");
        \\// A quiet digest without the fact costs no read; one with the fact reads once.
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["run.started"] });
        \\check("no-fact-no-read", reads === 1);
        \\answer = idle;
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
        \\check("fact-reads", reads === 2 && !isWorking(activityOf("s1")) && chatEntry().activity === idle);
        \\// A null read means the pane let the session go, and a gone session forgets its entry.
        \\answer = null;
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
        \\check("null-forgets", activityOf("s1") === null && chatEntry().activity === idle);
        \\answer = running;
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "gone", facts: ["session.removed"] });
        \\check("gone-forgets", activityOf("s1") === null);
        \\check("events", seen.join(",") === "s1:running,s1:idle,s1:null,s1:running,s1:null");
        \\// An interrupt stops the run and never clears the queue.
        \\chat.sessionId = "s1";
        \\chat.interrupt();
        \\check("interrupt-keeps-queue", cancels.length === 1 && cancels[0][0] === "s1" && cancels[0][1] === undefined);
        \\plugins.dispose("activity");
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "activity.js");
    try expectJs(host, "ok");
}

test "commands.define registers a user command with a slash word and removes it" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { command } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import { commands } from "yuke";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\let got = null;
        \\commands.define({ name: "review", title: "Review", description: "ask for a review", args: true, run: (arg) => { got = arg; } });
        \\const listed = command.list().find((c) => c.name === "user:review");
        \\check("listed", !!listed && listed.slash === "review" && listed.args === true && listed.title === "Review");
        \\command.perform("user:review", "src");
        \\check("runs", got === "src");
        \\commands.define({ name: "review", title: "Review 2", description: "d", run: () => {} });
        \\check("redefine-replaces", command.list().filter((c) => c.name === "user:review").length === 1);
        \\commands.define({ name: "hidden", title: "H", description: "d", slash: null, run: () => {} });
        \\check("slash-opt-out", command.list().find((c) => c.name === "user:hidden").slash === null);
        \\plugins.dispose("command:review");
        \\check("dispose-removes", !command.available("user:review"));
        \\let threw = false;
        \\try { commands.define({ name: "x", title: "t", description: "d" }); } catch (_e) { threw = true; }
        \\check("refuses-no-run", threw);
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "define.js");
    try expectJs(host, "ok");
}

test "the palette hints only the strokes that run the command here" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // A hint the current context cannot run is worse than no hint, so the scan must rank like dispatch.
    try host.evalModule(
        \\import { command, keymap, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { commandUiPlugin } from "yuke:command-ui";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\plugins.use(commandUiPlugin);
        \\
        \\const meta = { title: "t", description: "d" };
        \\const offCmd = command.add(null, {
        \\  "test:plain": () => {}, "test:hidden": () => {},
        \\  "test:shadowed": () => {}, "test:winner": () => {},
        \\}, { "test:plain": meta, "test:hidden": meta, "test:shadowed": meta, "test:winner": meta });
        \\const offA = keymap.add({ "ctrl+alt+a": "test:plain" });
        \\// No pane provides this atom, so the stroke never reaches the command.
        \\const offB = keymap.add({ "ctrl+alt+b": "test:hidden" }, "no_such_pane");
        \\// One stroke, two commands: the newest entry answers it and the older one is shadowed.
        \\const offC = keymap.add({ "ctrl+alt+c": "test:shadowed" });
        \\const offD = keymap.add({ "ctrl+alt+c": "test:winner" });
        \\
        \\const hintOf = (name) => {
        \\  command.perform("ui:palette");
        \\  const win = root.overlays[root.overlays.length - 1];
        \\  const p = win.content;
        \\  p.selectKey(name);
        \\  const it = p.selected();
        \\  root.popOverlay(win);
        \\  return it && it.name === name ? it.hint : null;
        \\};
        \\
        \\check("hint-shows-active", hintOf("test:plain") === "ctrl+alt+a");
        \\check("hint-hides-inactive", hintOf("test:hidden") === "");
        \\check("hint-shows-winner", hintOf("test:winner") === "ctrl+alt+c");
        \\check("hint-hides-shadowed", hintOf("test:shadowed") === "");
        \\check("palette-closed", root.overlays.length === 0);
        \\
        \\offA(); offB(); offC(); offD(); offCmd();
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "hint.js");
    try expectJs(host, "ok");
}

test "the pager follows the tail and counts the rows once per frame" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 24, 80);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    host.paint.render = &paint.render;
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Pager } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const rows = (n) => Array.from({ length: n }, (_, i) => ({ text: "row " + i }));
        \\const frame = (p) => { term.beginFrame(); p.draw({ x: 0, y: 0, w: 10, h: 4 }); term.endFrame(); };
        \\
        \\const p = new Pager();
        \\p.setRows(rows(10));
        \\frame(p);
        \\check("starts-at-the-tail", p.stuck === true && p.scroll === 6);
        \\
        \\// New rows arrive while the pager sits at the tail, so the view follows them down.
        \\p.setRows(rows(20));
        \\frame(p);
        \\check("stuck-follows-the-tail", p.stuck === true && p.scroll === 16);
        \\
        \\// A scroll away from the tail unsticks, and later rows must not move the view.
        \\p.scrollBy(-5);
        \\check("scroll-away-unsticks", p.stuck === false && p.scroll === 11);
        \\p.setRows(rows(30));
        \\frame(p);
        \\check("unstuck-holds-the-offset", p.stuck === false && p.scroll === 11);
        \\
        \\// A scroll back to the last row sticks again.
        \\p.scrollBy(100);
        \\check("tail-sticks-again", p.stuck === true && p.scroll === 26);
        \\
        \\// `rowCount` walks every message, so one frame must ask for it exactly once.
        \\let asked = 0;
        \\const q = new Pager();
        \\q.setSource({ rowCount: () => { asked++; return 30; }, rows: () => [] });
        \\asked = 0;
        \\frame(q);
        \\check("one-row-count-per-frame", asked === 1);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "pager.js");
    try expectJs(host, "ok");
}

test "the catalog stores a full reply and keeps the models on unchanged" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // `client` is one object, so a test replaces the one method the branch calls.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\import { catalogOf, loadCatalog } from "yuke:catalog";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const sent = [];
        \\client.catalogList = (sinceRev) => {
        \\  sent.push(sinceRev);
        \\  return Promise.resolve({ type: "full", catalog_rev: "r1", models: [{ selector: "m1", name: "m1" }] });
        \\};
        \\await loadCatalog();
        \\const c = catalogOf();
        \\check("full-stores-models", c.models.length === 1 && c.models[0].selector === "m1");
        \\check("full-stores-rev", c.rev === "r1");
        \\check("load-clears-loading", c.loading === false);
        \\
        \\// The second load sends the stored revision, and an unchanged reply keeps what the catalog holds.
        \\client.catalogList = (sinceRev) => { sent.push(sinceRev); return Promise.resolve({ type: "unchanged" }); };
        \\await loadCatalog();
        \\check("unchanged-keeps-models", c.models.length === 1 && c.rev === "r1");
        \\check("sends-since-rev", sent.length === 2 && sent[0] === null && sent[1] === "r1");
        \\
        \\// A rejected list leaves the catalog as it was and still clears the flag.
        \\client.catalogList = () => Promise.reject(new Error("offline"));
        \\await loadCatalog();
        \\check("refusal-keeps-models", c.models.length === 1 && c.rev === "r1" && c.loading === false);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "catload.js");
    try expectJs(host, "ok");
}

test "the explorer turns one directory listing into rows" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { fs } from "yuke:fs";
        \\import { command, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { explorerPlugin } from "yuke:explorer";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\plugins.use(explorerPlugin);
        \\
        \\let asked = "unset";
        \\fs.list = (path) => {
        \\  asked = path;
        \\  return Promise.resolve({
        \\    path: "/w", parent: "/", more: true,
        \\    entries: [{ name: "a", path: "/w/a", is_git_repo: true }, { name: "b", path: "/w/b", is_git_repo: false }],
        \\  });
        \\};
        \\command.perform("app:explorer");
        \\await Promise.resolve();
        \\const rows = root.overlays[root.overlays.length - 1].content.list.items;
        \\check("lists-the-working-directory", asked === null);
        \\// A parent leads the page, the entries follow, and `more` adds the truncation notice.
        \\check("parent-row-first", rows[0].up === true && rows[0].dest === "/");
        \\check("entry-rows", rows[1].path === "/w/a" && rows[1].is_git_repo === true && rows[2].path === "/w/b");
        \\check("more-adds-notice", rows[3].notice === true && rows.length === 4);
        \\
        \\// A refusal replaces the page with one notice instead of leaving the old rows.
        \\fs.list = () => Promise.reject(new Error("unreadable"));
        \\root.overlays[root.overlays.length - 1].content.keymap.left();
        \\await Promise.resolve();
        \\await Promise.resolve();
        \\const after = root.overlays[root.overlays.length - 1].content.list.items;
        \\check("refusal-shows-one-notice", after.length === 1 && after[0].notice === true);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "explore.js");
    try expectJs(host, "ok");
}

test "the catalog slice owns the model and context readings" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The readings need the open session, which the shell owns, so the slice takes it as config.
    try host.evalModule(
        \\import { status, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { notice, noticePlugin } from "yuke:notice";
        \\import { catalogPlugin, catalogOf, chooseModel, tokenLabel } from "yuke:catalog";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\let open = null;
        \\plugins.use(catalogPlugin, { entry: () => open });
        \\
        \\// With no session the readings fall back to the default model and show no context.
        \\check("empty-without-session", status.side("right") === "");
        \\// A choice tells the user and asks for a repaint, or the new model never reaches the screen.
        \\plugins.use(noticePlugin);
        \\root._needsDraw = false;
        \\chooseModel({ selector: "m-1", name: "m-1" }, "high");
        \\check("choice-notifies", notice.text === "model · m-1 · high");
        \\check("choice-repaints", root._needsDraw === true);
        \\check("default-model-shows", status.side("right").indexOf("m-1") >= 0);
        \\
        \\// An open session names its own model instead of the default.
        \\open = { session: { id: "s", model: "session-model" }, activity: null };
        \\check("session-model-wins", status.side("right").indexOf("session-model") >= 0);
        \\check("no-ctx-without-usage", status.side("right").indexOf("ctx") < 0);
        \\
        \\// With usage and no known window the reading falls back to a token count.
        \\open = { session: { id: "s", model: "session-model" }, activity: { context_usage: { input: 2500 } } };
        \\check("token-fallback", status.side("right").indexOf("2.5k ctx") >= 0);
        \\
        \\// A model the catalog names reports a percentage of its window instead.
        \\catalogOf().models = [{ selector: "session-model", context_window: 10000 }];
        \\check("known-window-percent", status.side("right").indexOf("25% ctx") >= 0);
        \\catalogOf().models = [];
        \\check("token-label", tokenLabel(999) === "999" && tokenLabel(2500) === "2.5k" && tokenLabel(20000) === "20k");
        \\
        \\// An unload takes both readings away.
        \\plugins.dispose("catalog");
        \\check("unload-drops-readings", status.side("right") === "");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "catalog.js");
    try expectJs(host, "ok");
}

test "loadCatalog coalesces, clears its flag, and survives a refusal" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // There is no connection here, so the request refuses; the state machine must still settle.
    try host.evalModule(
        \\import { root } from "yuke:core";
        \\import { catalogOf, loadCatalog } from "yuke:catalog";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const c = catalogOf();
        \\check("starts-idle", c.loading === false && c.rev === null && c.models.length === 0);
        \\
        \\// A second call while one is open returns the same state and starts no new request.
        \\c.loading = true;
        \\const coalesced = await loadCatalog();
        \\check("coalesces", coalesced === c && c.loading === true);
        \\c.loading = false;
        \\
        \\// A refused request still clears the flag and asks for a repaint.
        \\root._needsDraw = false;
        \\const settled = await loadCatalog();
        \\check("settles", settled === c && c.loading === false);
        \\check("repaints", root._needsDraw === true);
        \\check("keeps-empty-state", c.rev === null && c.models.length === 0);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "loadcatalog.js");
    try expectJs(host, "ok");
}

test "the chat slice owns its listeners and its transcript commands" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The chat reacts to session events and offers the commands that read its transcript.
    try host.evalModule(
        \\import { command, events, root, Node } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { Chat, chatEntry, chatPlugin } from "yuke:chat";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\// The pane must sit in the tree, because a session command acts on the focused chat.
        \\const chat = new Chat();
        \\root.setRoot(new Node(chat.view));
        \\root.focusView(chat.view);
        \\
        \\check("commands-absent-before", !command.available("model:pick"));
        \\plugins.use(chatPlugin);
        \\check("commands-registered", command.available("model:pick"));
        \\
        \\// A "gone" event for the open pair closes the session; one for another pair does not.
        \\chat.sessionId = "s1";
        \\events.emit("session.changed", { type: "session", session: "other", kind: "gone" });
        \\check("ignores-other-pair", chat.sessionId === "s1");
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "gone" });
        \\check("closes-open-pair", chat.sessionId === null);
        \\
        \\// The "active" and reload branches move the transcript, not just the session id.
        \\chat.sessionId = "s1";
        \\let actives = [];
        \\const realActive = chat.transcript.setActive.bind(chat.transcript);
        \\chat.transcript.setActive = (id) => { actives.push(id); return realActive(id); };
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "active", id: 7 });
        \\check("active-moves-transcript", actives.join(",") === "7");
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "delta" });
        \\check("other-kinds-reload", actives.join(",") === "7");
        \\
        \\// A quiet digest moves nothing the transcript draws, so neither branch runs.
        \\let reloads = 0;
        \\const realReload = chat.reload.bind(chat);
        \\chat.reload = () => { reloads++; return realReload(); };
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "reload" });
        \\check("reload-kind-reloads", reloads === 1);
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "quiet" });
        \\check("quiet-draws-nothing", reloads === 1 && actives.join(",") === "7");
        \\chat.reload = realReload;
        \\chat.transcript.setActive = realActive;
        \\
        \\chat.sessionId = null;
        \\
        \\// With no session the entry lookup answers null rather than reaching into a feed.
        \\check("no-entry-without-session", chatEntry() === null);
        \\
        \\// An unload takes the commands and the listeners with it.
        \\plugins.dispose("chat");
        \\check("unload-drops-commands", !command.available("model:pick"));
        \\chat.sessionId = "s2";
        \\events.emit("session.changed", { type: "session", session: "s2", kind: "gone" });
        \\check("unload-stops-listening", chat.sessionId === "s2");
        \\chat.sessionId = null;
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "chat.js");
    try expectJs(host, "ok");
}

test "the chat pane routes a drag that leaves the transcript and guards its press slot" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 20, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);

    // A drag that ends over the composer must still reach the transcript, or its drag never ends.
    try host.evalModule(
        \\import { root, Node, slot } from "yuke:core";
        \\import { term } from "yuke:term";
        \\import { ChatView } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const body = { a1: "alpha bravo charlie\nsecond line here\nthird line xx" };
        \\const v = new ChatView({ textOf: (id) => body[id] || "" });
        \\v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
        \\root.setRoot(new Node(v));
        \\v.rect = { x: 0, y: 0, w: 40, h: 18 };
        \\term.beginFrame(); v.draw(true); term.endFrame();
        \\const r = v.transcript.pager.rect();
        \\const mouse = (row, event, button) => v.onMouse({ type: "mouse", col: r.x + 2, row, button: button || "left", event, mods: 0 });
        \\
        \\mouse(r.y, "press");
        \\check("press-starts-drag", v.transcript._dragging === true);
        \\mouse(v.composer.rect.y, "drag");
        \\check("drag-outside-still-drags", v.transcript._dragging === true);
        \\mouse(v.composer.rect.y, "release");
        \\check("release-outside-ends-drag", v.transcript._dragging === false);
        \\
        \\// A non-left button never reaches the press slot.
        \\let calls = 0;
        \\const off = slot.add(ChatView, "press", () => { calls++; return true; });
        \\mouse(r.y, "press", "right");
        \\check("right-button-skips-slot", calls === 0);
        \\mouse(r.y, "drag");
        \\check("drag-skips-slot", calls === 0);
        \\mouse(r.y, "press");
        \\check("left-press-reaches-slot", calls === 1);
        \\off();
        \\
        \\// The pane claims the press only for a literal true, so a truthy value does not.
        \\const offTruthy = slot.add(ChatView, "press", () => "yes");
        \\check("truthy-does-not-claim", v.onMouse({ type: "mouse", col: r.x + 2, row: v.composer.rect.y, button: "left", event: "press", mods: 0 }) === false);
        \\offTruthy();
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "mouse.js");
    try expectJs(host, "ok");
}

test "a split gives each chat pane its own session" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // Each pane starts with its own session, and an event reaches every pane that shows the pair.
    try host.evalModule(
        \\import { root, Node, events } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { Chat, chats, chatOf, focusedChat, focusedChatView, chatPlugin } from "yuke:chat";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\plugins.use(chatPlugin);
        \\
        \\const a = new Chat();
        \\root.setRoot(new Node(a.view));
        \\root.focusView(a.view);
        \\check("first-is-focused", focusedChat() === a);
        \\
        \\// The split leaves the new pane focused, so a command acts on the pane the user just made.
        \\const b = new Chat();
        \\root.split("row", b.view);
        \\check("split-focuses-new", root.active === b.view && focusedChat() === b);
        \\check("view-leads-back", chatOf(b.view) === b && chatOf(a.view) === a);
        \\
        \\// Each pane holds its own session, so one pane cannot move the other.
        \\a.connKey = "local"; a.sessionId = "s1";
        \\b.connKey = "local"; b.sessionId = "s2";
        \\a.transcript.setOutline([{ id: "u1", type: "user" }], null);
        \\b.transcript.setOutline([{ id: "u2", type: "user" }, { id: "a2", type: "assistant" }], null);
        \\check("separate-transcripts", a.transcript.messages().length === 1 && b.transcript.messages().length === 2);
        \\
        \\// A "gone" event reaches only the pane that names the pair.
        \\events.emit("session.changed", { type: "session", session: "s1", kind: "gone" });
        \\check("gone-hits-one-pane", a.sessionId === null && b.sessionId === "s2");
        \\
        \\// Two panes on one session both follow it, which a single-chat shell could never do.
        \\a.sessionId = "s2";
        \\let seen = 0;
        \\const ra = a.transcript.setActive.bind(a.transcript);
        \\const rb = b.transcript.setActive.bind(b.transcript);
        \\a.transcript.setActive = (id) => { seen++; return ra(id); };
        \\b.transcript.setActive = (id) => { seen++; return rb(id); };
        \\events.emit("session.changed", { type: "session", session: "s2", kind: "active", id: 3 });
        \\check("both-panes-follow", seen === 2);
        \\a.transcript.setActive = ra;
        \\b.transcript.setActive = rb;
        \\
        \\// A closed pane releases its chat, so the registry does not keep a pane the tree dropped.
        \\const had = chats.size;
        \\root.focusView(b.view);
        \\root.close();
        \\check("close-drops-the-chat", chats.size === had - 1 && !chats.has(b));
        \\check("close-leaves-the-other", chats.has(a) && focusedChat() === a);
        \\
        \\// A replaced tree drops its panes, so a whole-tree swap releases them like a close.
        \\const c1 = new Chat();
        \\const c2 = new Chat();
        \\c1.connKey = "local"; c1.sessionId = "s9";
        \\root.setRoot(new Node(c1.view));
        \\check("setRoot-drops-the-pane-it-replaced", !chats.has(a));
        \\const held = chats.size;
        \\root.setRoot(new Node(c2.view));
        \\check("setRoot-drops-the-old-pane", chats.size === held - 1 && !chats.has(c1));
        \\check("setRoot-keeps-the-new-pane", chats.has(c2));
        \\
        \\// A pane that survives the swap must not be released, so only the dropped views go.
        \\const stay = new Chat();
        \\const drop = new Chat();
        \\root.setRoot(Node.branch("row", new Node(stay.view), new Node(drop.view), 0.5));
        \\root.setRoot(new Node(stay.view));
        \\check("setRoot-releases-only-the-dropped", chats.has(stay) && !chats.has(drop));
        \\
        \\// A split with no active leaf must not leave its new chat in the registry.
        \\root.setRoot(null);
        \\const orphans = chats.size;
        \\const tried = new Chat();
        \\if (!root.split("row", tried.view)) tried.dispose();
        \\check("failed-split-keeps-no-orphan", chats.size === orphans);
        \\
        \\// A bare view is a pane for a layer, but it owns no session, so a command finds none.
        \\const bare = { name: "chat", rect: { x: 0, y: 0, w: 1, h: 1 }, draw() {} };
        \\root.setRoot(new Node(bare));
        \\check("bare-view-is-a-pane", focusedChatView() === bare);
        \\check("bare-view-owns-no-session", focusedChat() === null);
        \\
        \\plugins.dispose("chat");
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "splitchat.js");
    try expectJs(host, "ok");
}

test "the context owns every overlay its plugin pushes" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // A modal that outlives its plugin consumes every key, so the scope must own the stack too.
    try host.evalModule(
        \\import { command, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { tui } from "yuke:tui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const layer = (n) => ({ name: n, rect: { x: 0, y: 0, w: 1, h: 1 }, draw() {} });
        \\
        \\const owner = { name: "ov", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "ov:open": () => t.overlay(root.pushOverlay(layer("own"))) }); } };
        \\const other = { name: "other", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "other:open": () => root.pushOverlay(layer("other")) }); } };
        \\const base = root.overlays.length;
        \\
        \\plugins.use(owner);
        \\plugins.use(other);
        \\
        \\// Two overlays from one plugin both leave with it, and an unowned one stays.
        \\command.perform("ov:open");
        \\command.perform("ov:open");
        \\command.perform("other:open");
        \\check("three-open", root.overlays.length === base + 3);
        \\plugins.dispose("ov");
        \\check("owned-popped", root.overlays.length === base + 1);
        \\check("unowned-kept", root.overlays[root.overlays.length - 1].name === "other");
        \\root.popOverlay();
        \\plugins.dispose("other");
        \\
        \\// One plugin's unload must leave another plugin's overlay alone, not every owned overlay.
        \\const second = { name: "ov2", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "ov2:open": () => t.overlay(root.pushOverlay(layer("own2"))) }); } };
        \\plugins.use(owner);
        \\plugins.use(second);
        \\command.perform("ov:open");
        \\command.perform("ov2:open");
        \\plugins.dispose("ov");
        \\check("other-owner-kept", root.overlays.length === base + 1 && root.overlays[root.overlays.length - 1].name === "own2");
        \\plugins.dispose("ov2");
        \\check("second-owner-popped", root.overlays.length === base);
        \\
        \\// A reload owns its own overlays, and the disposed scope no longer reaches the stack.
        \\plugins.use(owner);
        \\command.perform("ov:open");
        \\const kept = root.pushOverlay(layer("kept"));
        \\plugins.dispose("ov");
        \\check("reload-pops-its-own", root.overlays.length === base + 1);
        \\check("reload-keeps-others", root.overlays[root.overlays.length - 1] === kept);
        \\root.popOverlay(kept);
        \\
        \\// An overlay the user already closed is not popped again, so an unload cannot take a later one.
        \\plugins.use(owner);
        \\command.perform("ov:open");
        \\root.popOverlay();
        \\const after = root.pushOverlay(layer("after"));
        \\plugins.dispose("ov");
        \\check("closed-overlay-not-repopped", root.overlays.length === base + 1 && root.overlays[root.overlays.length - 1] === after);
        \\root.popOverlay(after);
        \\
        \\// The map keys on the layer, so a plugin that pushes one twice still owns the second push.
        \\const again = layer("again");
        \\plugins.use({ name: "re", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "re:open": () => t.overlay(root.pushOverlay(again)) }); } });
        \\command.perform("re:open");
        \\root.popOverlay(again);
        \\root.pushOverlay(again);
        \\plugins.dispose("re");
        \\check("re-push-stays-owned", root.overlays.length === base);
        \\
        \\// A layer that never reached the stack is a caller error, such as a picker handle in place of its window.
        \\let threw = false;
        \\plugins.use({ name: "bad", apply(ctx) { const t = tui.bindTo(ctx); try { t.overlay(layer("loose")); } catch (e) { threw = true; } } });
        \\check("rejects-a-layer-off-the-stack", threw && root.overlays.length === base);
        \\plugins.dispose("bad");
        \\
        \\// The overlay cleanup keeps its place among the plugin's own effects, so the order stays LIFO.
        \\const seen = [];
        \\plugins.use({ name: "ord", apply(ctx) {
        \\  const t = tui.bindTo(ctx);
        \\  const a = root.pushOverlay(layer("a"));
        \\  t.overlay(a);
        \\  ctx.effect(() => () => seen.push(root.overlays.indexOf(a) >= 0));
        \\  t.overlay(root.pushOverlay(layer("b")));
        \\} });
        \\plugins.dispose("ord");
        \\check("cleanup-keeps-its-disposer-slot", seen.length === 1 && seen[0] === true);
        \\check("order-test-left-nothing", root.overlays.length === base);
        \\
        \\// A frozen layer must still be claimable, so the claim never writes to the layer itself.
        \\const frozen = Object.freeze({ name: "frozen", rect: { x: 0, y: 0, w: 1, h: 1 }, draw() {} });
        \\plugins.use({ name: "fz", apply(ctx) { const t = tui.bindTo(ctx); t.overlay(root.pushOverlay(frozen)); } });
        \\check("frozen-claimed", root.overlays.length === base + 1);
        \\plugins.dispose("fz");
        \\check("frozen-popped", root.overlays.length === base);
        \\
        \\// One layer pushed twice leaves twice, because the cleanup walks every stack entry.
        \\const twice = layer("twice");
        \\plugins.use({ name: "dup", apply(ctx) {
        \\  const t = tui.bindTo(ctx);
        \\  root.pushOverlay(twice);
        \\  t.overlay(root.pushOverlay(twice));
        \\} });
        \\check("dup-pushed", root.overlays.length === base + 2);
        \\plugins.dispose("dup");
        \\check("dup-both-popped", root.overlays.length === base);
        \\
        \\// A late push from a disposed plugin closes at once, because a dead scope can never revert it.
        \\let late = null;
        \\plugins.use({ name: "late", apply(ctx) { const t = tui.bindTo(ctx); late = () => t.overlay(root.pushOverlay(layer("late"))); } });
        \\plugins.dispose("late");
        \\late();
        \\check("dead-scope-closes-a-late-push", root.overlays.length === base);
        \\
        \\// A late push of a layer that the stack already holds closes every copy, not only the first.
        \\const twiceLate = layer("twicelate");
        \\let lateDup = null;
        \\plugins.use({ name: "ld", apply(ctx) { const t = tui.bindTo(ctx); lateDup = () => { root.pushOverlay(twiceLate); t.overlay(root.pushOverlay(twiceLate)); }; } });
        \\plugins.dispose("ld");
        \\lateDup();
        \\check("dead-scope-closes-every-copy", root.overlays.length === base);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "ctxoverlay.js");
    try expectJs(host, "ok");
}

test "the explorer registers its command and takes it back on unload" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // The picker walks the filesystem through the client, so only its command lifetime is tested here.
    try host.evalModule(
        \\import { command, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { explorerPlugin } from "yuke:explorer";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\check("absent-before-load", !command.available("app:explorer"));
        \\plugins.use(explorerPlugin);
        \\check("command-registered", command.available("app:explorer"));
        \\
        \\// The command must open it, so a broken command entry cannot pass.
        \\const before = root.overlays.length;
        \\command.perform("app:explorer");
        \\check("command-opens-overlay", root.overlays.length === before + 1);
        \\
        \\// An unload takes an OPEN picker off the stack, or it keeps eating every key.
        \\plugins.dispose("explorer");
        \\check("unload-pops-open-picker", root.overlays.length === before);
        \\check("unload-drops-command", !command.available("app:explorer"));
        \\
        \\// A reload opens and closes cleanly again.
        \\plugins.use(explorerPlugin);
        \\command.perform("app:explorer");
        \\check("reload-opens", root.overlays.length === before + 1);
        \\root.popOverlay();
        \\check("closes-again", root.overlays.length === before);
        \\plugins.dispose("explorer");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "explorer.js");
    try expectJs(host, "ok");
}

test "yuke:fs reads, writes and stats a real directory through promises" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "one\ntwo\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    // A real task needs a reactor, so this test runs on one instead of the testing I/O.
    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = root });
    defer host.destroy();
    try host.evalModule(
        \\import { fs } from "yuke:fs";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\globalThis.done = 0;
        \\(async () => {
        \\  // A relative path anchors at the directory the host runs in.
        \\  check("read", await fs.readFile("hello.txt") === "one\ntwo\n");
        \\  check("write-count", await fs.writeFile("made.txt", "abc") === 3);
        \\  check("read-back", await fs.readFile("made.txt") === "abc");
        \\  const info = await fs.stat("made.txt");
        \\  check("stat-file", info !== null && info.isDirectory === false);
        \\  check("stat-missing", await fs.stat("nope.txt") === null);
        \\  // A failure rejects with an Error rather than answering a sentinel.
        \\  let message = "";
        \\  try { await fs.readFile("nope.txt"); } catch (e) { message = e.message; }
        \\  check("read-missing-rejects", message === "the path does not exist");
        \\  globalThis.done = fail.length ? 2 : 1;
        \\})();
    , "fsp.js");
    try pumpUntilIdle(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.done"));
}

/// Run the reactor until every primitive settles, as the owner loop does; a task runs only while this waits.
fn pumpUntilIdle(host: *Host) !void {
    var rounds: u32 = 0;
    while (host.ops.live.items.len != 0) : (rounds += 1) {
        if (rounds == 64) return error.PrimitiveNeverSettled;
        host.wake.timedWait(.fromMilliseconds(1000)) catch {};
        host.wake.reset();
        try host.pump();
    }
    try host.pump();
}

/// Drive the owner until one call settles, the way `serve` does between frames.
fn pumpUntilSettled(host: *Host, call: *tools_table.Call, wake: ?*zio.ResetEvent) !void {
    var rounds: u32 = 0;
    while (call.state != .settled) : (rounds += 1) {
        if (rounds == 64) return error.CallNeverSettled;
        if (wake) |w| {
            w.timedWait(.fromMilliseconds(1000)) catch {};
            w.reset();
        }
        try host.pump();
    }
}

/// Drive the shared headless owner pump until one tool call settles.
fn pumpOwnerUntilSettled(host: *Host, call: *tools_table.Call) !void {
    const wake = &host.wake;
    var rounds: u32 = 0;
    while (call.state != .settled) : (rounds += 1) {
        if (rounds == 64) return error.CallNeverSettled;
        wake.timedWait(.fromMilliseconds(1000)) catch {};
        wake.reset();
        try host.pump();
    }
}

/// Leave the call, then let the owner sweep the record it owns.
fn dropCall(host: *Host, call: *tools_table.Call) !void {
    call.finish();
    try host.pump();
}

test "a hook fault in one result does not stop later handlers" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { events } from "yuke:kernel";
        \\import { plugins } from "yuke:ext";
        \\globalThis.faults = [];
        \\events.on("ext.error", (e, owner) => globalThis.faults.push(String(owner) + ":" + e.message));
        \\plugins.use({ name: "getter", apply(ctx) {
        \\  ctx.hook("input.before", () => ({ get block() { throw new Error("getter"); } }));
        \\} });
        \\plugins.use({ name: "convert", apply(ctx) {
        \\  ctx.hook("input.before", () => ({ block: { toString() { throw new Error("convert"); } } }));
        \\} });
        \\plugins.use({ name: "later", apply(ctx) {
        \\  ctx.hook("input.before", () => ({ block: "accepted" }));
        \\} });
    , "hook-fault.js");

    const call = host.calls.submitHook("input.before", "{}");
    try pumpUntilSettled(host, call, null);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"type\":\"block\",\"reason\":\"accepted\"}", call.text.?);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt(
        \\globalThis.faults.join(",") === "getter:getter,convert:convert" ? 1 : 0
    ));
    try dropCall(host, call);
}

test "the owner runs an async handler and answers its resolved value" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\const params = { type: "object", properties: { city: { type: "string", description: "The city." } } };
        \\defineTool("sync", { description: "d", parameters: params, execute: (a) => ({ got: a.city }) });
        \\defineTool("later", { description: "d", parameters: params, execute: async (a) => ({ got: a.city, async: true }) });
        \\defineTool("text", { description: "d", parameters: params, execute: async () => "just text" });
        \\defineTool("nothing", { description: "d", parameters: params, execute: async () => undefined });
    , "run.js");

    // A synchronous callback violates the tool contract.
    {
        const call = host.calls.submit("sync", "{\"city\":\"Tokyo\"}", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("the tool execute function must return a Promise", call.text.?);
        try dropCall(host, call);
    }
    // A Promise settles through the job drain, so one pump is still enough.
    {
        const call = host.calls.submit("later", "{\"city\":\"Kyoto\"}", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expectEqualStrings("{\"got\":\"Kyoto\",\"async\":true}", call.text.?);
        try dropCall(host, call);
    }
    // A string passes through, because a text tool must not gain quotes.
    {
        const call = host.calls.submit("text", "{\"city\":\"Osaka\"}", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expectEqualStrings("just text", call.text.?);
        try dropCall(host, call);
    }
    {
        const call = host.calls.submit("nothing", "{\"city\":\"Nara\"}", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expect(!call.is_error);
        try std.testing.expectEqualStrings("", call.text.?);
        try dropCall(host, call);
    }
    // Every record swept, so the host holds nothing after the calls.
    try std.testing.expectEqual(@as(usize, 0), host.calls.live.items.len);
}

test "a failed handler answers the model with an error it can read" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\const params = { type: "object", properties: { city: { type: "string", description: "The city." } } };
        \\defineTool("throws", { description: "d", parameters: params, execute: async () => { throw new Error("it broke"); } });
        \\defineTool("cycles", { description: "d", parameters: params, execute: async () => { const o = {}; o.self = o; return o; } });
    , "fail.js");

    const cases = [_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "throws", .want = "it broke" },
        .{ .name = "cycles", .want = "the tool answered a value that is not JSON" },
    };
    for (cases) |case| {
        const call = host.calls.submit(case.name, "{\"city\":\"Tokyo\"}", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings(case.want, call.text.?);
        try dropCall(host, call);
    }

    // A name that no tool owns, and arguments that are not JSON, are engine input, not a crash.
    {
        const call = host.calls.submit("absent", "{}", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("the tool is not registered", call.text.?);
        try dropCall(host, call);
    }
    {
        const call = host.calls.submit("throws", "not json", "");
        try pumpUntilSettled(host, call, null);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("the arguments are not valid JSON", call.text.?);
        try dropCall(host, call);
    }
    // A pending exception from any of those must not change the next call.
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("3 + 4"));
}

test "a handler that awaits a primitive answers when the task finishes" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "from disk" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = root });
    defer host.destroy();

    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\import { fs } from "yuke:fs";
        \\defineTool("read_note", {
        \\  description: "Read the note.",
        \\  parameters: { type: "object", properties: { path: { type: "string", description: "The path to read." } } },
        \\  execute: async ({ path }) => ({ text: await fs.readFile(path) }),
        \\});
    , "await.js");

    // The handler holds a task, not the owner, so the call settles only after the read finishes.
    const call = host.calls.submit("read_note", "{\"path\":\"note.txt\"}", "");
    try host.pump();
    try std.testing.expectEqual(tools_table.Call.State.running, call.state);

    try pumpOwnerUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"text\":\"from disk\"}", call.text.?);
    try dropCall(host, call);
}

test "a handler reads the signal after the turn leaves" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\globalThis.seen = "none";
        \\// The handler keeps the signal, so it reads the flag long after the call record is gone.
        \\defineTool("watch", {
        \\  description: "d",
        \\  parameters: { type: "object", properties: { city: { type: "string", description: "The city." } } },
        \\  execute: async (args, signal) => {
        \\    globalThis.check = () => { globalThis.seen = signal.aborted ? "aborted" : "live"; };
        \\    globalThis.check();
        \\    return new Promise(() => {});
        \\  },
        \\});
    , "signal.js");

    const call = host.calls.submit("watch", "{\"city\":\"Tokyo\"}", "");
    try host.pump();
    try expectSeen(host, "live"); // the handler read the flag at its start
    _ = try host.evalInt("globalThis.check(), 0");
    try expectSeen(host, "live");

    // The turn leaves, so the next pass marks the signal and sweeps the record.
    call.finish();
    try host.pump();
    try std.testing.expectEqual(@as(usize, 0), host.calls.live.items.len);
    _ = try host.evalInt("globalThis.check(), 0");
    try expectSeen(host, "aborted");
}

test "closing the host answers a call nobody would settle" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\// This handler never settles, so only the close can answer the waiting turn.
        \\defineTool("hangs", {
        \\  description: "d",
        \\  parameters: { type: "object", properties: { city: { type: "string", description: "The city." } } },
        \\  execute: async () => new Promise(() => {}),
        \\});
    , "hang.js");

    const call = host.calls.submit("hangs", "{\"city\":\"Tokyo\"}", "");
    try host.pump();
    try std.testing.expectEqual(tools_table.Call.State.running, call.state);

    // A turn task waits on this event. A close that leaves it unset would hang the shutdown.
    try host.close();
    try std.testing.expectEqual(tools_table.Call.State.settled, call.state);
    try std.testing.expect(call.is_error);
    try std.testing.expect(call.done.isSet());
}

test "defineTool registers a tool and states its raw schema" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\defineTool("get_weather", {
        \\  description: "Report the weather of one city.",
        \\  parameters: {
        \\    type: "object",
        \\    properties: {
        \\      city: { type: "string", description: "The city to report." },
        \\      unit: { type: "string", enum: ["celsius", "fahrenheit"], description: "The unit of temperature." },
        \\    },
        \\    required: ["city"],
        \\  },
        \\  execute: async ({ city }) => ({ city, weather: "sunny" }),
        \\});
        \\globalThis.result = "ok";
    , "tool.js");
    try expectJs(host, "ok");

    try std.testing.expectEqual(@as(usize, 1), host.tools.decls.items.len);
    const tool = host.tools.decls.items[host.tools.find("get_weather").?];
    try std.testing.expectEqualStrings("Report the weather of one city.", tool.description);
    // The schema reaches the provider unchanged, so an enum and a shorter `required` survive.
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"description\":\"The city to report.\"}," ++
            "\"unit\":{\"type\":\"string\",\"enum\":[\"celsius\",\"fahrenheit\"],\"description\":\"The unit of temperature.\"}}," ++
            "\"required\":[\"city\"]}",
        tool.input_schema,
    );
    try std.testing.expectEqualStrings("get_weather", host.tools.decls.items[0].name);
}

test "defineTool refuses every definition a provider would reject" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    // Each case must throw, because `index.js` is user input that has to fail loudly at boot.
    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const refused = (name, fn) => {
        \\  try { fn(); check(name, false); } catch (e) { check(name, e instanceof TypeError); }
        \\};
        \\const ok = { description: "d", parameters: { type: "object", properties: {} }, execute: () => 1 };
        \\refused("no-definition", () => defineTool("probe"));
        \\refused("name-not-string", () => defineTool(7, ok));
        \\refused("name-has-a-space", () => defineTool("get weather", ok));
        \\refused("name-too-long", () => defineTool("x".repeat(65), ok));
        \\refused("no-description", () => defineTool("probe", { ...ok, description: undefined }));
        \\refused("empty-description", () => defineTool("probe", { ...ok, description: "" }));
        \\refused("schema-not-object", () => defineTool("probe", { ...ok, parameters: "{}" }));
        \\refused("schema-wrong-type", () => defineTool("probe", { ...ok, parameters: { type: "array", properties: {} } }));
        \\refused("schema-no-properties", () => defineTool("probe", { ...ok, parameters: { type: "object" } }));
        \\refused("execute-not-a-function", () => defineTool("probe", { ...ok, execute: 5 }));
        \\
        \\defineTool("probe", ok);
        \\refused("duplicate-name", () => defineTool("probe", ok));
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "refuse.js");
    try expectJs(host, "ok");

    // Only the one valid registration reached the table.
    try std.testing.expectEqual(@as(usize, 1), host.tools.decls.items.len);
}

test "a tool registers after boot and keeps the advertised order stable" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    // Registration order is not the advertised order, so a load order change cannot move the prefix.
    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\const p = { type: "object", properties: {} };
        \\for (const n of ["zulu", "alpha", "mike"]) {
        \\  defineTool(n, { description: "d", parameters: p, execute: async () => ({ text: n }) });
        \\}
        \\globalThis.result = "ok";
    , "boot.js");
    try expectJs(host, "ok");

    // A plugin may add a tool after boot, and it lands in the same sorted position.
    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\defineTool("bravo", { description: "d", parameters: { type: "object", properties: {} },
        \\  execute: async () => ({ text: "b" }) });
        \\globalThis.result = "ok";
    , "late.js");
    try expectJs(host, "ok");

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa.allocator());
    for (host.tools.decls.items) |d| {
        if (names.items.len != 0) try names.append(gpa.allocator(), ',');
        try names.appendSlice(gpa.allocator(), d.name);
    }
    try std.testing.expectEqualStrings("alpha,bravo,mike,zulu", names.items);
}
test "baked tools preserve file edits, bounded reads, views, and command output" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\ntwo\n" });
    const long_line = try gpa.allocator().alloc(u8, 8001);
    defer gpa.allocator().free(long_line);
    @memset(long_line, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = long_line });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = "/tmp" });
    defer host.destroy();
    try host.evalModule(
        \\import "yuke:builtins";
    , "builtins-test.js");

    {
        const call = host.calls.submit("read", "{\"path\":\"a.txt\",\"start\":2,\"end\":3}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expectEqualStrings("2: two\n3: two", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("read", "{\"path\":\"long.txt\"}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.endsWith(u8, call.text.?, "[The tool cut 1 line(s) at 8000 bytes.]"));
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("read", "{\"path\":\"missing.txt\"}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("read: the path does not exist", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("read", "{\"path\":1}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("read: the argument path must be a string", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("edit", "{\"path\":\"a.txt\",\"old_string\":\"two\",\"new_string\":\"TWO\"}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "more than one") != null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("edit", "{\"path\":\"a.txt\",\"old_string\":\"two\",\"new_string\":\"TWO\",\"replace_all\":true}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "replaced 2") != null);
        try std.testing.expect(call.view_json != null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("write", "{\"path\":\"new.txt\",\"content\":\"fresh\\n\"}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "wrote 6 bytes") != null);
        try std.testing.expect(call.view_json != null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("write", "{\"path\":\"a.txt\",\"content\":\"one\\nTWO\\nTWO\\n\"}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(call.view_json == null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("exec", "{\"command\":\"echo out; echo err 1>&2; exit 3\"}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expectEqualStrings("out\n[stderr]\nerr\n[exit code: 3]", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("exec", "{\"command\":\"sleep 30\",\"timeout_ms\":300}", root);
        try pumpOwnerUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "[The command passed its 300 ms timeout.") != null);
        call.finish();
        try host.pump();
    }
}

test "a user edit tool overrides the baked edit tool" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { defineTool } from "yuke:tools";
        \\defineTool("edit", {
        \\  description: "The user edit tool.",
        \\  parameters: { type: "object", properties: {} },
        \\  execute: async () => "user edit",
        \\});
    , "index.js");
    try host.evalModule(
        \\import "yuke:builtins";
    , "builtins.js");

    const call = host.calls.submit("edit", "{}", "");
    try pumpUntilSettled(host, call, null);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("user edit", call.text.?);
    call.finish();
    try host.pump();
}

test "yuke:exec runs commands on tasks and reports each outcome" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker.txt", .data = "found\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    // A command needs a real reactor, because it runs on its own task.
    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = root });
    defer host.destroy();

    try host.evalModule(
        \\import { exec } from "yuke:exec";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\globalThis.result = "pending";
        \\(async () => {
        \\  const ok = await exec("echo hello");
        \\  check("stdout", ok.stdout === "hello\n");
        \\  check("code", ok.code === 0);
        \\  check("signal", ok.signal === null);
        \\  check("timed-out", ok.timedOut === false);
        \\  check("dropped", ok.stdoutDropped === 0 && ok.stderrDropped === 0);
        \\  const bad = await exec("echo oops 1>&2; exit 3");
        \\  check("stderr", bad.stderr === "oops\n");
        \\  check("exit-code", bad.code === 3);
        \\  // A command with no cwd runs in the directory the host runs in.
        \\  check("cwd", (await exec("cat marker.txt")).stdout === "found\n");
        \\  // A refused argument rejects; it never throws at the caller.
        \\  let message = "";
        \\  try { await exec("   "); } catch (e) { message = e.message; }
        \\  check("blank-rejects", message === "the command must not be blank");
        \\  try { await exec("echo x", { timeoutMs: 0 }); } catch (e) { message = e.message; }
        \\  check("timeout-range-rejects", message.startsWith("timeoutMs must be"));
        \\  // A number reaches the host as a double, so a fraction must fail rather than truncate.
        \\  message = "";
        \\  try { await exec("echo x", { timeoutMs: 1.5 }); } catch (e) { message = e.message; }
        \\  check("timeout-fraction-rejects", message.startsWith("timeoutMs must be"));
        \\  globalThis.result = fail.length ? fail.join(",") : "ok";
        \\})();
    , "exec.js");
    try pumpUntilIdle(host);
    try expectJs(host, "ok");
}

test "yuke:exec ends a command that passes its deadline" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = "/tmp" });
    defer host.destroy();

    // The deadline must stop the command and name the outcome. A failed kill would wait 30 seconds.
    const started: std.Io.Timestamp = .now(rt.io(), .awake);
    try host.evalModule(
        \\import { exec } from "yuke:exec";
        \\globalThis.result = "pending";
        \\exec("sleep 30", { timeoutMs: 300 }).then((r) => {
        \\  globalThis.result = r.timedOut && r.code === null && r.signal === null ? "ok" : "wrong";
        \\});
    , "deadline.js");
    // The command holds a task, not the owner: the promise is pending and the owner still runs.
    try std.testing.expectEqual(@as(usize, 1), host.ops.live.items.len);
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("3 + 4"));

    try pumpUntilIdle(host);
    try expectJs(host, "ok");
    try std.testing.expect(started.durationTo(.now(rt.io(), .awake)).toNanoseconds() < 20 * std.time.ns_per_s);
}

test "yuke:diff describes a change, an equal pair, and a new file" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    // The compare stays on the owner, so this needs no reactor.
    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { diff } from "yuke:diff";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\globalThis.result = "pending";
        \\(async () => {
        \\  const changed = await diff("a.txt", "one\ntwo\n", "one\ntwo changed\n");
        \\  check("path", changed.path === "a.txt");
        \\  check("one-hunk", changed.hunks.length === 1);
        \\  const lines = changed.hunks[0].lines;
        \\  check("marks", lines[0] === " one" && lines[1] === "-two" && lines[2] === "+two changed");
        \\  check("starts", changed.hunks[0].oldStart === 1 && changed.hunks[0].newStart === 1);
        \\  check("counts", changed.hunks[0].oldLines === 2 && changed.hunks[0].newLines === 2);
        \\  // An equal pair has nothing to show, so the caller drops the view.
        \\  check("equal", (await diff("a.txt", "same\n", "same\n")).hunks.length === 0);
        \\  // A new file states an empty old side with start 0 and count 0.
        \\  const fresh = (await diff("new.txt", "", "fresh\n")).hunks[0];
        \\  check("new-file", fresh.oldStart === 0 && fresh.oldLines === 0 && fresh.lines[0] === "+fresh");
        \\  // A value of another type rejects. A conversion would run a script the argument carries.
        \\  let message = "";
        \\  try { await diff(1, "a\n", "b\n"); } catch (e) { message = e.message; }
        \\  check("number-path-rejects", message === "the path must be a string");
        \\  globalThis.result = fail.length ? fail.join(",") : "ok";
        \\})();
    , "diff.js");
    try host.drainJobs();
    try expectJs(host, "ok");
}

test "a primitive stays pending until the owner lets its task run" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = root });
    defer host.destroy();

    try host.evalModule(
        \\import { fs } from "yuke:fs";
        \\globalThis.settled = 0;
        \\fs.readFile("a.txt").then(() => { globalThis.settled = 1; });
    , "pend.js");

    // The owner has not waited, so the task has not run and the promise is still pending.
    try host.drainJobs();
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.settled"));
    try std.testing.expectEqual(@as(usize, 1), host.ops.live.items.len);

    try pumpUntilIdle(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.settled"));
}

test "a throwing await handler faults once and leaves no pending exception" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = Host.createWith(gpa.allocator(), rt.io(), .{ .cwd = root });
    defer host.destroy();

    // A resolver that throws must not leave an exception for the next owner turn.
    try host.evalModule(
        \\import { fs } from "yuke:fs";
        \\globalThis.ran = 0;
        \\fs.readFile("a.txt").then(() => { globalThis.ran = 1; throw new Error("boom"); });
    , "throwy.js");

    var rounds: u32 = 0;
    while (host.ops.live.items.len != 0) : (rounds += 1) {
        if (rounds == 64) return error.PrimitiveNeverSettled;
        host.wake.timedWait(.fromMilliseconds(1000)) catch {};
        host.wake.reset();
        // The throw happens in a job, so `pump` reports it through the job drain, not the settle.
        host.pump() catch |err| try std.testing.expectEqual(host_mod.Error.JavaScriptFault, err);
    }
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ran"));
    // The next call must see a clean context, so a later read still works.
    try host.evalModule("globalThis.after = 7;", "after.js");
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("globalThis.after"));
}

test "the yuke facade exports config, plugins, and the tool registry" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { defineConfig, plugins, tools } from "yuke";
        \\import { config } from "yuke:core";
        \\defineConfig({ keymap: { chordMs: 500 } });
        \\tools.define({
        \\  name: "facade_tool",
        \\  description: "Registered through the facade.",
        \\  parameters: { type: "object", properties: {} },
        \\  execute: async () => ({ text: "ok" }),
        \\});
        \\plugins.use({ name: "from-facade", apply: () => {} });
        \\globalThis.named = plugins.names().join(",");
        \\globalThis.chord = config.keymap.chordMs;
    , "facade-entry.js");

    // The facade reaches the same native table the engine borrows.
    try std.testing.expectEqual(@as(usize, 1), host.tools.decls.items.len);
    try std.testing.expectEqualStrings("facade_tool", host.tools.decls.items[0].name);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.named === 'from-facade' ? 1 : 0"));
    // `defineConfig` through the facade reaches the same live config object.
    try std.testing.expectEqual(@as(i32, 500), try host.evalInt("globalThis.chord"));
}

test "the facade and its internal module share one instance" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    // A second module name must not create a second plugin registry.
    try host.evalModule(
        \\import { plugins as viaFacade } from "yuke";
        \\import { plugins as viaExt } from "yuke:ext";
        \\globalThis.same = viaFacade === viaExt ? 1 : 0;
    , "identity.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.same"));
}

test "tools.define refuses a definition that is not an object" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();

    try host.evalModule(
        \\import { tools } from "yuke";
        \\let refused = 0;
        \\for (const bad of [null, undefined, "name", 7]) {
        \\  try { tools.define(bad); } catch { refused += 1; }
        \\}
        \\globalThis.refused = refused;
    , "bad-tool.js");
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.refused"));
    try std.testing.expectEqual(@as(usize, 0), host.tools.decls.items.len);
}

test "inject holds a block until every capability exists" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins, services } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const log = [];
        \\plugins.use({
        \\  name: "gated",
        \\  apply(ctx) {
        \\    log.push("apply");
        \\    ctx.inject(["cap"], (c) => {
        \\      log.push("in:" + c.cap);
        \\      return () => log.push("out");
        \\    });
        \\  },
        \\});
        \\// The plugin applies now; only the injected block waits.
        \\check("apply-ran", log.join(",") === "apply");
        \\check("absent", !services.has("cap"));
        \\
        \\const off1 = services.provide("cap", "T1");
        \\check("activated", log.join(",") === "apply,in:T1");
        \\
        \\// A second provider hides the first, so the block reads the new value.
        \\// The new block builds before the old one leaves, so a shared resource passes across.
        \\const off2 = services.provide("cap", "T2");
        \\check("restacked", log.join(",") === "apply,in:T1,in:T2,out");
        \\
        \\// The withdrawal of the live provider reveals the one below it.
        \\off2();
        \\check("revealed", log.join(",") === "apply,in:T1,in:T2,out,in:T1,out");
        \\
        \\off1();
        \\check("withdrawn", log.join(",") === "apply,in:T1,in:T2,out,in:T1,out,out");
        \\check("gone", !services.has("cap"));
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "inject-gate.js");
    try expectJs(host, "ok");
}

test "inject waits for every name and stops watching with its plugin" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins, services } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\const log = [];
        \\plugins.use({
        \\  name: "two-deps",
        \\  apply(ctx) {
        \\    ctx.inject(["a", "b"], () => {
        \\      log.push("on");
        \\      return () => log.push("off");
        \\    });
        \\  },
        \\});
        \\const offA = services.provide("a", 1);
        \\check("one-is-not-enough", log.length === 0);
        \\services.provide("b", 2);
        \\check("both", log.join(",") === "on");
        \\offA();
        \\check("lost-one", log.join(",") === "on,off");
        \\
        \\// A disposed plugin drops its watchers, so a later provider must not revive the block.
        \\plugins.dispose("two-deps");
        \\services.provide("a", 3);
        \\check("no-revival", log.join(",") === "on,off");
        \\
        \\// A repeated name registers one watcher, so one change builds the block one time.
        \\const seen = [];
        \\plugins.use({ name: "dupe", apply: (ctx) => ctx.inject(["d", "d"], () => { seen.push("built"); }) });
        \\services.provide("d", 1);
        \\check("built-once", seen.length === 1);
        \\
        \\// A provider of undefined still holds the name.
        \\const offU = services.provide("u", undefined);
        \\check("undefined-counts", services.has("u") && services.get("u") === undefined);
        \\offU();
        \\check("undefined-leaves", !services.has("u"));
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "inject-deps.js");
    try expectJs(host, "ok");
}

test "inject refuses a bad declaration and survives a throwing block" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins, services } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\let refused = 0;
        \\plugins.use({
        \\  name: "bad-args",
        \\  apply(ctx) {
        \\    for (const bad of [[], null, "tui", [""], [1]]) {
        \\      try { ctx.inject(bad, () => {}); } catch { refused += 1; }
        \\    }
        \\    try { ctx.inject(["ok"], null); } catch { refused += 1; }
        \\  },
        \\});
        \\check("refused-all", refused === 6);
        \\check("plugin-survived", !!plugins.get("bad-args"));
        \\
        \\// A block that throws reports the fault and stays inactive; the plugin keeps its other work.
        \\let sibling = 0;
        \\plugins.use({
        \\  name: "boom",
        \\  apply(ctx) {
        \\    ctx.inject(["x"], () => { throw new Error("nope"); });
        \\    sibling = 1;
        \\  },
        \\});
        \\const offX = services.provide("x", 1);
        \\check("sibling-ran", sibling === 1);
        \\check("boom-alive", !!plugins.get("boom"));
        \\offX();
        \\check("clean-withdraw", !services.has("x"));
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "inject-bad.js");
    try expectJs(host, "ok");
}

test "a disposed injection never builds from a copied watcher list" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins, services, Scope } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// The killer registers its watcher first, so it runs before the victim in one change.
        \\const log = [];
        \\plugins.use({ name: "killer", apply: (ctx) => ctx.inject(["c"], () => { plugins.dispose("victim"); }) });
        \\plugins.use({ name: "victim", apply: (ctx) => ctx.inject(["c"], () => { log.push("on"); return () => log.push("off"); }) });
        \\services.provide("c", 1);
        \\// The victim died during the same change, so its copied watcher must build nothing.
        \\check("no-orphan-build", log.join(",") === "");
        \\check("victim-gone", !plugins.get("victim"));
        \\
        \\// A block that drops its own dependency must not stay active.
        \\// The provider exists first, so the block builds at once and can withdraw it from inside.
        \\const seen = [];
        \\const offY = services.provide("y", 1);
        \\plugins.use({
        \\  name: "self-cut",
        \\  apply: (ctx) => ctx.inject(["y"], () => {
        \\    offY();
        \\    seen.push("built");
        \\    return () => seen.push("torn");
        \\  }),
        \\});
        \\check("dependency-gone", !services.has("y"));
        \\check("block-torn-down", seen.join(",") === "built,torn");
        \\
        \\// A scope disposed inside its own effect reverts that effect at once.
        \\const s = new Scope("reentrant");
        \\let cleaned = 0;
        \\s.effect(() => { s.dispose(); return () => { cleaned = 1; }; });
        \\check("reentrant-cleanup", cleaned === 1);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "inject-reentrancy.js");
    try expectJs(host, "ok");
}

test "a service event always reports the live provider" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { events } from "yuke:core";
        \\import { plugins, services } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// Record whether each announced value matched the registry at the moment it arrived.
        \\const agreed = [];
        \\events.on("service:z", (v) => agreed.push(v === services.get("z")));
        \\
        \\// This watcher replaces the provider while the first change still runs.
        \\plugins.use({
        \\  name: "chain",
        \\  apply: (ctx) => ctx.inject(["z"], () => {
        \\    if (services.get("z") === "B") services.provide("z", "C");
        \\  }),
        \\});
        \\services.provide("z", "B");
        \\
        \\check("saw-both", agreed.length === 2);
        \\check("never-stale", agreed.every((ok) => ok));
        \\check("live-is-c", services.get("z") === "C");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "service-event-live.js");
    try expectJs(host, "ok");
}

test "a capability binds onto the block that declared it" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins, services } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// A block sees the capabilities it declared, and no other.
        \\let saw = null;
        \\services.provide("alpha", { tag: "A" });
        \\services.provide("beta", { tag: "B" });
        \\plugins.use({
        \\  name: "reader",
        \\  apply: (ctx) => ctx.inject(["alpha"], (c) => { saw = { alpha: c.alpha, beta: c.beta }; }),
        \\});
        \\check("bound-declared", saw && saw.alpha && saw.alpha.tag === "A");
        \\check("undeclared-absent", saw && saw.beta === undefined);
        \\
        \\// A replaced provider rebuilds the block, so the binding is never stale.
        \\const seen = [];
        \\plugins.use({ name: "watcher", apply: (ctx) => ctx.inject(["alpha"], (c) => { seen.push(c.alpha.tag); }) });
        \\const off = services.provide("alpha", { tag: "A2" });
        \\check("rebound", seen.join(",") === "A,A2");
        \\off();
        \\check("revealed", seen.join(",") === "A,A2,A");
        \\
        \\// A capability must not shadow a context member, or the block would lose that method.
        \\let refused = 0;
        \\for (const bad of ["effect", "inject", "provide", "on", "scope", "id"]) {
        \\  try { services.provide(bad, 1); } catch { refused += 1; }
        \\}
        \\check("provide-refuses-reserved", refused === 6);
        \\
        \\let injectRefused = 0;
        \\plugins.use({
        \\  name: "reserved-dep",
        \\  apply(ctx) {
        \\    try { ctx.inject(["effect"], () => {}); } catch { injectRefused = 1; }
        \\  },
        \\});
        \\check("inject-refuses-reserved", injectRefused === 1);
        \\
        \\// `ctx.use` is gone, because a point-in-time read carries no lifetime.
        \\let hasUse = 1;
        \\plugins.use({ name: "no-use", apply(ctx) { hasUse = typeof ctx.use === "function" ? 1 : 0; } });
        \\check("use-removed", hasUse === 0);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "capability-binding.js");
    try expectJs(host, "ok");
}

test "a host with no renderer loads the view tier and leaves a view plugin inert" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = host_mod.Host.createWith(gpa.allocator(), std.testing.io, .{});
    defer host.destroy();

    // `index.js` is one file for both frontends, so a view import must load with no terminal bound.
    try host.evalModule(
        \\import { plugins, services } from "yuke:ext";
        \\import { composerVim } from "yuke:composer-vim";
        \\import { transcriptVim } from "yuke:transcript-vim";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// A view plugin holds its work behind `inject(["tui"])`, and no frontend provides that service here.
        \\let built = 0;
        \\plugins.use({ name: "probe", apply: (ctx) => ctx.inject(["tui"], () => { built += 1; }) });
        \\check("no-tui-service", services.get("tui") === undefined);
        \\check("block-never-built", built === 0);
        \\
        \\plugins.use(composerVim);
        \\plugins.use(transcriptVim);
        \\check("composer-vim-live", plugins.get("composer-vim") !== undefined);
        \\check("transcript-vim-live", plugins.get("transcript-vim") !== undefined);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "view-inert.js");
    try expectJs(host, "ok");
}

test "the kernel never imports the terminal" {
    // The headless frontend loads the kernel, so a terminal import here would pull the whole view tier.
    const source = for (host_mod.default_baked) |m| {
        if (std.mem.eql(u8, m.name, "yuke:kernel")) break m.source;
    } else return error.KernelNotBaked;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "import ")) continue;
        // `yuke:engine-native` is the engine seam, which every frontend owns.
        if (std.mem.indexOf(u8, trimmed, "\"yuke:engine-native\"") != null) continue;
        std.debug.print("\nthe kernel imports: {s}\n", .{trimmed});
        return error.KernelImportsAForbiddenModule;
    }
}

test "the kernel alone runs without the terminal tier" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    // A headless boot evaluates the kernel and the plugin runtime, and never builds a root view.
    try host.evalModule(
        \\import { events, config } from "yuke:kernel";
        \\let fired = 0;
        \\events.on("myplugin:ready", () => { fired += 1; });
        \\events.emit("myplugin:ready");
        \\globalThis.result = fired === 1 && config.keymap.chordMs > 0 ? "ok" : "bad";
    , "headless.js");
    try expectJs(host, "ok");
}

test "a change during a build rebuilds the block instead of leaving it stale" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { events } from "yuke:kernel";
        \\import { plugins, services } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// The block replaces its own provider while it builds, so the first bound value goes stale.
        \\const log = [];
        \\services.provide("x", "old");
        \\plugins.use({ name: "selfrep", apply: (ctx) => ctx.inject(["x"], (c) => {
        \\  log.push(c.x);
        \\  if (c.x === "old") services.provide("x", "new");
        \\}) });
        \\check("rebuilt-with-live-value", log.join(",") === "old,new");
        \\check("registry-agrees", services.get("x") === "new");
        \\
        \\// A block that never settles reports one fault and stops, so the build cannot spin.
        \\const faults = [];
        \\events.on("ext.error", (e, who) => faults.push(String(who)));
        \\let n = 0;
        \\services.provide("y", 0);
        \\plugins.use({ name: "churn", apply: (ctx) => ctx.inject(["y"], () => { services.provide("y", ++n); }) });
        \\check("stopped", faults.indexOf("churn") >= 0);
        \\check("bounded", n <= 16);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "inject-dirty.js");
    try expectJs(host, "ok");
}

test "a headless bus refuses a name only the view tier emits" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = host_mod.Host.createWith(gpa.allocator(), std.testing.io, .{});
    defer host.destroy();

    // Without the view tier nothing emits these names, so a listener would wait for ever.
    try host.evalModule(
        \\import { events } from "yuke:kernel";
        \\const throws = (fn) => { try { fn(); return false; } catch { return true; } };
        \\const view = ["ui.start", "key.press", "mouse.input", "session.changed", "index.changed"];
        \\const accepted = view.filter((n) => !throws(() => events.on(n, () => {})));
        \\// The neutral name stays, and an owner:event name stays free.
        \\const neutral = !throws(() => events.on("ext.error", () => {}));
        \\const owned = !throws(() => events.on("myplugin:ready", () => {}));
        \\globalThis.result = accepted.length === 0 && neutral && owned ? "ok" : "accepted:" + accepted.join("|");
    , "headless-bus.js");
    try expectJs(host, "ok");
}

test "an overlay survives a rebuild of the block that claimed it" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { root } from "yuke:core";
        \\import { plugins, services } from "yuke:ext";
        \\import { tui, tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// One long-lived layer, claimed by a block that also waits on a second capability.
        \\const layer = { name: "kept", rect: { x: 0, y: 0, w: 1, h: 1 }, draw() {} };
        \\root.pushOverlay(layer);
        \\const base = root.overlays.length;
        \\
        \\let builds = 0;
        \\services.provide("gate", 1);
        \\plugins.use({
        \\  name: "keeper",
        \\  apply: (ctx) => ctx.inject(["tui", "gate"], (c) => { builds += 1; c.tui.overlay(layer); }),
        \\});
        \\check("claimed", builds === 1 && root.overlays.indexOf(layer) >= 0);
        \\
        \\// A change of the second capability rebuilds the block; the layer must pass across.
        \\services.provide("gate", 2);
        \\check("rebuilt", builds === 2);
        \\check("layer-kept", root.overlays.indexOf(layer) >= 0);
        \\check("no-duplicate", root.overlays.length === base);
        \\
        \\// The plugin still owns it, so an unload takes the layer off the stack.
        \\plugins.dispose("keeper");
        \\check("released", root.overlays.indexOf(layer) < 0);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "overlay-rebuild.js");
    try expectJs(host, "ok");
}

test "a plugin owns the tools it defines and withdraws them on unload" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const params = { type: "object", properties: {} };
        \\
        \\plugins.use({
        \\  name: "toolbox",
        \\  apply(ctx) {
        \\    ctx.tools.define({ name: "zeta", description: "d", parameters: params, execute: async () => ({ text: "z" }) });
        \\    ctx.tools.define({ name: "alpha", description: "d", parameters: params, execute: async () => ({ text: "a" }) });
        \\  },
        \\});
        \\globalThis.result = "ok";
    , "own.js");
    try expectJs(host, "ok");

    // The plugin registered both, and the table keeps them sorted.
    try std.testing.expectEqual(@as(usize, 2), host.tools.decls.items.len);
    try std.testing.expectEqualStrings("alpha", host.tools.decls.items[0].name);
    try std.testing.expectEqualStrings("zeta", host.tools.decls.items[1].name);

    // An unload withdraws every tool the plugin owned.
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\plugins.dispose("toolbox");
        \\globalThis.result = "ok";
    , "drop.js");
    try expectJs(host, "ok");
    try std.testing.expectEqual(@as(usize, 0), host.tools.decls.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.tools.decls.items.len);

    // The name is free again, so a reload can register it.
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\const params = { type: "object", properties: {} };
        \\plugins.use({ name: "again", apply: (ctx) => {
        \\  ctx.tools.define({ name: "zeta", description: "d", parameters: params, execute: async () => ({ text: "z2" }) });
        \\} });
        \\globalThis.result = "ok";
    , "reload.js");
    try expectJs(host, "ok");
    try std.testing.expectEqual(@as(usize, 1), host.tools.decls.items.len);
}

test "one tool leaves without moving the others" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\const params = { type: "object", properties: {} };
        \\globalThis.drop = null;
        \\plugins.use({
        \\  name: "three",
        \\  apply(ctx) {
        \\    ctx.tools.define({ name: "zulu", description: "d", parameters: params, execute: async () => ({ text: "z" }) });
        \\    globalThis.drop = ctx.tools.define({ name: "bravo", description: "d", parameters: params, execute: async () => ({ text: "b" }) });
        \\    ctx.tools.define({ name: "alpha", description: "d", parameters: params, execute: async () => ({ text: "a" }) });
        \\    ctx.tools.define({ name: "mike", description: "d", parameters: params, execute: async () => ({ text: "m" }) });
        \\  },
        \\});
        \\globalThis.result = "ok";
    , "three.js");
    try expectJs(host, "ok");
    try std.testing.expectEqual(@as(usize, 4), host.tools.decls.items.len);

    // Drop the middle tool. The rest must keep their order, so the advertised prefix is unchanged.
    try host.evalModule("globalThis.drop(); globalThis.result = \"ok\";", "drop-one.js");
    try expectJs(host, "ok");
    try std.testing.expectEqual(@as(usize, 3), host.tools.decls.items.len);
    try std.testing.expectEqualStrings("alpha", host.tools.decls.items[0].name);
    try std.testing.expectEqualStrings("mike", host.tools.decls.items[1].name);
    try std.testing.expectEqualStrings("zulu", host.tools.decls.items[2].name);
}

test "a listener fault reaches the shared error bus" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { events } from "yuke:kernel";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// A throwing listener must not vanish, and the other listeners still run.
        \\const seen = [];
        \\events.on("ext.error", (e, who) => seen.push(String(who) + ":" + e.message));
        \\events.on("myplugin:go", () => { throw new Error("boom"); });
        \\events.on("myplugin:go", () => seen.push("second"));
        \\events.emit("myplugin:go");
        \\check("reported", seen.indexOf("myplugin:go:boom") >= 0);
        \\check("others-ran", seen.indexOf("second") >= 0);
        \\
        \\// A throwing `ext.error` listener must not re-enter the bus.
        \\events.on("ext.error", () => { throw new Error("second fault"); });
        \\let looped = false;
        \\try { events.emit("myplugin:go"); looped = true; } catch { looped = true; }
        \\check("no-recursion", looped);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "bus-fault.js");
    try expectJs(host, "ok");
}

test "RPC interaction answers correlated promises out of order" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { rpcInteractionPlugin } from "yuke:interaction";
        \\plugins.use(rpcInteractionPlugin);
        \\globalThis.result = "pending";
        \\plugins.use({ name: "ask", apply(ctx) {
        \\  const a = ctx.interaction.confirm("first", "one");
        \\  const b = ctx.interaction.select("second", ["red", "blue"]);
        \\  Promise.all([a, b]).then((answers) => { globalThis.result = JSON.stringify(answers); });
        \\} });
    , "interaction.js");

    // The host refuses an answer to a question the frontend has not seen.
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{
        .interaction_id = 1,
        .response = .{ .confirm = .{ .value = true } },
    }));
    const first = host.interactions.takeNext().?;
    try std.testing.expectEqualStrings("first", first.request.confirm.title);
    const second = host.interactions.takeNext().?;
    try std.testing.expectEqualStrings("second", second.request.select.title);
    try std.testing.expect(host.interactions.takeNext() == null);

    try std.testing.expectError(error.InvalidSelection, host.interactions.respond(.{
        .interaction_id = second.interaction_id,
        .response = .{ .select = .{ .value = "green" } },
    }));
    try std.testing.expectError(error.ResponseMismatch, host.interactions.respond(.{
        .interaction_id = second.interaction_id,
        .response = .{ .input = .{ .value = "blue" } },
    }));
    try host.interactions.respond(.{
        .interaction_id = second.interaction_id,
        .response = .{ .select = .{ .value = "blue" } },
    });
    try host.interactions.respond(.{
        .interaction_id = first.interaction_id,
        .response = .{ .confirm = .{ .value = true } },
    });
    try host.pump();
    try expectJs(host, "[true,\"blue\"]");
}

test "disposing an interaction consumer cancels only its pending dialog" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { rpcInteractionPlugin } from "yuke:interaction";
        \\plugins.use(rpcInteractionPlugin);
        \\globalThis.result = "pending";
        \\plugins.use({ name: "ask", apply(ctx) {
        \\  ctx.interaction.input("value").then((answer) => {
        \\    globalThis.result = answer === undefined ? "canceled" : answer;
        \\  });
        \\} });
    , "interaction-cancel.js");
    const interaction_id = host.interactions.takeNext().?.interaction_id;

    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\plugins.dispose("ask");
    , "interaction-dispose.js");
    try host.pump();
    try expectJs(host, "canceled");
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{
        .interaction_id = interaction_id,
        .response = .{ .input = .{ .value = "late" } },
    }));
}

test "the TUI interaction provider answers select and input dialogs" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 50);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import { tuiInteractionPlugin } from "yuke:interaction-ui";
        \\plugins.use(tuiPlugin);
        \\plugins.use(tuiInteractionPlugin);
        \\globalThis.result = "pending";
        \\plugins.use({ name: "ask", async apply(ctx) {
        \\  const selected = await ctx.interaction.select("pick", ["alpha", "beta"]);
        \\  const entered = await ctx.interaction.input("name", "value");
        \\  globalThis.result = selected + ":" + entered;
        \\} });
    , "interaction-tui.js");

    const loop = @import("loop.zig");
    try loop.start(host);
    try loop.step(host, .{ .key_press = .{ .codepoint = '\r' } });
    try loop.step(host, .{ .key_press = .{ .codepoint = 'x' } });
    try loop.step(host, .{ .key_press = .{ .codepoint = '\r' } });
    try expectJs(host, "alpha:x");
}

test "a composition with no answerer refuses every question" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\globalThis.result = "pending";
        \\plugins.use({ name: "ask", apply(ctx) {
        \\  try { ctx.interaction.notify("hello"); } catch (e) { globalThis.sync = e.name; }
        \\  ctx.interaction.confirm("allow").catch((e) => { globalThis.result = globalThis.sync + ":" + e.name; });
        \\} });
    , "no-answerer.js");
    try host.pump();
    try expectJs(host, "InteractionUnavailable:InteractionUnavailable");
}

test "an install replaces the answerer and its disposer restores the last one" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { interaction, plugins } from "yuke:ext";
        \\const answerer = (tag) => ({ surfaceFor: () => ({ notify: (m) => { globalThis.heard.push(tag + ":" + m); } }) });
        \\globalThis.heard = [];
        \\const first = interaction.install(answerer("first"));
        \\plugins.use({ name: "reporter", apply(ctx) { globalThis.say = (m) => ctx.interaction.notify(m); } });
        \\globalThis.say("a");
        \\const second = interaction.install(answerer("second"));
        \\globalThis.say("b");
        \\second();
        \\globalThis.say("c");
        \\first();
        \\globalThis.result = globalThis.heard.join(",");
    , "install-stack.js");
    try expectJs(host, "first:a,second:b,first:c");
}

test "yuke:ui transcript renders evicted history exactly" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 32);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const messages = [];
        \\const parts = {};
        \\for (let i = 0; i < 120; i++) {
        \\  const id = "m" + i;
        \\  messages.push({ id, type: "assistant" });
        \\  parts[id] = [{ type: "text", id: 0, text: "alpha " + i + " bravo charlie delta ".repeat(4) + "\n```zig\nconst x = " + i + ";\n```" }];
        \\}
        \\parts.m0 = [{ type: "reasoning", id: 1, text: "old thought" }, { type: "text", id: 2, text: "old answer" }];
        \\parts.m40 = [{ type: "reasoning", id: 1, text: "middle thought" }, { type: "text", id: 2, text: "middle answer" }];
        \\parts.m119 = [{ type: "tool", id: 3, name: "exec", arguments: '{"command":"old"}', state: { type: "completed", output: "old output" } }];
        \\const make = () => new Transcript({ partsOf: (id) => parts[id] || [] });
        \\const t = make();
        \\t.setOutline(messages, null);
        \\const frame = (w, h) => { term.beginFrame(); t.draw({ x: 0, y: 0, w, h }); term.endFrame(); };
        \\// Each reference message renders alone, so the index under test never checks itself.
        \\const folds = { m0: 1, m119: 3 };
        \\const reference = (w) => messages.flatMap((m) => {
        \\  const one = make();
        \\  one.setOutline([m], null);
        \\  if (folds[m.id] != null) one.togglePart(m.id, folds[m.id]);
        \\  return one.rows(w, 0, one.rowCount(w));
        \\});
        \\let builds = 0;
        \\const rowsOf = t._rowsOf;
        \\t._rowsOf = function(m, w) { const c = this._rows.get(String(m.id)); if (!c || c.w !== w) builds++; return rowsOf.call(this, m, w); };
        \\
        \\for (const id in folds) t.togglePart(id, folds[id]);
        \\const wide = reference(32);
        \\check("total", t.rowCount(32) === wide.length);
        \\frame(32, 8);
        \\check("tail-rows", JSON.stringify(t.rows(32, wide.length - 8, 8)) === JSON.stringify(wide.slice(-8)));
        \\check("tail-sticks", t.pager.atBottom() && t.pager.stuck);
        \\builds = 0;
        \\t.rowCount(32);
        \\t.rows(32, wide.length - 8, 8);
        \\check("warm-tail-builds-nothing", builds === 0);
        \\check("tail-position", t.posAt(4, 7, false)?.id === "m119");
        \\
        \\// A selection spans evicted history, and survives an eviction and a resize.
        \\t.select(t.posAtSource("m0", 0), t.posAtSource("m119", 1000000));
        \\const selected = t.selectedText();
        \\const source = t.selectedSource();
        \\check("selection", selected.includes("old thought") && selected.includes("old output") && source.includes("middle answer"));
        \\t.rows(32, 0, 8);
        \\t.rows(32, wide.length - 8, 8);
        \\check("selection-after-eviction", t.selectedText() === selected && t.selectedSource() === source);
        \\const narrow = reference(18);
        \\check("resize-total", t.rowCount(18) === narrow.length);
        \\const plain = (rows) => rows.map(({ sel, ...row }) => row); // the reference holds no selection
        \\check("resize-tail-rows", JSON.stringify(plain(t.rows(18, narrow.length - 8, 8))) === JSON.stringify(narrow.slice(-8)));
        \\check("selection-after-resize", t.selectedSource() === source);
        \\
        \\// A fold on an evicted message changes the count and shows at its own location.
        \\t.clearSelection();
        \\t.rows(18, narrow.length - 8, 8);
        \\check("middle-evicted", !t._rows.has("m40"));
        \\const before = t.rowCount(18);
        \\t.togglePart("m40", 1);
        \\check("fold-count", t.rowCount(18) > before);
        \\check("fold-marker", t.rows(18, t._globalRow({ id: "m40", row: 0, col: 0 }), 4).some((r) => r.marker === "▾"));
        \\
        \\// The viewport stays cached whole, and a part motion reads only its neighbours.
        \\t.rows(18, 0, 8);
        \\builds = 0;
        \\t.rows(18, 0, 8);
        \\check("viewport-cached", builds === 0);
        \\builds = 0;
        \\const next = t.partStep({ id: "m50", row: 0, col: 0 }, 1);
        \\const previous = t.partStep(next, -1);
        \\check("part-motion-local", next?.id === "m51" && previous?.id === "m50" && builds <= 4);
        \\
        \\// A code-block query over plain text parses on demand and leaves the row index alone.
        \\const code = new Transcript({ textOf: (id) => "```zig\nconst x = " + id + ";\n```" });
        \\code.setOutline(messages, null);
        \\const codeTotal = code.rowCount(32);
        \\builds = 0;
        \\const codeRowsOf = code._rowsOf;
        \\code._rowsOf = function(m, w) { builds++; return codeRowsOf.call(this, m, w); };
        \\check("code-blocks", code.codeBlocks().length === messages.length && code.rowCount(32) === codeTotal && builds === 0);
        \\
        \\// Message ids repeat across sessions, so an empty outline clears even a message whose fold moved after its eviction.
        \\parts.m40 = [{ type: "text", id: 2, text: "other session" }];
        \\t.setOutline([], null);
        \\t.setOutline([{ id: "m40", type: "assistant" }], null);
        \\check("switch-clears-parts", t.rows(18, 0, 4).some((r) => (r.segments || []).map(s => s.text).join("").includes("other session")));
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "transcript-eviction.js");
    try expectJs(host, "ok");
}

test "yuke:ui transcript keeps committed renders across a reload" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var paint: Paint = undefined;
    try paint.setup(gpa.allocator(), 12, 40);
    defer paint.deinit();
    const host = Host.create(gpa.allocator());
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const parts = {
        \\  old: [{ type: "text", id: 0, text: "old committed" }],
        \\  gone: [{ type: "text", id: 0, text: "truncated" }],
        \\  live: [{ type: "reasoning", id: 0, text: "live thought" }],
        \\};
        \\const t = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
        \\const draw = () => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: 12 }); term.endFrame(); };
        \\const shows = (text) => t.rows(40, 0, 12).some((r) => (r.segments || []).map(s => s.text).join("").includes(text));
        \\t.setOutline([{ id: "old", type: "assistant" }, { id: "gone", type: "assistant" }], { id: "live", type: "assistant" });
        \\draw();
        \\const oldRows = JSON.stringify(t.rows(40, 0, t.rowCountOf("old")));
        \\const liveCount = t.rowCountOf("live");
        \\check("active-expanded", t.rows(40, t._globalRow({ id: "live", row: 0, col: 0 }), 4).some((r) => r.marker === "▾"));
        \\const rebuilt = [];
        \\const rowsOf = t._rowsOf;
        \\t._rowsOf = function(m, w) { rebuilt.push(String(m.id)); return rowsOf.call(this, m, w); };
        \\
        \\// A commit reloads the outline: the committed render stays, and only the former draft rebuilds, now collapsed.
        \\t.setOutline([{ id: "old", type: "assistant" }, { id: "gone", type: "assistant" }, { id: "live", type: "assistant" }], null);
        \\const committedCount = t.rowCount(40);
        \\t._rowsOf = rowsOf;
        \\check("old-render-kept", JSON.stringify(t.rows(40, 0, t.rowCountOf("old"))) === oldRows);
        \\check("only-draft-rebuilt", rebuilt.join(",") === "live");
        \\check("draft-collapsed", t.rowCountOf("live") < liveCount && t.rows(40, t._globalRow({ id: "live", row: 0, col: 0 }), 3).some((r) => r.marker === "▸"));
        \\
        \\// A truncation removes the rows of the message it cut.
        \\const goneCount = t.rowCountOf("gone");
        \\t.setOutline([{ id: "old", type: "assistant" }, { id: "live", type: "assistant" }], null);
        \\check("truncated-removed", t.rowCountOf("gone") === 0 && t.rowCount(40) === committedCount - goneCount && !shows("truncated"));
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "transcript-reload-reuse.js");
    try expectJs(host, "ok");
}
