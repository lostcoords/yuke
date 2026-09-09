import { check } from "yuke:test";
import { keymap, root, config, defineConfig, View, Node } from "yuke:core";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

// keymap.add removes the bind and clears a prefix nothing uses.
{
  const off = keymap.add({ "ctrl+x g": () => true });
  const hadPrefix = keymap.prefixes["ctrl+x"].length === 1;
  off();
  check("keymap-dispose", hadPrefix && !keymap.map["ctrl+x g"] && !keymap.prefixes["ctrl+x"]);
}

// A later binding wins, and a binding that declines falls through to the one below.
{
  const ran = [];
  const kev = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const offA = keymap.add({ "ctrl+alt+t": () => { ran.push("a"); return true; } });
  const offB = keymap.add({ "ctrl+alt+t": () => { ran.push("b"); return false; } });
  keymap.onKey(kev({ char: "t", mods: 6 }));
  offB();
  offB();
  keymap.onKey(kev({ char: "t", mods: 6 }));
  check("keymap-newest-first", ran.join(",") === "b,a,a");
  offA();
  check("keymap-clean", !keymap.map["ctrl+alt+t"]);
}

// A modified binding folds shift away, so the stroke an event makes is the stroke that matches.
{
  let ran = 0;
  const kev2 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const off = keymap.add({ "ctrl+shift+g": () => { ran++; return true; } });
  keymap.onKey(kev2({ char: "g", shifted: "G", mods: 5 }));
  check("stroke-ctrl-shift", ran === 1);
  off();
}

// A chord waits, then runs the prefix alone. An operator waits without a bound.
{
  const ran = [];
  const kev5 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const offs = [
    keymap.add({ "f5 x": () => { ran.push("chord"); return true; } }),
    keymap.add({ f5: () => { ran.push("prefix"); return true; } }),
  ];
  keymap.onKey(kev5({ code: "f5" }));
  check("pend-armed", keymap.pending.kind === "chord" && keymap.pendingLabel() === "f5");
  check("pend-ticks", keymap.needsTick().periodMs === 1000);
  // The rest of the chord arrives before the wait ends.
  keymap.onKey(kev5({ char: "x" }));
  check("pend-chord-first", ran.join(",") === "chord" && keymap.pending === null);

  // Nothing follows, so the wait ends and the prefix runs on its own.
  keymap.onKey(kev5({ code: "f5" }));
  keymap.pending.at -= 2000;
  keymap.tick();
  check("pend-timeout", ran.join(",") === "chord,prefix" && keymap.pending === null);
  for (const f of offs) f();
}

// An operator never times out, and the status bar reports it.
{
  const ran = [];
  const kevOp = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const off = keymap.add({ "f8 x": () => { ran.push("op"); return true; } }, undefined, { pending: "operator" });
  keymap.onKey(kevOp({ code: "f8" }));
  check("pend-operator", keymap.pending.kind === "operator" && keymap.pendingLabel() === "f8");
  check("pend-operator-no-tick", keymap.needsTick() === null);
  keymap.pending.at -= 60000;
  keymap.tick();
  check("pend-operator-holds", keymap.pending !== null && keymap.pendingLabel() === "f8");
  keymap.onKey(kevOp({ char: "x" }));
  check("pend-operator-runs", ran.join(",") === "op" && keymap.pending === null);
  off();
}

// The chord wait is configurable and validated.
{
  defineConfig({ keymap: { chordMs: 250 } });
  check("cfg-chord", config.keymap.chordMs === 250);
  check("cfg-chord-bad", throws(() => defineConfig({ keymap: { chordMs: 0 } })) && config.keymap.chordMs === 250);
  defineConfig({ keymap: { chordMs: 1000 } });
}

// A chord whose context does not match must not swallow the prefix or the key after it.
{
  const seen = [];
  // The view declines, so the key reaches the keymap and the arming path runs.
  class Bare extends View { get name() { return "bare"; } draw() {} onKey(ev) { seen.push(ev.code || ev.char); return false; } }
  const pane = new Bare();
  root.setRoot(Node.leaf(pane));
  root.focusView(pane);
  const off = keymap.add({ "f6 x": () => true }, "chat");
  check("prefix-context-off", keymap._armKind("f6") === null);
  root.onEvent({ type: "key", code: "f6", char: "", event: "press", text: "", mods: 0 });
  check("prefix-falls-through", seen.join(",") === "f6" && keymap.pending === null);
  off();
  const on = keymap.add({ "f6 x": () => true }, "bare");
  check("prefix-context-on", keymap._armKind("f6") === "chord");
  on();
  root.setRoot(null);
}

// The keymap runs as a tick service, so a real tick event ends the chord wait.
{
  const ran = [];
  const kev8 = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
  const offs = [
    keymap.add({ "f10 x": () => { ran.push("chord"); return true; } }),
    keymap.add({ f10: () => { ran.push("prefix"); return true; } }),
  ];
  keymap.onKey(kev8({ code: "f10" }));
  keymap.pending.at -= 2000;
  root.onEvent({ type: "tick" });
  check("keymap-tick-service", ran.join(",") === "prefix" && keymap.pending === null);
  for (const f of offs) f();
}
