import { plugins } from "yuke:ext";
import { root } from "yuke:core";
import { tuiPlugin } from "yuke:tui";
import { tuiInteractionPlugin } from "yuke:interaction-ui";
plugins.use(tuiPlugin); plugins.use(tuiInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "question", apply(ctx) {
  ctx.tools.define({ name: "question", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
    await ctx.interaction.confirm("Proceed?", "Small is for narrow research and simple edits. Medium is for broader work and review. You can use one model for both slots. Change these choices later with /agent-models.", { signal, labels: { accept: "Configure models", cancel: "Later" } });
    const completion = new Promise((resolve) => globalThis.finishLogin = resolve);
    const outcome = await ctx.interaction.deviceLogin({ verification_url: "https://example.com", user_code: "abc" }, completion, { signal });
    result = outcome?.type || "canceled";
    return result;
  } });
} });
globalThis.root = root;
