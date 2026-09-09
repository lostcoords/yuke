import { command, root } from "yuke:core";
import { client } from "yuke:client";
const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
const start = (login_id) => ({ login_id, verification_url: "https://x/y", user_code: "AB-CD" });
client.catalogReload = () => Promise.resolve({ changed: false });
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", providers: [], models: [] });
client.authList = () => Promise.resolve({ providers: [{ provider_id: "codex", can_login: true }] });
client.authCancelLogin = () => Promise.resolve({});
client.authLogin = () => Promise.resolve(start("07".repeat(32)));
command.perform("auth:login", "codex");
await settle();
globalThis.resolveLogin = null;
globalThis.openCount = () => root.overlays.length;
globalThis.startPendingLogin = async () => {
  client.authLogin = () => new Promise((resolve) => { globalThis.resolveLogin = () => resolve(start("08".repeat(32))); });
  command.perform("auth:login", "codex");
  await settle();
};
globalThis.finishPendingLogin = async () => { globalThis.resolveLogin(); await settle(); };
