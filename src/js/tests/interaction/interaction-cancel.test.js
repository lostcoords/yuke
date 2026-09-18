import { plugins } from "yuke:ext";
import { rpcInteractionPlugin } from "yuke:interaction";
plugins.use(rpcInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "ask", apply(ctx) {
  globalThis.interactionPending = () => ctx.interaction.pending;
  ctx.interaction.input("value").then((answer) => {
    globalThis.result = answer === undefined ? "canceled" : answer;
  });
} });
