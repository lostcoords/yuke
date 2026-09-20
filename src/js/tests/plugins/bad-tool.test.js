import { plugins } from "yuke";
let refused = 0;
for (const [i, bad] of [null, undefined, "name", 7].entries()) {
  try { plugins.use({ name: "bad-" + i, apply(ctx) { ctx.tools.define(/** @type {any} */ (bad)); } }); } catch { refused += 1; }
}
globalThis.refused = refused;
