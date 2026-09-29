import { plugins } from "yuke:internal/ext";
import { notifications } from "yuke:internal/kernel";
globalThis.result = "pending";
plugins.use({ name: "ask", apply(ctx) {
  // A notification needs no answerer, so it enters the history. A question needs one, so it is refused.
  ctx.interaction.notify("hello");
  const posted = notifications[notifications.length - 1]?.message === "hello" ? "posted" : "lost";
  ctx.interaction.confirm("allow").catch((e) => { globalThis.result = posted + ":" + e.name; });
} });
