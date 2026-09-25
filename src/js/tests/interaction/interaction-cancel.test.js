import { plugins } from "yuke:internal/ext";
import { rpcInteractionPlugin } from "yuke:internal/interaction";
plugins.use(rpcInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "ask", apply(ctx) {
  globalThis.interactionPending = () => ctx.interaction.pending;
  ctx.interaction.input("value").then((answer) => {
    globalThis.result = answer === undefined ? "canceled" : answer;
  });
} });
