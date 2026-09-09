import { check } from "yuke:test";
import { root, keymap } from "yuke:core";
import { ui } from "yuke:ui";
const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: char || "", event: "press", mods: 0 });
const { content, close } = ui.select(["a", "b", "c", "d", "e"], { format: (x) => ({ text: String(x) }) });
const press = (code, char) => root.onEvent(key(code, char));
const sel = () => content.list.selected();

press("char", "j");
check("picker-j", sel() === "b");
press("down");
check("picker-down", sel() === "c");
press("char", "k");
check("picker-k", sel() === "b");
press("up");
check("picker-up", sel() === "a");
press("char", "G");
check("picker-G", sel() === "e");
press("home");
check("picker-home", sel() === "a");
press("end");
check("picker-end", sel() === "e");

// The paging keys came back with the shared table, so a modal pages like the app.
press("ctrl+u");
check("picker-ctrl-u", sel() !== "e");
press("ctrl+d");
check("picker-ctrl-d", sel() === "e");
press("page_up");
check("picker-page-up", sel() !== "e");
press("page_down");
check("picker-page-down", sel() === "e");

// A menu keeps its source and its selection, so a plugin that calls the finder path cannot reorder it.
press("char", "G");
content.refilter();
check("menu-refilter-keeps-selection", sel() === "e");
content.setSource(["x", "y"]);
check("menu-set-source", content.selected() === "x");
check("menu-no-query", content.query === "");

// A plugin may destructure the kit, so `select` must not depend on its receiver.
const { select } = ui;
const loose = select(["p", "q"], { format: x => ({ text: String(x) }) });
check("detached-select", loose.content.selected() === "p");
loose.close();

// A menu edits no query, so the setter changes neither the text nor the rows.
content.query = "zz";
check("menu-query-setter", content.query === "" && content.selected() === "x");

// A cancel always closes, in both modes, and `onCancel` only reports it.
let told = 0;
const deep = root.overlays.length;
ui.select(["m"], { format: x => ({ text: String(x) }), onCancel: () => { told++; } });
press("esc");
check("menu-cancel-closes", root.overlays.length === deep && told === 1);
ui.pick({ items: ["f"], format: x => ({ text: String(x) }), onCancel: () => { told++; } });
press("esc");
check("finder-cancel-closes", root.overlays.length === deep && told === 2);

// A modal layer seals the keymap, so an app binding cannot fire underneath it.
let leaked = 0;
const off = keymap.add({ f9: () => { leaked++; } });
press("f9");
check("modal-seals-keymap", leaked === 0);
const float = root.pushOverlay({ modal: false, layout() {}, draw() {}, onKey() { return false; } });
press("home");
press("j");
check("float-reaches-modal", sel() === "y");
press("f9");
check("float-keeps-modal-boundary", leaked === 0);
const routeMouse = root.routeMouse;
root.routeMouse = () => { leaked++; };
root.onEvent({ type: "mouse", col: -1, row: -1, button: "left", event: "press", mods: 0, count: 1 });
check("float-keeps-mouse-boundary", leaked === 0);
root.routeMouse = routeMouse;
root.popOverlay(float);
const lower = root.pushOverlay({ modal: false, layout() {}, draw() {} });
let calls = 0;
const moving = root.pushOverlay({ modal: false, layout() {}, draw() {}, onKey() { calls++; root.popOverlay(lower); return false; } });
press("f9");
check("removed-lower-layer-runs-once", calls === 1 && leaked === 0);
root.popOverlay(moving);
const a = root.pushOverlay({ modal: false, layout() {}, draw() {} });
const b = root.pushOverlay({ modal: false, layout() {}, draw() {} });
const self = root.pushOverlay({ modal: false, layout() {}, draw() {}, onKey() { root.popOverlay(a); root.popOverlay(b); root.popOverlay(self); return false; } });
press("f9");
check("removed-stack-keeps-modal-boundary", leaked === 0);
off();

close();
