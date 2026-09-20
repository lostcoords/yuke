import { check, equal } from "yuke:test";
import { plugins } from "yuke";
import { events } from "yuke:kernel";

let released = 0;
let faults = 0;
const off = events.on("ext.error", (_error, name) => { if (name === "stuck-start") faults++; });
const handle = plugins.use({ name: "stuck-start", async apply(ctx) {
  ctx.own(() => { released++; });
  await new Promise(() => {});
} });
globalThis.startDone = false;
const ready = handle.ready.catch(error => error.name);
handle.dispose().then(async () => {
  equal(await ready, "AbortError");
  equal(released, 1);
  equal(faults, 1);
  check("stuck startup releases its name", !plugins.get("stuck-start"));
  off();
  globalThis.startDone = true;
}).catch(error => { globalThis.startFailure = String(error.stack); globalThis.startDone = true; });
