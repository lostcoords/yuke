import { check, equal } from "yuke:internal/test";
import { plugins } from "yuke";
import { events } from "yuke:internal/kernel";

const faults = [];
const off = events.on("ext.error", (error, name) => { if (name === "release") faults.push(error.message); });
const order = [];
let nested;
let once;
const handle = plugins.use({ name: "release", apply(ctx) {
  once = ctx.own(() => { order.push("early"); });
  ctx.own(() => { order.push("last"); });
  ctx.own(() => { order.push("fault"); throw new Error("release failed"); });
  ctx.own(() => { nested = plugins.dispose("release"); order.push("first"); });
} });
once();
once();
const closed = handle.dispose();
equal(nested, closed);
equal(order.join(","), "early,first,fault,last");
equal(faults.join(","), "release failed");
globalThis.resourcesDone = false;
closed.then(() => {
  check("resource fault releases the name", !plugins.has("release"));
  off();
  globalThis.resourcesDone = true;
});
