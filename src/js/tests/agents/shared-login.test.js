import { events } from "yuke:core";
(async () => {
  map.config.models = { small: { model: "p/family/model" }, medium: { model: "p/family/model" } };
  const resolve = globalThis.resolveSlot;
  let ready = false, logins = 0;
  globalThis.resolveSlot = async (slot) => { if (!ready) throw Object.assign(new Error("key expired"), { code: "auth_required" }); return resolve(slot); };
  client.authList = async () => ({ providers: [{ provider_id: "p", can_login: true }] });
  client.authLogin = async () => {
    logins++;
    events.emit("auth.login_finished", { type: "index", facts: ["auth.login_finished"], auth: [{ method: "auth.login_finished", params: { login_id: "login", provider_id: "p", outcome: { type: "succeeded" } } }] });
    ready = true;
    return { login_id: "login", verification_url: "https://example.com/login", user_code: "code" };
  };
  client.catalogReload = async () => {};
  client.authCancelLogin = async () => { throw new Error("canceled success"); };
  await Promise.all([spawnAgent(ctx, { name: "repair-small", message: "task", model: "small" }, undefined, site), spawnAgent(ctx, { name: "repair-medium", message: "task", model: "medium" }, undefined, site)]);
  if (logins !== 1 || stats.saves !== 0 || stats.creates !== 2) throw new Error("duplicate repair");
  result = "ok";
})().catch((e) => result = e.stack || e.message);
