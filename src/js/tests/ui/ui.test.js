import { View, root, text } from "yuke:internal/core";
class Hello extends View {
  get name() { return "hello"; }
  draw() { text(this.rect.x, this.rect.y, "hi", "Normal"); }
}
root.setActive(new Hello());
