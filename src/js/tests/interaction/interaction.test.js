import { plugins } from "yuke:ext";
import { rpcInteractionPlugin } from "yuke:interaction";
plugins.use(rpcInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "ask", apply(ctx) {
  globalThis.interactionPending = () => ctx.interaction.pending;
  const a = ctx.interaction.confirm("first", "one");
  const b = ctx.interaction.select("second", ["red", "blue"]);
  Promise.all([a, b]).then((answers) => { globalThis.result = JSON.stringify(answers); });
} });
