import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { tuiInteractionPlugin } from "yuke:interaction-ui";
plugins.use(tuiPlugin);
plugins.use(tuiInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "ask", async apply(ctx) {
  const selected = await ctx.interaction.select("pick", ["alpha", "beta"]);
  const entered = await ctx.interaction.input("name", "value");
  globalThis.result = selected + ":" + entered;
} });
