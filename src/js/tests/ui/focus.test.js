import { root, Node, View, events } from "yuke:core";
class A extends View { get name() { return "a"; } draw() {} }
class B extends View { get name() { return "b"; } draw() {} }
const a = new A();
const b = new B();
root.setRoot(Node.branch("row", Node.leaf(a), Node.leaf(b), 0.5));
root.focusView(a);
globalThis.log = "";
events.on("pane.focused", (v) => { globalThis.log += "P" + v.name; });
events.on("focus.changed", (ev) => { globalThis.log += "T" + (ev.focused ? "1" : "0"); });
globalThis.root = root;
globalThis.a = a;
globalThis.b = b;
