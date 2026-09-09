import { View, root, text } from "yuke:core";
globalThis.seen = 0;
class Base extends View {
  get name() { return "base"; }
  draw() { text(0, 0, "b", "Normal"); }
  onKey(ev) { globalThis.seen++; return true; }
}
root.setActive(new Base());
root.pushOverlay({ layout() {}, draw() { text(0, 1, "o", "Normal"); } });
globalThis.root = root;
