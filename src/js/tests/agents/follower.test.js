import { plugins } from "yuke:ext";
import { rpcInteractionPlugin } from "yuke:interaction";
plugins.use(rpcInteractionPlugin);
plugins.use({ name: "agent-test", apply(ctx) {
  for (const name of ["one", "two"]) ctx.tools.define({ name, description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
    try { await spawnAgent(ctx, { name, message: "task", model: "small" }, signal, site); globalThis[name] = "spawned"; }
    catch (e) { globalThis[name] = e.code || e.message; }
    return { text: globalThis[name] };
  } });
} });
