import { root, Node, View } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
class A extends View { get name() { return "a"; } draw() {} }
class B extends View { get name() { return "b"; } draw() {} }
const a = new A();
const b = new B();
// A split without a ratio gives each side half.
root.setRoot(Node.branch("row", Node.leaf(a), Node.leaf(b)));
if (/** @type {any} */ (root.root_node).shape.ratio !== 0.5) throw new Error("a split without a ratio must give each side half");
root.focusView(a);
globalThis.log = "";
events.on("pane.focused", (v) => { globalThis.log += "P" + v.name; });
events.on("focus.changed", (ev) => { globalThis.log += "T" + (ev.focused ? "1" : "0"); });
globalThis.root = root;
globalThis.a = a;
globalThis.b = b;
