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

        // A rejecting onSubmit (returns false, e.g. no open session) keeps the text; the line does
        // not clear. Any other return accepts and clears.
        const r = new Composer({ onSubmit: () => false });
        r.text = "keep me";
        check("reject-keeps", r.onKey({ code: "enter", mods: 0 }) === true && r.text === "keep me");

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:composer", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The shared edit buffer: mid-line insert/delete, caret movement, word-erase and kill-to-start act
// at the caret, onChange fires on text change only, and movement/deletion step by grapheme cluster.
@(test)
test_text_input :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !ext_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { TextInput } from "yuke:core";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };
        const ch = (x) => ({ code: "char", char: x, mods: 0 });
        const key = (code) => ({ code, mods: 0 });
        const ctrl = (x) => ({ code: "char", char: x, mods: 4 });

        const t = new TextInput();
        t.onKey(ch("a")); t.onKey(ch("b")); t.onKey(ch("c"));
        check("type", t.text === "abc" && t.caret === 3);

        t.onKey(key("left")); t.onKey(key("left"));
        check("left", t.caret === 1);
        t.onKey(ch("X"));
        check("insert-mid", t.text === "aXbc" && t.caret === 2);
        t.onKey(key("backspace"));
        check("bksp-mid", t.text === "abc" && t.caret === 1);
        t.onKey(key("delete"));
        check("del-fwd", t.text === "ac" && t.caret === 1);

        t.onKey(key("home"));  check("home", t.caret === 0);
        t.onKey(key("end"));   check("end", t.caret === 2);
        t.onKey(ctrl("a"));    check("ctrl-a", t.caret === 0);
        t.onKey(ctrl("e"));    check("ctrl-e", t.caret === 2);

        // Word-erase and kill-to-start act on the span before the caret, not the whole tail.
        t.setText("foo bar baz");
        t.onKey(key("left")); t.onKey(key("left")); t.onKey(key("left"));
        check("caret-mid", t.caret === 8);
        t.onKey(ctrl("w"));
        check("ctrl-w-mid", t.text === "foo baz" && t.caret === 4);
        t.onKey(ctrl("u"));
        check("ctrl-u-kill", t.text === "baz" && t.caret === 0);

        // onChange fires on edits, not bare caret moves; setText is silent.
        let changes = 0;
        const u = new TextInput({ onChange: () => changes++ });
        u.onKey(ch("x"));
        u.onKey(key("left")); u.onKey(key("right"));
        check("onchange-edit-only", changes === 1);
        u.setText("hello");
        check("settext-silent", changes === 1 && u.caret === 5);

        // An astral cluster (a surrogate pair) is one step and deletes whole.
        const g = new TextInput();
        g.setText("a😀b");
        g.onKey(key("left"));
        check("astral-step", g.caret === 3);
        g.onKey(key("left"));
        check("astral-step2", g.caret === 1);
        g.onKey(key("delete"));
        check("astral-del", g.text === "ab" && g.caret === 1);

        globalThis.result = fail.length ? fail.join(",") : "ok";
    `

    testing.expect(t, js.eval_module(&h.js, "test:text-input", source, context.allocator))
    testing.expect_value(t, ext_test_result(t, &h), "ok")
}

// The virtualized transcript: descriptors + on-demand text via textOf, wrapping to width and
// returning only the visible rows; setActive re-wraps just the draft; the Pager scrolls.
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
        import { ChatView } from "yuke:defaults";

        const fail = [];
        const check = (name, cond) => { if (!cond) fail.push(name); };

        // Descriptors + a text provider; the transcript pulls text on demand and wraps to width.
        const textMap = {
          1: "the quick brown fox jumps over the lazy dog",
          2: "ok",
          3: "streaming reply in progress here",
        };
        const tx = new Transcript({ textOf: (id) => textMap[id] || "" });
        tx.setOutline([{ id: 1, type: "user" }, { id: 2, type: "assistant" }], { id: 3, type: "assistant" });

        // Row count at a narrow width exceeds the message count (wrapping), and rows() returns only
        // the visible window: the first row is the user message's gutter marker + tinted band.
        const total = tx.rowCount(12);
        check("wrapped", total >= 8);
        const head = tx.rows(12, 0, 3);
        check("head", head.length === 3 && head[0].marker === "⟩" && head[0].bg === "TxUser");
        check("window", tx.rows(12, 2, 4).length === 4);

        // setActive re-wraps only the draft: shrinking it drops the total, committed rows cached.
        textMap[3] = "short";
        tx.setActive(3);
        check("active-rewrap", tx.rowCount(12) < total);

        // A draft that starts mid-session (no active in the last outline) still appears via setActive.
        const tx2 = new Transcript({ textOf: (id) => (id === 9 ? "streaming draft" : "") });
        tx2.setOutline([{ id: 1, type: "user" }], null);
        const base = tx2.rowCount(12);
        tx2.setActive(9);
        check("draft-appears", tx2.rowCount(12) > base);

        // setOutline clears the wrap cache: a message sealed with content different from its streamed
        // draft shows the sealed text, not the stale draft (committed content can change under an id).
        const store = { 5: "partial" };
        const tx3 = new Transcript({ textOf: (id) => store[id] || "" });
        tx3.setOutline([], { id: 5, type: "assistant" });
        check("draft-partial", tx3.rows(40, 0, 10).some((r) => r.text.indexOf("partial") >= 0));
        store[5] = "sealed text";
        tx3.setOutline([{ id: 5, type: "assistant" }], null);
        const sealed = tx3.rows(40, 0, 10);
        check("seal-fresh", sealed.some((r) => r.text.indexOf("sealed") >= 0) && !sealed.some((r) => r.text.indexOf("partial") >= 0));

        // Pager clamps an unstuck scroll when the source shrinks (draft discarded / resize), instead
        // of leaving scroll past the end and painting a blank pane; landing on the tail re-sticks.
        const src = { n: 20, rowCount() { return this.n; }, rows() { return []; } };
        const pg = new Pager();
        pg.setSource(src);
        pg._w = 1;
        pg._h = 5;
        pg.toTop();
        pg.scrollBy(10);
        check("pager-scrolled", pg.scroll === 10 && pg.stuck === false);
        src.n = 6;
        pg._clamp();
        check("pager-clamp", pg.scroll === 1 && pg.stuck === true);

        // Pager static rows (the pickers' path): stuck to the tail, top/bottom/step, vim keys.
        const p = new Pager();
        const rows = Array.from({ length: 20 }, (_, i) => ({ text: "row" + i, key: i }));
        p._h = 5;
        p.setRows(rows);
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
        const chat = new ChatView({ textOf: () => "x ".repeat(40) });
        chat.setOutline([{ id: 1, type: "assistant" }, { id: 2, type: "assistant" }], null);
        chat.transcript.pager._h = 3;
        chat.transcript.pager._w = 20;
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
