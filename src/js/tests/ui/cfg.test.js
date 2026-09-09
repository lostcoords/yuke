import { check } from "yuke:test";
import { config, defineConfig, keymap } from "yuke:core";
import { TextInput } from "yuke:text-input";
import { strokeOf } from "yuke:keys";
const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };

// defineConfig merges values and rejects invalid fields.
defineConfig({ mouse: { scrollLines: 7, copyOnSelect: false } });
check("cfg-merge", config.mouse.scrollLines === 7 && config.mouse.copyOnSelect === false);
check("cfg-unknown-key", throws(() => defineConfig({ nope: 1 })));
check("cfg-prototype-key", throws(() => defineConfig({ mouse: { toString: undefined } })));
check("cfg-out-of-range", throws(() => defineConfig({ mouse: { scrollLines: 0 } })));
// A bad patch changes no config value.
const before = config.mouse.scrollLines;
throws(() => defineConfig({ mouse: { scrollLines: 4, copyOnSelect: "no" } }));
check("cfg-atomic", config.mouse.scrollLines === before);
throws(() => defineConfig({ mouse: { scrollLines: 9 }, keymap: { chordMs: 0 } }));
check("cfg-whole-atomic", config.mouse.scrollLines === before);

// strokeOf separates G from g under both keyboard protocols.
const kev = (o) => Object.assign({ type: "key", code: "char", char: "", shifted: "", text: "", mods: 0 }, o);
const mk = (o) => strokeOf(kev(o));
check("stroke-legacy-shift", mk({ char: "G", mods: 1 }) === "G");
check("stroke-kitty-shift", mk({ char: "g", shifted: "G", mods: 1 }) === "G");
check("stroke-plain", mk({ char: "g" }) === "g");
check("stroke-kitty-colon", mk({ char: ";", shifted: ":", mods: 1 }) === ":");
// A legacy terminal reports the shifted symbol as the char and sends no shifted form.
check("stroke-legacy-colon", mk({ char: ":", mods: 1 }) === ":");
check("stroke-chord", mk({ char: "d", mods: 4 }) === "ctrl+d");
check("stroke-named", mk({ code: "tab" }) === "tab");


// A written binding folds the way an event folds, so the keymap can bind an uppercase key.
{
  const ran = [];
  const off = keymap.add({ G: () => { ran.push("G"); return true; }, g: () => { ran.push("g"); return true; } });
  keymap.onKey(kev({ char: "G", mods: 1 }));
  keymap.onKey(kev({ char: "g" }));
  check("keymap-case", ran.join(",") === "G,g");
  off();
}

// `shift+g` names the same stroke as `G`, and another modifier folds the case away.
{
  const ran = [];
  const off = keymap.add({ "shift+g": () => { ran.push("shift"); return true; }, "ctrl+G": () => { ran.push("ctrl"); return true; } });
  keymap.onKey(kev({ char: "g", shifted: "G", mods: 1 }));
  keymap.onKey(kev({ char: "g", mods: 4 }));
  check("keymap-shift-alias", ran.join(",") === "shift,ctrl");
  off();
}
// TextInput uses committed text before the folded key.
const key = (o) => Object.assign({ type: "key", code: "char", event: "press", char: "", text: "", mods: 0 }, o);
const insert = (evs) => { const ti = new TextInput(); for (const e of evs) ti.onKey(e); return ti.text; };
check("upper", insert([key({ char: "a", text: "A", mods: 1 }), key({ char: "b", text: "B", mods: 1 })]) === "AB");
check("shifted-symbol", insert([key({ char: "1", text: "!", mods: 1 })]) === "!");
check("ime-cjk", insert([key({ char: "あ", text: "あ", mods: 0 })]) === "あ");
check("ime-zwj", insert([key({ char: "👨", text: "👨‍👩‍👧", mods: 0 })]) === "👨‍👩‍👧");
check("fallback-char", insert([key({ char: "x", text: "", mods: 1 })]) === "x");
check("altgr-text", insert([key({ char: "q", text: "@", mods: 6 })]) === "@");
// A command has no committed text.
check("ctrl-no-insert", insert([key({ char: "z", text: "", mods: 4 })]) === "");
