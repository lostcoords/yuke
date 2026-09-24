import { check, equal } from "yuke:test";
import { Context, Scope, plugins, scopeOf } from "yuke:ext";
import { authPlugin } from "yuke:auth";
import { command, root } from "yuke:core";
import { events } from "yuke:kernel";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { defaultModel } from "yuke:catalog";
import { chat } from "yuke:defaults";
globalThis.authTest = (async () => {
const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
const finished = (login_id, outcome) => events.emit("auth.login_finished", { type: "index", facts: ["auth.login_finished"],
  auth: [{ method: "auth.login_finished", params: { login_id, provider_id: "codex", outcome } }] });
root.focusView(chat.view);
const calls = [];
const observer = new Context(new Scope("auth-observer"), "auth-observer");
client.catalogReload = () => Promise.resolve({ changed: false });
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", models: [],
  providers: [{ id: "codex", name: "Codex", state: "needs_credential", can_login: true },
    { id: "minimax", name: "MiniMax", state: "ready", credential_kind: "api_key", can_login: false }] });
client.authLogin = (id) => { calls.push("login:" + id); return Promise.resolve({ login_id: "L1", verification_url: "https://x/y", user_code: "AB-CD" }); };
client.authCancelLogin = (id) => { calls.push("cancel:" + id); return Promise.resolve({}); };
client.authSetApiKey = (id, k) => { calls.push("key:" + id + ":" + k); return Promise.resolve({}); };
client.authRemove = (id) => { calls.push("remove:" + id); return Promise.resolve({}); };

// /login lists both providers with the kind and the state of each.
command.perform("auth:login");
await settle();
check("login-lists", root.overlays.length === 1);
equal(observer.interaction.pending, 0);
const picker = root.overlays[0].content;
check("login-rows", picker.list.items.length === 2);
check("login-state", picker.list.selectKey("codex") && picker.list.selected().state === "needs_credential");
root.onEvent(key("enter"));
await settle();
check("device-dialog", root.overlays.length === 1 && calls.includes("login:codex"));
equal(observer.interaction.pending, 1);
// The outcome of another login leaves the dialog open; the outcome of this one closes it with its message.
finished("L9", { type: "succeeded" });
check("other-login-ignored", root.overlays.length === 1);
finished("L1", { type: "failed", message: "denied" });
await settle();
check("failure-closes", root.overlays.length === 0 && notice.text === "login failed · denied");
equal(observer.interaction.pending, 0);

// An unknown name is a notice, not a list.
command.perform("auth:login", "nope");
await settle();
check("unknown-name", root.overlays.length === 0 && notice.text === "no provider named nope");

// A direct `/login codex` skips the list, and Escape cancels through the engine.
command.perform("auth:login", "codex");
await settle();
check("direct-opens-dialog", root.overlays.length === 1);
root.onEvent(key("esc"));
await settle();
check("esc-cancels", root.overlays.length === 0 && calls.includes("cancel:L1"));

// A key provider gets the masked prompt, and Enter stores the key.
command.perform("auth:login", "minimax");
await settle();
check("key-prompt", root.overlays.length === 1);
equal(observer.interaction.pending, 1);
const prompt = root.overlays[0].content;
root.onEvent(key("char", { char: "s", text: "s" }));
root.onEvent({ type: "paste", text: "k" });
check("masked", prompt.input.text === "sk" && prompt.shown(prompt.input.text) === "••");
root.onEvent(key("enter"));
await settle();
check("key-stored", root.overlays.length === 0 && calls.includes("key:minimax:sk"));
equal(observer.interaction.pending, 0);

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
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r2", providers: [{ id: "codex", name: "Codex", state: "needs_credential", can_login: true }],
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
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r3", providers: [{ id: "codex", name: "Codex", state: "needs_route", can_login: true }],
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
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r4", providers: [{ id: "codex", name: "Codex", state: "ready", can_login: true }],
  models: [{ id: "gpt", provider: "codex", selector: "codex/gpt", name: "gpt", reasoning_levels: ["low", "high"], default_reasoning: "high", cost: {} }] });
command.perform("model:pick", "codex/gpt");
await settle();
check("query-ready-uses-default", root.overlays.length === 0 && defaultModel().model === "codex/gpt" && defaultModel().reasoning === "high");

// Disposal closes an active login and cancels its provider operation.
command.perform("auth:login", "codex");
await settle();
equal(observer.interaction.pending, 1);
const canceledBefore = calls.filter(call => call === "cancel:L1").length;
plugins.dispose("auth");
await settle();
equal(observer.interaction.pending, 0);
equal(root.overlays.length, 0);
equal(calls.filter(call => call === "cancel:L1").length, canceledBefore + 1);

// A late start response cannot open a dialog after its owner leaves.
plugins.use(authPlugin);
let finishStart;
client.authLogin = () => new Promise(resolve => { finishStart = resolve; });
command.perform("auth:login", "codex");
await settle();
plugins.dispose("auth");
finishStart({ login_id: "late", verification_url: "https://example.com", user_code: "code" });
await settle();
equal(observer.interaction.pending, 0);
equal(root.overlays.length, 0);
check("late login canceled", calls.includes("cancel:late"));
scopeOf(observer).dispose();
})();
