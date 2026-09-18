import { plugins } from "yuke:ext";
import { rpcInteractionPlugin } from "yuke:interaction";
import { native } from "yuke:interaction-native";
native.notify = () => {};
plugins.use(rpcInteractionPlugin);
map.config.models.small = { model: "p/family/model" };
globalThis.canceledLogin = "";
globalThis.resolveSlot = async () => { throw Object.assign(new Error("expired"), { code: "auth_required" }); };
client.authList = async () => ({ providers: [{ provider_id: "p", can_login: true }] });
client.authLogin = async () => ({ login_id: "login", verification_url: "https://example.com/login", user_code: "code" });
client.authCancelLogin = async (id) => { canceledLogin = id; };
plugins.use({ name: "agent-test", apply(plugin) {
  ctx.interaction.deviceLogin = (...args) => plugin.interaction.deviceLogin(...args);
  globalThis.interactionPending = () => plugin.interaction.pending;
  plugin.tools.define({ name: "spawn-test", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
    try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, signal, site); result = "spawned"; }
    catch (e) { result = e.code || e.message; }
    return { text: result };
  } });
} });
