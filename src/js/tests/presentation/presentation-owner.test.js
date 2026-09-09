import { check } from "yuke:test";
import { ChatView } from "yuke:chat-view";
import { root } from "yuke:core";
import { row, child, fixed, grow } from "yuke:layout";
import { Context, Scope } from "yuke:ext";
import { tui } from "yuke:tui";
const seen = [];
const a = new Scope("a"), b = new Scope("b");
const view = new ChatView();
const bounds = { x: 0, y: 0, w: 60, h: 20 };
let aMount = 0, aDispose = 0, bDispose = 0;
tui.bindTo(new Context(a, "a")).presentation((_chat, owner) => {
  aMount++; owner.effect(() => () => aDispose++);
  const side = { rect: bounds, layout(r) { this.rect = r; }, draw() {},
    onMouse(ev) { seen.push(ev.event); return true; }, onKey() { seen.push("key"); return true; } };
  return state => row([child(null, grow(), { layout: state.defaultLayout }), child(side, fixed(10))]);
});
root.setActive(view); view.layout(bounds);
const mouse = (event, col) => ({ type: "mouse", event, button: "left", col, row: 1, mods: 0, count: 1 });
view.onMouse(mouse("press", 55)); view.onMouse(mouse("drag", 0)); view.onKey({ type: "key", key: "enter" });
check("capture", seen.join(",") === "press,drag,key");
tui.bindTo(new Context(b, "b")).presentation((_chat, owner) => {
  owner.effect(() => () => bDispose++);
  return state => state.defaultLayout;
});
view.layout(bounds);
check("replace", aDispose === 1 && view.presentationCapture === null && view.presentationFocus === null);
view.onMouse(mouse("release", 0));
check("old-capture-stops", seen.join(",") === "press,drag,key");
b.dispose(); view.layout(bounds);
check("restore", bDispose === 1 && aMount === 2);
view.onMouse(mouse("press", 55));
view.layout({ ...bounds, w: 0 });
check("hidden-clears-capture", view.presentationCapture === null && view.presentationFocus === null);
root.setActive(null);
check("pane-close", aDispose === 2 && view.presentation === null && view.presentationViews.length === 0);
a.dispose();
check("dispose-once", aDispose === 2 && bDispose === 1);
