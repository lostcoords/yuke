import { check, equal } from "yuke:test";
import { plugins } from "yuke";
import { events } from "yuke:kernel";

let disposed = 0;
const faults = [];
const unwatch = events.on("ext.error", (error, owner) => faults.push(owner + ":" + error.message));
for (const async of [false, true]) {
  plugins.use({
    name: "fault-" + async,
    apply(ctx) {
      ctx.effect(() => () => { disposed++; });
      ctx.own(() => {
        if (async) return Promise.reject(new Error("async"));
        throw new Error("sync");
      });
    },
  });
}
globalThis.stopDone = false;
Promise.all([plugins.dispose("fault-false"), plugins.dispose("fault-true")]).then(() => {
  equal(disposed, 2);
  equal(faults.join(","), "fault-false:sync,fault-true:async");
  check("faults release both names", !plugins.get("fault-false") && !plugins.get("fault-true"));
  unwatch();
  globalThis.stopDone = true;
});
