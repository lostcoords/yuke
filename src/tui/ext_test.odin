package tui

import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "src:js"

@(private = "file")
ext_test_result :: proc(t: ^testing.T, h: ^Host) -> string {
    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)

    value := qjs.get_property(h.js.ctx, global, "result")
    defer qjs.free_value(h.js.ctx, value)

    result, ok := qjs.to_string(h.js.ctx, value)
    if !testing.expect(t, ok, "ext test result should be readable") do return ""

    defer qjs.free_string(h.js.ctx, result)

    return strings.clone(result, context.temp_allocator)
}

@(private = "file")
ext_test_host_init :: proc(t: ^testing.T, h: ^Host) -> bool {
    h.allocator = context.allocator
    // yuke:core imports yuke:term; installing the native term module lets core resolve.
    modules := [1]js.Module{term_module()}

    return testing.expect_value(
        t,
        js.init(&h.js, {modules = modules[:], user = h, resolve = host_resolve, allocator = context.allocator}),
        js.Error.None,
    )
}

// Exercises the plugin kernel (scope/effect, emitter, advice, command/keymap disposers, plugin
// lifecycle) in one module. Each check pushes its name to `fail` on a miss; "ok" means all passed.
@(test)
test_ext_kernel :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !ext_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { command, keymap, events, Emitter } from "yuke:core";
        import { Scope, Context, advice, plugins } from "yuke:ext";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };

        // Scope reverts effects LIFO (newest first).
        {
          const order = [];
          const s = new Scope("t");
          s.effect(() => { order.push("a-set"); return () => order.push("a"); });
          s.effect(() => { order.push("b-set"); return () => order.push("b"); });
          s.effect(() => { order.push("c-set"); return () => order.push("c"); });
          s.dispose();
          check("lifo", order.join(",") === "a-set,b-set,c-set,c,b,a");
        }

        // A disposer runs its cleanup once, whether called manually or via dispose.
        {
          let n = 0;
          const s = new Scope("t2");
          const off = s.effect(() => () => n++);
          off(); off();
          s.dispose();
          check("effect-idempotent", n === 1);
        }

        // emit runs every listener and isolates a throwing one.
        {
          const em = new Emitter();
          em.onError = () => {};
          let hits = 0;
          em.on("x", () => { hits++; throw new Error("boom"); });
          em.on("x", () => { hits++; });
          em.emit("x");
          check("emit-isolate", hits === 2);
        }

        // bail stops at the first listener that claims the event.
        {
          const em = new Emitter();
          const seen = [];
          em.on("k", () => { seen.push(1); });
          em.on("k", () => { seen.push(2); return "claimed"; });
          em.on("k", () => { seen.push(3); });
          const r = em.bail("k");
          check("bail", r === "claimed" && seen.join(",") === "1,2");
        }

        // Context.on subscribes on the shared bus and is removed when its scope disposes.
        {
          const s = new Scope("t5");
          const ctx = new Context(s, "p5");
          let got = 0;
          ctx.on("evt5", () => got++);
          events.emit("evt5");
          s.dispose();
          events.emit("evt5");
          check("ctx-on-dispose", got === 1);
        }

        // command.add returns a disposer that removes exactly what it added.
        {
          const off = command.add(null, { "test:cmd6": () => {} });
          const present = !!command.map["test:cmd6"];
          off();
          check("command-dispose", present && !command.map["test:cmd6"]);
        }

        // keymap.add returns a disposer that removes the bind and clears a now-unused prefix.
        {
          const off = keymap.add({ "ctrl+x g": () => true });
          const hadPrefix = keymap.prefixes["ctrl+x"] === true;
          off();
          check("keymap-dispose", hadPrefix && !keymap.map["ctrl+x g"] && !keymap.prefixes["ctrl+x"]);
        }

        // advice composes before/around/filterReturn/after, then fully restores on removal.
        {
          const obj = { hits: [], greet(n) { this.hits.push("orig:" + n); return "hi " + n; } };
          const original = obj.greet;
          const offs = [
            advice.advise(obj, "greet", "before", function (n) { this.hits.push("before:" + n); }, { owner: "o", name: "b" }),
            advice.advise(obj, "greet", "after", function (n) { this.hits.push("after:" + n); }, { owner: "o", name: "a" }),
            advice.advise(obj, "greet", "around", function (orig, n) { return orig(n.toUpperCase()); }, { owner: "o", name: "ar" }),
            advice.advise(obj, "greet", "filterReturn", function (r) { return r + "!"; }, { owner: "o", name: "f" }),
          ];
          const out = obj.greet("bob");
          check("advice-compose", out === "hi BOB!" && obj.hits.join(",") === "before:bob,orig:BOB,after:bob");
          for (const off of offs) off();
          check("advice-restore", obj.greet === original);
        }

        // Re-adding the same owner+name replaces in place rather than stacking.
        {
          const obj = { log: [], f() { this.log.push("orig"); } };
          advice.advise(obj, "f", "before", function () { this.log.push("v1"); }, { owner: "o", name: "n" });
          const off2 = advice.advise(obj, "f", "before", function () { this.log.push("v2"); }, { owner: "o", name: "n" });
          const replaced = advice.list(obj, "f").length === 1;
          obj.f();
          off2();
          check("advice-replace", replaced && obj.log.join(",") === "v2,orig" && advice.list(obj, "f").length === 0);
        }

        // A plugin's registrations appear on use, vanish on dispose, and return on reload.
        {
          const p = { name: "demo9", apply(ctx) { ctx.command(null, { act: () => {} }); } };
          plugins.use(p);
          const present = !!command.map["demo9:act"];
          plugins.dispose("demo9");
          const gone = !command.map["demo9:act"];
          plugins.use(p);
          const back = !!command.map["demo9:act"];
          plugins.dispose("demo9");
          check("plugin-lifecycle", present && gone && back);
        }

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:ext-kernel", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The default UI registers its stock commands and keybinds through the plugin kernel: evaluating
// the baked app leaves app:quit and focus:left registered, space bound, and "app-keys" live.
@(test)
test_defaults_registers_stock_keys :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    h.allocator = context.allocator
    // core imports yuke:term; defaults imports yuke:client.
    modules := [2]js.Module{term_module(), client_module()}
    ok := js.init(&h.js, {modules = modules[:], user = &h, resolve = host_resolve, allocator = context.allocator})
    if !testing.expect_value(t, ok, js.Error.None) do return

    defer js.destroy(&h.js)

    // The default connection service requests ticks at load; with no event loop wired here, mark
    // the host done so term.setNeedsTick short-circuits instead of arming a timer.
    h.done = true

    source := `
        import "yuke:defaults";
        import { command, keymap } from "yuke:core";
        import { plugins } from "yuke:ext";
        globalThis.result = [
          !!command.map["app:quit"],
          !!command.map["focus:left"],
          keymap.map["ctrl+p"] && keymap.map["ctrl+p"][0] === "ui:palette",
          keymap.map["ctrl+k h"] && keymap.map["ctrl+k h"][0] === "focus:left",
          keymap.map["ctrl+k left"] && keymap.map["ctrl+k left"][0] === "focus:left",
          !keymap.map["ctrl+w h"],
          !keymap.map[" "],
          !keymap.map[":"],
          plugins.names().indexOf("app-keys") >= 0,
        ].join(":");
    `
    testing.expect(t, js.eval_module(&h.js, "test:defaults-keys", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "true:true:true:true:true:true:true:true:true")
}

