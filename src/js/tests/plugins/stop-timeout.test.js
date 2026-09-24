import { check, equal } from "yuke:test";
import { plugins } from "yuke";
import { events } from "yuke:kernel";

let reject;
let disposed = 0;
let faults = 0;
const unwatch = events.on("ext.error", (_error, owner) => { if (owner === "stalled") faults++; });
plugins.use({
  name: "stalled",
  apply(ctx) {
    ctx.effect(() => () => { disposed++; });
    ctx.own(() => new Promise((_resolve, fail) => { reject = fail; }));
  },
});
globalThis.stopDone = false;
plugins.dispose("stalled").then(async () => {
  equal(disposed, 1);
  equal(faults, 1);
  plugins.use({ name: "stalled", apply() {} });
  reject(new Error("late failure"));
  await Promise.resolve();
  check("late failure keeps replacement", plugins.has("stalled"));
  equal(faults, 1);
  plugins.dispose("stalled");
  unwatch();
  globalThis.stopDone = true;
});
