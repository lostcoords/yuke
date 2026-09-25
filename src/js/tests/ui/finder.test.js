import { check } from "yuke:internal/test";
import { root } from "yuke:internal/core";
import { ui } from "yuke:internal/ui";
const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: char || "", event: "press", mods: 0 });
const press = (code, char) => root.onEvent(key(code, char));
const items = [{ id: "ay" }, { id: "bee" }, { id: "sea" }];

// The chat model picker preselects the open model this way, so a finder must answer it.
let taken = null;
let at = -1;
const p = ui.pick({
  items,
  key: it => it.id,
  filterText: it => it.id,
  format: it => ({ text: it.id }),
  needsTick: { periodMs: 40 },
  keymap: { "ctrl+g": "bottom" },
  onAccept: (it, i) => { taken = it.id; at = i; },
});
root.pushOverlay(p.win);
check("selectKey", p.content.list.selectKey("sea") && p.content.list.selected().id === "sea");

// `needsTick` reaches the window, so a finder that wants a timer gets one.
const t = p.win.needsTick();
check("needsTick", t !== null && t.periodMs === 40);

// A string binding names a default action; only the shared class answers one.
p.content.list.selectKey("ay");
press("ctrl+g");
check("string-action", p.content.list.selected().id === "sea");

// The query still filters, so the finder half did not regress.
press("char", "b");
check("query", p.content.query === "b" && p.content.list.selected().id === "bee");

// The accept carries the row index, and a pick that `onAccept` opens stays on top. The chat model step chains this way.
const depth = root.overlays.length;
let chained = null;
p.content.onAccept = (it, i) => {
  taken = it.id;
  at = i;
  chained = ui.pick({ items: [{ id: "level" }], key: x => x.id, format: x => ({ text: x.id }) });
  root.pushOverlay(chained.win);
};
press("enter");
check("accepted", taken === "bee" && at === 0);
check("chained-on-top", root.overlays.length === depth && root.overlays[root.overlays.length - 1] === chained.win);
chained.content.close();
