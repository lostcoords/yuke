import { View, root, keymap, route } from "yuke:core";
globalThis.hits = "";
class Pane extends View {
  contexts() { return ["pane", "inner"]; }
  draw() {}
  onKey(ev) { globalThis.hits += "V"; return true; }
}
root.setActive(new Pane());
keymap.add({ a: () => { globalThis.hits += "K"; } });
globalThis.route = route;
globalThis.d1 = null;
globalThis.d2 = null;
