import { plugins } from "yuke:ext";
import { root } from "yuke:core";
import { tuiPlugin } from "yuke:tui";
import { tuiInteractionPlugin } from "yuke:interaction-ui";
plugins.use(tuiPlugin); plugins.use(tuiInteractionPlugin);
globalThis.result = "pending";
plugins.use({ name: "question", apply(ctx) {
  ctx.tools.define({ name: "question", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
    await ctx.interaction.confirm("Proceed?", "The provider needs a credential. Change it later with /auth.", { signal, labels: { accept: "Connect", cancel: "Later" } });
    const completion = new Promise((resolve) => globalThis.finishLogin = resolve);
    const outcome = await ctx.interaction.deviceLogin({ verification_url: "https://example.com", user_code: "abc" }, completion, { signal });
    result = outcome?.type || "canceled";
    return result;
  } });
} });
globalThis.root = root;
