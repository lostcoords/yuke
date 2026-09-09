import { equal } from "yuke:test";
import { Text } from "yuke:ui";
import { term } from "yuke:term";
const t = new Text({ text: "αβ gamma delta", group: "UIBody" });
const rect = { x: 1, y: 1, w: 5, h: 2 };
const measured = t.measure(5);
t.layout({ ...rect, w: 6 });
t.layout(rect);
const visible = t._layoutCache;
t.measure(5);
const independent = visible === t._layoutCache;
globalThis.repeat = () => {
  t.setText("αβ gamma delta"); t.measure(5); t.layout(rect);
  term.beginFrame(); t.draw(true); t.draw(false); term.endFrame();
};
equal(independent && measured.h > 2 && visible.rows.length === 2 && visible.rows.every(row => term.measure(row) <= 5) ? "ok" : "text cache mismatch", "ok");
