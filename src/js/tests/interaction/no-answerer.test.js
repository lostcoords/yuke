import { plugins } from "yuke:ext";
globalThis.result = "pending";
plugins.use({ name: "ask", apply(ctx) {
  try { ctx.interaction.notify("hello"); } catch (e) { globalThis.sync = e.name; }
  ctx.interaction.confirm("allow").catch((e) => { globalThis.result = globalThis.sync + ":" + e.name; });
} });
