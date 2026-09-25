import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { tuiInteractionPlugin } from "yuke:internal/interaction-ui";
plugins.use(tuiPlugin);
plugins.use(tuiInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "ask", async apply(ctx) {
  globalThis.interactionPending = () => ctx.interaction.pending;
  const selected = await ctx.interaction.select("pick", ["alpha", "beta"]);
  const entered = await ctx.interaction.input("name", "value");
  globalThis.result = selected + ":" + entered;
} });
