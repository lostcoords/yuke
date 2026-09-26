import { View, root, keymap, route, Node } from "yuke:internal/core";
globalThis.hits = "";
class Pane extends View {
  contexts() { return ["pane", "inner"]; }
  draw() {}
  onKey(ev) { globalThis.hits += "V"; return true; }
}
root.setRoot(Node.leaf(new Pane()));
keymap.add({ a: () => { globalThis.hits += "K"; } });
globalThis.route = route;
globalThis.d1 = null;
globalThis.d2 = null;
