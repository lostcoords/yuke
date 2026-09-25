import { plugins } from "yuke:internal/ext";
import { rpcInteractionPlugin } from "yuke:internal/interaction";
plugins.use(rpcInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "ask", apply(ctx) {
  globalThis.interactionPending = () => ctx.interaction.pending;
  const a = ctx.interaction.confirm("first", "one");
  const b = ctx.interaction.select("second", ["red", "blue"]);
  Promise.all([a, b]).then((answers) => { globalThis.result = JSON.stringify(answers); });
} });
