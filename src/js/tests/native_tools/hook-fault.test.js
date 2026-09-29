import { events } from "yuke:internal/kernel";
import { plugins } from "yuke:internal/ext";
globalThis.faults = [];
events.on("notify.posted", (n) => globalThis.faults.push(n.source + ":" + n.message));
plugins.use({ name: "getter", apply(ctx) {
  ctx.hook("input.before", () => ({ get block() { throw new Error("getter"); } }));
} });
plugins.use({ name: "convert", apply(ctx) {
  ctx.hook("input.before", () => ({ block: { toString() { throw new Error("convert"); } } }));
} });
plugins.use({ name: "later", apply(ctx) {
  ctx.hook("input.before", () => ({ block: "accepted" }));
} });
