import { check, equal } from "yuke:internal/test";
import { plugins } from "yuke";
import { events } from "yuke:internal/kernel";

let released = 0;
let faults = 0;
const off = events.on("notify.posted", (n) => { if (n.source === "stuck-start") faults++; });
const handle = plugins.use({ name: "stuck-start", async apply(ctx) {
  ctx.own(() => { released++; });
  await new Promise(() => {});
} });
globalThis.startDone = false;
handle.dispose().then(async () => {
  equal(released, 1);
  equal(faults, 1);
  check("stuck startup releases its name", !plugins.has("stuck-start"));
  off();
  globalThis.startDone = true;
}).catch(error => { globalThis.startFailure = String(error.stack); globalThis.startDone = true; });
