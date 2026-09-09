import { tools } from "yuke";
let refused = 0;
for (const bad of [null, undefined, "name", 7]) {
  try { tools.define(bad); } catch { refused += 1; }
}
globalThis.refused = refused;
