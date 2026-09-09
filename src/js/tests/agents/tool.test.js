import { plugins } from "yuke:ext";
import { rpcInteractionPlugin } from "yuke:interaction";
plugins.use(rpcInteractionPlugin);
plugins.use({ name: "agent-test", apply(ctx) {
  ctx.tools.define({ name: "spawn-test", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
    try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, signal, site); result = "spawned"; }
    catch (e) { result = e.code || e.message; }
    return { text: result };
  } });
} });
