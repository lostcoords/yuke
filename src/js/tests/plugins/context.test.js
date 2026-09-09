import { check } from "yuke:test";
import { keymap, root, context, parseContext, View, Node } from "yuke:core";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

// A view contributes its atoms, and the stack orders them from the root outward.
{
  class Pane extends View { get name() { return "pane"; } draw() {} }
  class Split extends View { contexts() { return ["chat", "composer"]; } draw() {} }
  const pane = new Pane();
  root.setRoot(Node.leaf(pane));
  root.focusView(pane);
  check("ctx-stack-name", JSON.stringify(context.stack()) === JSON.stringify(["root", "pane"]));
  const split = new Split();
  root.setRoot(Node.leaf(split));
  root.focusView(split);
  check("ctx-stack-atoms", JSON.stringify(context.stack()) === JSON.stringify(["root", "chat", "composer"]));

  // A deeper atom wins, and an unscoped binding sits below every scoped one.
  const ran = [];
  const kev3 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const offs = [
    keymap.add({ F1: () => { ran.push("bare"); return true; } }),
    keymap.add({ F1: () => { ran.push("chat"); return true; } }, "chat"),
    keymap.add({ F1: () => { ran.push("composer"); return true; } }, "composer"),
  ];
  keymap.onKey(kev3({ code: "f1" }));
  check("ctx-depth-wins", ran.join(",") === "composer");
  const d = keymap.describe("f1");
  check("ctx-describe", d.winner.context === "composer" && d.shadowed.length === 2 &&
    d.shadowed[0].context === "chat" && d.shadowed[1].context === "");
  offs[2]();
  keymap.onKey(kev3({ code: "f1" }));
  check("ctx-uncover", ran.join(",") === "composer,chat");
  for (const f of offs) f();
  root.setRoot(null);
}

// A flag matches by value, and a function flag resolves at match time.
{
  let mode = "insert";
  const off = context.add({ vim: () => mode, fixed: "on" });
  const ran = [];
  const kev4 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const offKey = keymap.add({ F2: () => { ran.push(mode); return true; } }, "vim == normal && fixed == on");
  keymap.onKey(kev4({ code: "f2" }));
  check("ctx-flag-absent", ran.length === 0);
  mode = "normal";
  keymap.onKey(kev4({ code: "f2" }));
  check("ctx-flag-live", ran.join(",") === "normal");
  offKey();
  off();
  check("ctx-flag-disposed", context.flag("vim") === undefined && context.flag("fixed") === undefined);
}

// The expression grammar covers negation, alternation, inequality, and grouping.
{
  const off = context.add({ m: "a" });
  root.setRoot(null);
  const truthy = (src) => { const off = keymap.add({ f9: () => true }, src);
    const n = keymap.candidates("f9").length; off(); return n === 1; };
  check("ctx-parse-root", truthy("root") && !truthy("chat"));
  check("ctx-parse-not", truthy("!chat") && !truthy("!root"));
  check("ctx-parse-or", truthy("chat || root") && !truthy("chat || nope"));
  check("ctx-parse-eq", truthy("m == a") && truthy("m != b") && !truthy("m == b"));
  check("ctx-parse-group", truthy("(chat || root) && m == a") && !truthy("(chat || root) && m == b") &&
    truthy("root || chat && m == b"));
  check("ctx-parse-bad", throws(() => parseContext("chat &&")) && throws(() => parseContext("(chat")) &&
    throws(() => parseContext("chat ||")) && throws(() => parseContext("m !=")) &&
    throws(() => parseContext("!")) && throws(() => parseContext("chat)")));
  off();
}

// The parser rejects a source it cannot read whole, so a typo never matches something else.
{
  check("parse-drop-punct", throws(() => parseContext("chat?")));
  check("parse-drop-at", throws(() => parseContext("chat && @leaf")));
  check("parse-drop-unicode", throws(() => parseContext("a == café")));
}

// A view atom must be a usable name, and a throwing hook must not stop a key.
{
  class Junk extends View { contexts() { return ["root", "", "dup", "dup", null, "ok"]; } draw() {} }
  const junk = new Junk();
  root.setRoot(Node.leaf(junk));
  root.focusView(junk);
  check("atoms-sanitized", JSON.stringify(context.stack()) === JSON.stringify(["root", "dup", "ok"]));
  // A throwing hook falls back to the view name, so a broken plugin keeps the view reachable.
  class Boom extends View { get name() { return "boom"; } contexts() { throw new Error("no"); } draw() {} }
  const boom = new Boom();
  root.setRoot(Node.leaf(boom));
  root.focusView(boom);
  check("atoms-throw-safe", JSON.stringify(context.stack()) === JSON.stringify(["root", "boom"]));
  root.setRoot(null);
}

// An overlay deepens the stack, so a binding on the overlay outranks one on the pane below.
{
  class Pane2 extends View { get name() { return "pane2"; } draw() {} }
  const pane = new Pane2();
  root.setRoot(Node.leaf(pane));
  root.focusView(pane);
  const ran = [];
  const kev7 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const offs = [
    keymap.add({ f8: () => { ran.push("pane"); return true; } }, "pane2"),
    keymap.add({ f8: () => { ran.push("over"); return true; } }, "overlay"),
  ];
  keymap.onKey(kev7({ code: "f8" }));
  const layer = { rect: { x: 0, y: 0, w: 1, h: 1 }, layout() {}, draw() {} };
  root.pushOverlay(layer);
  keymap.onKey(kev7({ code: "f8" }));
  root.popOverlay(layer);
  check("ctx-overlay", ran.join(",") === "pane,over");
  for (const f of offs) f();
  root.setRoot(null);
}

// A flag-only context has depth 0, so registration order decides against an unscoped binding.
{
  const offFlag = context.add({ m: "a" });
  const kev6 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const first = [];
  const a1 = keymap.add({ f7: () => { first.push("flag"); return true; } }, "m == a");
  const a2 = keymap.add({ f7: () => { first.push("bare"); return true; } });
  keymap.onKey(kev6({ code: "f7" }));
  a1(); a2();
  const second = [];
  const b1 = keymap.add({ f7: () => { second.push("bare"); return true; } });
  const b2 = keymap.add({ f7: () => { second.push("flag"); return true; } }, "m == a");
  keymap.onKey(kev6({ code: "f7" }));
  b1(); b2();
  check("ctx-depth-tie", first.join(",") === "bare" && second.join(",") === "flag");
  offFlag();
}
