import { check } from "yuke:internal/test";
import { root, Node } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";

/** @param {string} name */
const pane = (name) => ({ name, rect: { x: 0, y: 0, w: 0, h: 0 }, focuses: 0, layout() {}, draw() {}, onFocus() { this.focuses++; } });
const x = pane("x"), y = pane("y"), z = pane("z");
root.setRoot(Node.leaf(x));
root.split("row", y);
root.split("col", z);
root.focusView(x);
let moves = 0;
events.on("pane.focused", () => { moves++; });
const held = x.focuses;

// A pane that did not hold the focus closes without moving it: x | (y / z) loses z, then x | y loses y.
root.close(z);
check("far-close-keeps-focus", root.active === x && moves === 0 && x.focuses === held);
root.close(y);
check("sibling-close-keeps-focus", root.active === x && moves === 0 && x.focuses === held);

// The focused pane that closes hands the focus to the pane that takes its place.
root.split("row", y);
root.close(y);
check("focused-close-moves-focus", root.active === x && moves === 2);
root.setRoot(null);
