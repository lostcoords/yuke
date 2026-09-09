import { check } from "yuke:test";
import { command, root, events } from "yuke:core";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { defaultModel } from "yuke:catalog";
import { chat } from "yuke:defaults";
const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
const finished = (login_id, outcome) => events.emit("auth.login_finished", { type: "index", facts: ["auth.login_finished"],
  auth: [{ method: "auth.login_finished", params: { login_id, provider_id: "codex", outcome } }] });
root.focusView(chat.view);
const calls = [];
client.catalogReload = () => Promise.resolve({ changed: false });
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", models: [],
  providers: [{ id: "codex", name: "Codex", state: "needs_credential" }, { id: "minimax", name: "MiniMax", state: "ready" }] });
client.authList = () => Promise.resolve({ providers: [
  { provider_id: "codex", can_login: true }, { provider_id: "minimax", credential_kind: "api_key", can_login: false }] });
client.authLogin = (id) => { calls.push("login:" + id); return Promise.resolve({ login_id: "L1", verification_url: "https://x/y", user_code: "AB-CD" }); };
client.authCancelLogin = (id) => { calls.push("cancel:" + id); return Promise.resolve({}); };
client.authSetApiKey = (id, k) => { calls.push("key:" + id + ":" + k); return Promise.resolve({}); };
client.authRemove = (id) => { calls.push("remove:" + id); return Promise.resolve({}); };

// /login lists both providers with the kind and the state of each.
command.perform("auth:login");
await settle();
check("login-lists", root.overlays.length === 1);
const picker = root.overlays[0].content;
check("login-rows", picker.list.items.length === 2);
check("login-state", picker.selectKey("codex") && picker.selected().state === "needs_credential");
root.onEvent(key("enter"));
await settle();
check("device-dialog", root.overlays.length === 1 && calls.includes("login:codex"));
// The outcome of another login leaves the dialog open; the outcome of this one closes it with its message.
finished("L9", { type: "succeeded" });
check("other-login-ignored", root.overlays.length === 1);
finished("L1", { type: "failed", message: "denied" });
await settle();
check("failure-closes", root.overlays.length === 0 && notice.text === "login failed · denied");

// An unknown name is a notice, not a list.
command.perform("auth:login", "nope");
await settle();
check("unknown-name", root.overlays.length === 0 && notice.text === "no provider named nope");

// A direct `/login codex` skips the list, and Escape cancels through the engine.
command.perform("auth:login", "codex");
await settle();
check("direct-opens-dialog", root.overlays.length === 1);
root.onEvent(key("esc"));
check("esc-cancels", root.overlays.length === 0 && calls.includes("cancel:L1"));

// A key provider gets the masked prompt, and Enter stores the key.
command.perform("auth:login", "minimax");
await settle();
check("key-prompt", root.overlays.length === 1);
const prompt = root.overlays[0].content;
root.onEvent(key("char", { char: "s", text: "s" }));
root.onEvent({ type: "paste", text: "k" });
check("masked", prompt.input.text === "sk" && prompt.shown(prompt.input.text) === "••");
root.onEvent(key("enter"));
await settle();
check("key-stored", root.overlays.length === 0 && calls.includes("key:minimax:sk"));

// /logout lists only the provider that holds a credential.
command.perform("auth:logout");
await settle();
check("logout-lists-one", root.overlays.length === 1 && root.overlays[0].content.list.items.length === 1);
root.onEvent(key("enter"));
await settle();
check("logout-removes", root.overlays.length === 0 && calls.includes("remove:minimax"));
// A key from the environment is not in the file, so the engine refuses and the notice says where it lives.
client.authRemove = () => { const e = new Error("unknown provider"); e.code = "unknown_provider"; return Promise.reject(e); };
command.perform("auth:logout", "minimax");
await settle();
check("env-key-notice", notice.text.indexOf("in the environment") > 0);

// The model picker dims a model whose provider needs a credential, and accepting it starts the login.
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r2", providers: [{ id: "codex", name: "Codex", state: "needs_credential" }],
  models: [{ id: "gpt", provider: "codex", selector: "codex/gpt", name: "gpt", reasoning_levels: [], default_reasoning: "", cost: {} }] });
command.perform("model:pick");
await settle();
check("model-picker", root.overlays.length === 1);
const models = root.overlays[0].content;
check("model-dimmed", models.list.items.length === 1 && models.opts.format(models.list.items[0]).group === "UIDim");
root.onEvent(key("enter"));
await settle();
check("model-accept-logs-in", root.overlays.length === 1 && calls[calls.length - 1] === "login:codex");
root.onEvent(key("esc"));
check("dialog-closed", root.overlays.length === 0);
// A provider without a route cannot log in, so the picker stops with the reason.
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r3", providers: [{ id: "codex", name: "Codex", state: "needs_route" }],
  models: [{ id: "gpt", provider: "codex", selector: "codex/gpt", name: "gpt", reasoning_levels: ["low", "high"], default_reasoning: "low", cost: {} }] });
command.perform("model:pick");
await settle();
root.onEvent(key("enter"));
await settle();
check("route-stops", root.overlays.length === 0 && notice.text.indexOf("needs a route") > 0);
const beforeQuery = defaultModel().model;
command.perform("model:pick", "codex/gpt");
await settle();
check("query-route-stops", defaultModel().model === beforeQuery && notice.text.indexOf("needs a route") > 0);
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r4", providers: [{ id: "codex", name: "Codex", state: "ready" }],
  models: [{ id: "gpt", provider: "codex", selector: "codex/gpt", name: "gpt", reasoning_levels: ["low", "high"], default_reasoning: "high", cost: {} }] });
command.perform("model:pick", "codex/gpt");
await settle();
check("query-ready-uses-default", root.overlays.length === 0 && defaultModel().model === "codex/gpt" && defaultModel().reasoning === "high");
