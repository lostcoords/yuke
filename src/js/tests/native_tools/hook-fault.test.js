import { events } from "yuke:kernel";
import { plugins } from "yuke:ext";
globalThis.faults = [];
events.on("ext.error", (e, owner) => globalThis.faults.push(String(owner) + ":" + e.message));
plugins.use({ name: "getter", apply(ctx) {
  ctx.hook("input.before", () => ({ get block() { throw new Error("getter"); } }));
} });
plugins.use({ name: "convert", apply(ctx) {
  ctx.hook("input.before", () => ({ block: { toString() { throw new Error("convert"); } } }));
} });
plugins.use({ name: "later", apply(ctx) {
  ctx.hook("input.before", () => ({ block: "accepted" }));
} });
