import { plugins } from "yuke:ext";
const save = client.agentsUpdate;
client.agentsUpdate = (next) => new Promise((resolve) => { globalThis.finishSave = async () => resolve(await save(next)); });
plugins.use({ name: "agent-test", apply(plugin) {
  plugin.tools.define({ name: "spawn-test", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
    try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, signal, site); result = "spawned"; }
    catch (e) { result = e.code || e.message; }
    return { text: result };
  } });
} });
