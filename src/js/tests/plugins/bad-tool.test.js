import { plugins } from "yuke";
import { events } from "yuke:internal/kernel";
// A refused definition fails the apply, so the registry reports it under the plugin and closes the plugin.
let refused = 0;
const off = events.on("notify.posted", (n) => { if (n.source.startsWith("bad-")) refused += 1; });
for (const [i, bad] of [null, undefined, "name", 7].entries()) {
  plugins.use({ name: "bad-" + i, apply(ctx) { ctx.tools.define(/** @type {any} */ (bad)); } });
  if (plugins.has("bad-" + i)) refused = -100;
}
off();
globalThis.refused = refused;
