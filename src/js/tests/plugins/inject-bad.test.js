import { check } from "yuke:test";
import { plugins, services } from "yuke:ext";

let refused = 0;
plugins.use({
  name: "bad-args",
  apply(ctx) {
    for (const bad of [[], null, "tui", [""], [1]]) {
      try { ctx.inject(bad, () => {}); } catch { refused += 1; }
    }
    try { ctx.inject(["ok"], null); } catch { refused += 1; }
  },
});
check("refused-all", refused === 6);
check("plugin-survived", !!plugins.get("bad-args"));

// A block that throws reports the fault and stays inactive; the plugin keeps its other work.
let sibling = 0;
plugins.use({
  name: "boom",
  apply(ctx) {
    ctx.inject(["x"], () => { throw new Error("nope"); });
    sibling = 1;
  },
});
const offX = services.provide("x", 1);
check("sibling-ran", sibling === 1);
check("boom-alive", !!plugins.get("boom"));
offX();
check("clean-withdraw", !services.has("x"));
