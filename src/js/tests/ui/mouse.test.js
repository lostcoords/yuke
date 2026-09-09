import { check } from "yuke:test";
import { term } from "yuke:term";
import { config, defineConfig, root, Node, View, isWheel } from "yuke:core";
import { List } from "yuke:ui";
import { Pager } from "yuke:pager";
const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };

check("mouse-default-lines", config.mouse.scrollLines === 3);
defineConfig({ mouse: { scrollLines: 5 } });
check("mouse-merge", config.mouse.scrollLines === 5);
check("mouse-unknown-key", throws(() => defineConfig({ mouse: { nope: 1 } })));
check("mouse-bad-lines", throws(() => defineConfig({ mouse: { scrollLines: 0 } })));
check("is-wheel", isWheel("wheel_up") && !isWheel("left"));

const mouse = (o) => Object.assign({ type: "mouse", col: 0, row: 0, button: "left", event: "press", mods: 0 }, o);
const p = new Pager();
p.setRows(Array.from({ length: 100 }, (_, i) => ({ text: "row " + i })));
term.beginFrame();
p.draw({ x: 0, y: 0, w: 10, h: 10 });
term.endFrame();
p.toTop();
check("wheel-down", p.onMouse(mouse({ button: "wheel_down" })) === true && p.scroll === 5);
check("wheel-up", p.onMouse(mouse({ button: "wheel_up" })) === true && p.scroll === 0);
check("click-not-scroll", p.onMouse(mouse({ button: "left" })) === false && p.scroll === 0);

// A click selects the row under the pointer. A two-line row covers two screen rows.
const L = new List({ key: (it) => it.id, itemHeight: 2, format: (it) => ({ text: it.id }) });
L.setItems([{ id: "a" }, { id: "b" }, { id: "c" }]);
term.beginFrame();
L.draw({ x: 2, y: 3, w: 8, h: 6 });
term.endFrame();
check("list-click", L.onMouse(mouse({ col: 3, row: 5, button: "left" })) === true && L.selectedKey === "b");
check("list-click-outside", L.onMouse(mouse({ col: 0, row: 5, button: "left" })) === false);
check("list-wheel", L.onMouse(mouse({ col: 3, row: 3, button: "wheel_down" })) === true && L.selectedKey === "c");
// A short pane paints one two-line row, so a click on the leftover row selects nothing.
const S = new List({ key: (it) => it.id, itemHeight: 2, format: (it) => ({ text: it.id }) });
S.setItems([{ id: "a" }, { id: "b" }]);
term.beginFrame();
S.draw({ x: 0, y: 0, w: 8, h: 3 });
term.endFrame();
check("list-partial-row", S.onMouse(mouse({ col: 1, row: 2, button: "left" })) === false && S.selectedKey === "a");

// A cleared rect drops a click, so a row that left the screen cannot be hit.
L.clearRect();
check("list-click-cleared", L.onMouse(mouse({ col: 3, row: 5, button: "left" })) === false);

// A press focuses the pane under the pointer; the wheel reaches it without moving focus.
class Pane extends View {
  constructor() { super(); this.seen = []; }
  draw() {}
  onMouse(ev) { this.seen.push(ev.button); return true; }
}
const left = new Pane();
const right = new Pane();
const a = Node.leaf(left);
const b = Node.leaf(right);
root.setRoot(Node.branch("row", a, b, 0.5));
root.root_node.layout({ x: 0, y: 0, w: 21, h: 5 });
root.focusLeaf(a);
root.routeMouse(mouse({ col: 15, row: 2, button: "left", event: "press" }));
check("press-focuses", root.active === right && right.seen.length === 1);
root.focusLeaf(a);
root.routeMouse(mouse({ col: 15, row: 2, button: "wheel_down", event: "press" }));
check("wheel-keeps-focus", root.active === left && right.seen.length === 2);
root.routeMouse(mouse({ col: 10, row: 2, button: "left", event: "press" }));
check("rule-hits-nothing", right.seen.length === 2 && left.seen.length === 0);

// A left press captures the pane. The drag and the release reach it even over another pane.
right.seen.length = 0;
left.seen.length = 0;
root.routeMouse(mouse({ col: 15, row: 2, button: "left", event: "press" }));
root.routeMouse(mouse({ col: 3, row: 2, button: "left", event: "drag" }));
root.routeMouse(mouse({ col: 3, row: 2, button: "left", event: "release" }));
check("capture-drag", right.seen.length === 3 && left.seen.length === 0);
// The release ends the capture, so the next press hits the pane under the pointer.
root.routeMouse(mouse({ col: 3, row: 2, button: "left", event: "press" }));
check("capture-released", left.seen.length === 1);
