import { View, root } from "yuke:core";
class Ok extends View { draw() {} }
const reject = (fn, want) => {
  try { fn(); } catch (e) {
    if (e instanceof TypeError && e.message === want) globalThis.threw++;
  }
};
globalThis.threw = 0;
const view = "a view needs layout and draw methods";
const layer = "pushOverlay needs layout and draw methods";
for (const bad of [{}, { draw: 1 }]) reject(() => root.setActive(bad), view);
root.setActive(new Ok());
reject(() => root.split("row", {}), view);
for (const bad of [null, {}, { draw: true }]) reject(() => root.pushOverlay(bad), layer);
root.setActive(null);
globalThis.cleared = root.active === null ? 1 : 0;