// The node-tree layout engine: branch/leaves order, row/col geometry with a one-cell divider,
// split, close collapsing a parent onto its sibling, and geometric focus movement.
@(test)
test_node_tree :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !ext_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { Node, RootView } from "yuke:core";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };
        const view = (id) => ({ id, rect: { x: 0, y: 0, w: 0, h: 0 } });

        // branch keeps leaves in a, b order.
        {
          const a = view("a"), b = view("b");
          const root = Node.branch("row", new Node(a), new Node(b), 0.5);
          const ls = root.leaves();
          check("leaves", ls.length === 2 && ls[0].view === a && ls[1].view === b);
        }

        // row split: 21 wide -> total 20, each child 10, divider at x=10.
        {
          const a = view("a"), b = view("b");
          Node.branch("row", new Node(a), new Node(b), 0.5).layout({ x: 0, y: 0, w: 21, h: 10 });
          check("row-layout", a.rect.x === 0 && a.rect.w === 10 && b.rect.x === 11 && b.rect.w === 10 && b.rect.h === 10);
        }

        // col split: 21 tall -> each child 10, divider at y=10.
        {
          const a = view("a"), b = view("b");
          Node.branch("col", new Node(a), new Node(b), 0.5).layout({ x: 0, y: 0, w: 10, h: 21 });
          check("col-layout", a.rect.y === 0 && a.rect.h === 10 && b.rect.y === 11 && b.rect.h === 10);
        }

        // a starved split still leaves each child at least one cell.
        {
          const a = view("a"), b = view("b");
          Node.branch("row", new Node(a), new Node(b), 0.0).layout({ x: 0, y: 0, w: 3, h: 1 });
          check("clamp", a.rect.w === 1 && b.rect.w === 1);
        }

        // split turns the active leaf into a split and focuses the new view.
        {
          const a = view("a"), b = view("b");
          const rv = new RootView();
          rv.setRoot(new Node(a));
          const activeWasA = rv.active === a;
          const leaf = rv.split("row", b);
          check("split", activeWasA && rv.root_node.leaves().length === 2 && rv.active === b && rv.activeLeaf === leaf);
        }

        // closing a leaf collapses its parent onto the sibling; the lone leaf cannot close.
        {
          const a = view("a"), b = view("b");
          const rv = new RootView();
          rv.setRoot(new Node(a));
          rv.split("row", b);
          rv.close();
          const collapsed = rv.root_node.leaves().length === 1 && rv.active === a;
          rv.close();
          check("close", collapsed && rv.root_node.leaves().length === 1 && rv.active === a);
        }

        // focusDir walks between row leaves by geometry.
        {
          const a = view("a"), b = view("b");
          const rv = new RootView();
          rv.setRoot(Node.branch("row", new Node(a), new Node(b), 0.5));
          rv.root_node.layout({ x: 0, y: 0, w: 20, h: 10 });
          rv.focusLeaf(rv.root_node.leaves()[0]);
          const startA = rv.active === a;
          rv.focusDir("l");
          const wentRight = rv.active === b;
          rv.focusDir("h");
          check("focus-dir", startA && wentRight && rv.active === a);
        }

        // setRoot detaches a reused subtree so the root-has-no-parent invariant holds; closing the
        // lone root leaf is then a safe no-op.
        {
          const tree = Node.branch("row", new Node(view("a")), new Node(view("b")), 0.5);
          const rv = new RootView();
          rv.setRoot(tree.b);
          const detached = tree.b.parent === null;
          rv.close();
          check("setroot-detach", detached && rv.root_node === tree.b && rv.root_node.leaves().length === 1);
        }

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:node-tree", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The fuzzy scorer and picker: subsequence matching, boundary/consecutive bonuses, ranking order,
// and that typing into a Picker filters + ranks and highlights the best match.
@(test)
test_fuzzy_picker :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !ext_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { fuzzyMatch, fuzzyRank, Picker } from "yuke:ui";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };

        check("no-match", fuzzyMatch("hello", "xyz") === null);
        check("match-num", typeof fuzzyMatch("hello", "hlo") === "number");
        check("empty", fuzzyMatch("hello", "") === 0);

        // "ap" scores higher on "apple" (boundary + consecutive) than on "grape" (mid-word).
        check("boundary", fuzzyMatch("apple", "ap") > fuzzyMatch("grape", "ap"));

        // "fb" ranks "foo-bar" (f at start, b after a separator) above "affable" (both mid-word).
        {
          const r = fuzzyRank(["affable", "foo-bar", "zzz"], "fb", (s) => s);
          check("rank", r.length === 2 && r[0] === "foo-bar");
        }

        // An empty query keeps input order.
        check("rank-empty", fuzzyRank(["c", "a", "b"], "", (s) => s).join("") === "cab");

        // Picker: typing filters + ranks and selects the best match.
        {
          const p = new Picker({
            items: [{ n: "apple" }, { n: "grape" }, { n: "maple" }],
            key: (x) => x.n,
            filterText: (x) => x.n,
            format: (x) => x.n,
          });
          const allThree = p.list.items.length === 3;
          p.query = "pl";
          p.refilter();
          const filtered = p.list.items.map((x) => x.n).sort().join(",");
          const bestSelected = p.list.selectedKey === p.list.items[0].n;
          check("picker", allThree && filtered === "apple,maple" && bestSelected);
        }

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:fuzzy-picker", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The composer input: typing appends, backspace deletes, a non-text key passes through (returns
// false so the owner can route it), and Enter submits a trimmed non-empty message and clears.
@(test)
test_composer :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !ext_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { Composer } from "yuke:ui";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };

        let submitted = null;
        const c = new Composer({ onSubmit: (t) => { submitted = t; } });
        const ch = (x) => ({ code: "char", char: x, mods: 0 });

        check("type", c.onKey(ch("h")) === true && (c.onKey(ch("i")), c.text === "hi"));
        check("backspace", c.onKey({ code: "backspace", mods: 0 }) === true && c.text === "h");
        check("passthrough", c.onKey({ code: "up", mods: 0 }) === false);

        // Readline editing: ctrl+w (mods bit 4 = ctrl) erases the last word, ctrl+u clears the line.
        c.text = "foo bar baz";
        check("ctrl-w-werase", c.onKey({ code: "char", char: "w", mods: 4 }) === true && c.text === "foo bar ");
        check("ctrl-u-clear", c.onKey({ code: "char", char: "u", mods: 4 }) === true && c.text === "");
        c.text = "h"; // restore for the enter check below

        c.onKey(ch("!"));
        check("enter", c.onKey({ code: "enter", mods: 0 }) === true && submitted === "h!" && c.text === "");

        submitted = null;
        c.onKey({ code: "enter", mods: 0 });
        check("empty-submit", submitted === null);

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:composer", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The chat transcript over a session snapshot: adaptSnapshot flattens committed + active messages
// (id stringified, non-text parts dropped), the layout wraps to width, and the Pager scrolls.
@(test)
test_transcript_snapshot_scroll :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    h.allocator = context.allocator
    // core imports yuke:term; defaults imports yuke:client.
    modules := [2]js.Module{term_module(), client_module()}
    ok := js.init(&h.js, {modules = modules[:], user = &h, resolve = host_resolve, allocator = context.allocator})
    if !testing.expect_value(t, ok, js.Error.None) do return

    defer js.destroy(&h.js)

    // The default connection service requests ticks at load; mark the host done so term.setNeedsTick
    // short-circuits instead of arming a timer with no event loop wired here.
    h.done = true

    source := `
        import { Transcript, Pager } from "yuke:ui";
        import { adaptSnapshot, ChatView } from "yuke:defaults";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };

        // adaptSnapshot: committed messages then the active draft; ids stringified; reasoning dropped.
        const snap = {
          sessionId: "0123456789abcdef", sync: "synced", rev: 5, hasMore: false,
          messages: [
            { type: "user", id: 1, content: [{ type: "text", text: "the quick brown fox jumps over the lazy dog" }, { type: "reasoning", text: "hidden" }] },
            { type: "assistant", id: 2, content: [{ type: "text", text: "ok" }] },
          ],
          active: { type: "assistant", id: 3, content: [{ type: "text", text: "streaming reply in progress here" }] },
        };
        const msgs = adaptSnapshot(snap);
        check("count", msgs.length === 3);
        check("ids", msgs.map((m) => m.id).join(",") === "1,2,3");
        check("id-type", typeof msgs[0].id === "string");
        check("reasoning-dropped", msgs[0].content.length === 1 && msgs[0].content[0].type === "text");
        check("rev", msgs[0].rev === 0 && msgs[2].rev === 5);
        check("empty-null", adaptSnapshot(null).length === 0);

        // Layout wraps to a narrow width: rows exceed message count, the user's first row carries the
        // gutter marker and the tinted band.
        const tx = new Transcript();
        tx.setMessages(msgs);
        tx._layout(12);
        const rows = tx.pager.rows;
        check("wrapped", rows.length >= 8);
        check("marker", rows[0].marker === "⟩" && rows[0].bg === "TxUser");

        // Pager scroll: stuck follows the tail, then top/bottom/step (clamped) and vim keys.
        const p = new Pager();
        p.setRows(Array.from({ length: 20 }, (_, i) => ({ text: "row" + i, key: i })));
        p._h = 5;
        p.setRows(p.rows);
        check("stuck", p.scroll === 15 && p.atBottom());
        p.toTop();
        check("top", p.scroll === 0 && p.stuck === false);
        p.scrollBy(3);
        check("step", p.scroll === 3);
        p.scrollBy(-9);
        check("clamp", p.scroll === 0);

        const key = (char) => ({ type: "key", code: "char", char, mods: 0 });
        p.toBottom();
        p.onKey(key("k"));
        check("k-up", p.scroll === 14);
        p.onKey(key("g"));
        p.onKey(key("g"));
        check("gg-top", p.scroll === 0);
        p.onKey(key("G"));
        check("G-bottom", p.scroll === 15 && p.stuck === true);

        // ChatView routing: the composer owns typing; only non-text keys scroll the transcript, so
        // typing "j" inserts (never scrolls) while page_up scrolls without disturbing the draft.
        const chat = new ChatView();
        chat.setMessages(msgs);
        chat.transcript._layout(40);
        chat.transcript.pager._h = 3;
        chat.transcript.pager.toBottom();
        const atBottom = chat.transcript.pager.scroll;
        check("type-to-composer", chat.onKey({ code: "char", char: "j", mods: 0 }) === true && chat.composer.text === "j" && chat.transcript.pager.scroll === atBottom);
        check("pageup-scrolls", chat.onKey({ code: "page_up", mods: 0 }) === true && chat.transcript.pager.scroll < atBottom && chat.composer.text === "j");

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:transcript-scroll", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The opt-in vim layer: loading the plugin flips the focused chat composer to normal (input
// disabled), binds :/i/a, and reverts everything on unload so the composer types again.
@(test)
test_vim_mode_toggle :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    h.allocator = context.allocator
    modules := [2]js.Module{term_module(), client_module()}
    ok := js.init(&h.js, {modules = modules[:], user = &h, resolve = host_resolve, allocator = context.allocator})
    if !testing.expect_value(t, ok, js.Error.None) do return

    defer js.destroy(&h.js)

    h.done = true

    source := `
        import { ChatView } from "yuke:defaults";
        import { root, command, keymap } from "yuke:core";
        import { plugins } from "yuke:ext";
        import { vim } from "yuke:vim";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };

        root.draw = () => {}; // headless: mode changes call root.invalidate(), skip painting

        const chat = new ChatView();
        root.setActive(chat);

        // Default: insert mode, composer types.
        check("insert-default", chat.composer.mode === "insert");
        chat.composer.onKey({ code: "char", char: "x", mods: 0 });
        check("types-in-insert", chat.composer.text === "x");

        // Load vim: the focused chat flips to normal, text input is disabled, keys are bound.
        plugins.use(vim);
        check("normal-on-load", chat.composer.mode === "normal");
        check("normal-ignores-text", chat.composer.onKey({ code: "char", char: "y", mods: 0 }) === false && chat.composer.text === "x");
        check("colon-bound", keymap.map[":"] && keymap.map[":"][0] === "vim:cmdline");
        check("i-bound", keymap.map["i"] && keymap.map["i"][0] === "vim:insert");
        check("ctrl-w-window", keymap.map["ctrl+w h"] && keymap.map["ctrl+w h"][0] === "focus:left");

        // i -> insert, esc -> normal (predicate: a chat is focused).
        command.perform("vim:insert");
        check("i-enters-insert", chat.composer.mode === "insert");
        command.perform("vim:normal");
        check("esc-enters-normal", chat.composer.mode === "normal");

        // Unload reverts: composer types again and the vim keys are gone.
        plugins.dispose("vim");
        check("unload-insert", chat.composer.mode === "insert");
        check("keys-reverted", !keymap.map[":"] && !keymap.map["i"] && !keymap.map["a"] && !keymap.map["ctrl+w h"]);

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:vim-toggle", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}
