// yuke:agents — model setup and admission over the native slot contract.
import { client } from "yuke:client";
import { watchCancellation } from "yuke:interaction";

/** @typedef {import("yuke:ext").Context} Context */
/** @typedef {{ aborted: boolean }} Signal */
/** @typedef {{ sessionId: string, messageId: number, partId: number }} Site */
/** @type {Map<string, Promise<void>>} */
const setups = new Map();
/** @type {Map<string, Promise<void>>} */
const connections = new Map();

/** A child name is unique per parent; "root" is reserved. */
export const NAME = /^[a-z][a-z0-9_-]{0,63}$/;

/** @param {string} code @param {string} message */
export function failure(code, message) { return Object.assign(new Error(message), { name: "AgentError", code }); }
/** @param {unknown} error @returns {string | undefined} */
function codeOf(error) { return /** @type {{ code?: string }} */ (error)?.code; }
/** @param {Signal | undefined} signal */
export function check(signal) { if (signal?.aborted) throw failure("tool_cancelled", "The tool call was canceled."); }
// Share one in-flight promise per key, so concurrent callers see one setup and one login.
/** @template T @param {Map<string, Promise<T>>} map @param {string} key @param {() => Promise<T>} make @returns {Promise<T>} */
function shared(map, key, make) {
  let pending = map.get(key);
  if (!pending) {
    pending = make();
    map.set(key, pending);
    const held = pending;
    pending.finally(() => { if (map.get(key) === held) map.delete(key); }).catch(() => {});
  }
  return pending;
}
/** @param {Context} ctx */
function interactive(ctx) { if (ctx.interaction.interactive !== true) throw failure("setup_required", "Agent model setup requires an interactive frontend. No agent was created. Do not retry agent setup in this frontend. Continue without delegation, or ask the user to configure agent models."); }
/** @template T @param {Promise<T>} promise @param {Signal | undefined} signal @returns {Promise<T>} */
async function cancellable(promise, signal) {
  check(signal);
  let dispose = () => {};
  const canceled = new Promise((_, reject) => { dispose = watchCancellation(signal, () => reject(failure("tool_cancelled", "The tool call was canceled.")), (error) => reject(failure("runtime_failed", "Cannot observe tool cancellation: " + String(error)))); });
  try { return /** @type {T} */ (await Promise.race([promise, canceled])); }
  finally { dispose(); }
}
/** @template T @param {T | undefined} value @param {Signal | undefined} signal @returns {T} */
function answer(value, signal) {
  check(signal);
  if (value === undefined) throw failure("setup_canceled", "Subagent setup was canceled.");
  return value;
}
/** @param {Wire.ModelInfo} model @returns {string} */
function modelLabel(model) {
  const price = model.cost.input == null || model.cost.output == null ? "price unknown" : "$" + model.cost.input + "/$" + model.cost.output + " per 1M input/output tokens";
  return model.selector + " · ready · tools · " + (model.supports_vision ? "vision · " : "") + price;
}
/** @param {Context} ctx @param {string} title @param {string[]} labels @param {Signal | undefined} signal @returns {Promise<string>} */
async function select(ctx, title, labels, signal) {
  let page = 0;
  while (true) {
    const items = labels.slice(page * 60, (page + 1) * 60);
    if (page > 0) items.push("← Previous page");
    if ((page + 1) * 60 < labels.length) items.push("Next page →");
    const value = answer(await ctx.interaction.select(title, items, { signal }), signal);
    if (value === "Next page →") page += 1;
    else if (value === "← Previous page") page -= 1;
    else { if (!items.includes(value)) throw failure("bad_request", "The picker returned an unknown option."); return value; }
  }
}
/** @returns {Promise<Wire.CatalogListResultFull>} */
async function catalog() {
  const result = await client.catalogList(null);
  if (result.type !== "full") throw failure("runtime_failed", "The catalog did not return its models.");
  return result;
}

/** @param {Context} ctx @param {Wire.AuthProvider} provider @param {Signal | undefined} signal */
async function connect(ctx, provider, signal) {
  interactive(ctx);
  if (!provider.can_login) {
    const key = answer(await ctx.interaction.input("API key · " + provider.provider_id, "paste the API key", { signal, secret: true }), signal);
    if (!key) throw failure("setup_canceled", "No API key was supplied.");
    await client.authSetApiKey(provider.provider_id, key);
  } else {
    const login = client.authLoginTracked(provider.provider_id);
    let loginId = "";
    let finished = false;
    try {
      check(signal);
      const start = await login.start;
      loginId = start.login_id;
      check(signal);
      if (!ctx.interaction.deviceLogin) ctx.interaction.notify("Sign in at " + start.verification_url + " with code " + start.user_code + ". Cancel the tool to stop setup.");
      const outcome = answer(await cancellable(ctx.interaction.deviceLogin ? ctx.interaction.deviceLogin(start, login.outcome, { signal }) : login.outcome, signal), signal);
      finished = true;
      if (outcome.type !== "succeeded") throw failure(outcome.type === "canceled" ? "setup_canceled" : "auth_required", outcome.type === "failed" ? outcome.message : "Login was canceled.");
    } finally {
      login.dispose();
      if (loginId && !finished) await client.authCancelLogin(loginId).catch(() => {});
    }
  }
  check(signal);
  await client.catalogReload();
}

/** @param {Context} ctx @param {Signal | undefined} signal @param {string} [providerId] */
async function setupProvider(ctx, signal, providerId) {
  const providers = (await client.authList()).providers;
  if (!providers.length) throw failure("setup_required", "Add a provider to providers.json before model setup.");
  const id = providerId || await select(ctx, "Connect a provider", providers.map((provider) => provider.provider_id), signal);
  const provider = providers.find((item) => item.provider_id === id);
  if (!provider) throw failure("auth_required", "The provider is unavailable for setup.");
  if ((await catalog()).providers.find((item) => item.id === id)?.state === "needs_route") throw failure("setup_required", "Repair the route for " + id + " in providers.json before model setup.");
  while (true) {
    try { await cancellable(shared(connections, id, () => connect(ctx, provider, signal)), signal); return; }
    catch (error) { check(signal); if (codeOf(error) !== "tool_cancelled") throw error; }
  }
}

/** @param {Context} ctx @param {string} slot @param {Signal | undefined} signal @returns {Promise<Wire.AgentModel>} */
async function pickModel(ctx, slot, signal) {
  while (true) {
    check(signal);
    const current = await catalog();
    const ready = new Set(current.providers.filter((provider) => provider.state === "ready").map((provider) => provider.id));
    const models = current.models.filter((model) => ready.has(model.provider) && model.supports_tools === true);
    if (!models.length) {
      if (!answer(await ctx.interaction.confirm("Connect a provider", "No ready model with known tool support is available. Connect a provider?", { signal }), signal)) throw failure("setup_declined", "The user declined provider setup for agents.");
      await setupProvider(ctx, signal);
      continue;
    }
    const providers = [...new Set(models.map((model) => model.provider))];
    const provider = providers.length === 1 ? providers[0] : await select(ctx, "Provider · " + slot, providers, signal);
    const choices = models.filter((model) => model.provider === provider);
    const label = await select(ctx, "Model · " + slot, choices.map(modelLabel), signal);
    const model = choices.find((item) => modelLabel(item) === label);
    if (!model) throw failure("bad_request", "The picker returned an unknown model.");
    if (!model.reasoning_levels.length) return { model: model.selector };
    const normal = "Model default" + (model.default_reasoning ? " · " + model.default_reasoning : "");
    const level = await select(ctx, "Reasoning · " + slot, [normal, ...model.reasoning_levels], signal);
    return level === normal ? { model: model.selector } : { model: model.selector, reasoning: level };
  }
}

/** @param {Context} ctx @param {Wire.AgentModelSlot} slot @param {Wire.AgentsGetResult} current @param {Signal | undefined} signal @param {boolean} [editing] */
async function setup(ctx, slot, current, signal, editing = false) {
  interactive(ctx);
  if (!current.path) throw failure("setup_required", "No profile config directory is available.");
  if (!editing) {
    const replace = current.config.models?.[slot] != null;
    const introduction = "Agents handle separate tasks and return their results here.\n\nSmall: narrow research and simple edits.\nMedium: broader work and review.\n\nChoose models from your providers. One model can serve both slots. No download is required. Provider charges may apply. Change these choices with /agent-models.\n\n";
    const message = introduction + (replace ? "The " + slot + " slot needs a different model. Choose it now?" : "Subagent model slot " + slot + " is not configured. Set it up?");
    if (!answer(await ctx.interaction.confirm("Agent models", message, { signal, labels: { accept: "Configure models", cancel: "Later" } }), signal)) throw failure("setup_declined", "The user declined agent model setup.");
  }
  /** @type {Partial<Record<Wire.AgentModelSlot, Wire.AgentModel>>} */
  const choices = { [slot]: await pickModel(ctx, slot, signal) };
  const other = slot === "small" ? "medium" : "small";
  if (!editing && !current.config.models?.[other]) {
    const same = answer(await ctx.interaction.confirm("Both model slots", "Use this model for both small and medium?", { signal }), signal);
    choices[other] = same ? /** @type {Wire.AgentModel} */ (choices[slot]) : await pickModel(ctx, other, signal);
  }
  for (let attempt = 0; attempt < 4; attempt++) {
    check(signal);
    const latest = await client.agentsGet();
    const models = { ...latest.config.models };
    for (const key of /** @type {Wire.AgentModelSlot[]} */ (Object.keys(choices))) {
      if (latest.revision !== current.revision && JSON.stringify(latest.config.models?.[key]) !== JSON.stringify(current.config.models?.[key])) continue;
      const choice = choices[key];
      if (choice) models[key] = choice;
    }
    check(signal);
    try { await client.agentsUpdate({ revision: latest.revision, config: { models } }); return; }
    catch (error) { if (codeOf(error) !== "config_conflict") throw error; }
  }
  throw failure("config_conflict", "agents.json changed repeatedly. Setup saved no stale update.");
}

/** @template T @param {Context} ctx @param {Wire.AgentModelSlot} slot @param {Signal | undefined} signal @param {() => Promise<T>} attempt @returns {Promise<T>} */
async function withSlot(ctx, slot, signal, attempt) {
  while (true) {
    check(signal);
    try { return await attempt(); }
    catch (error) {
      const code = codeOf(error);
      if (!["setup_required", "auth_required", "unsupported_model", "unsupported_reasoning"].includes(code || "")) throw error;
      interactive(ctx);
      const current = await client.agentsGet();
      if (code === "auth_required") {
        const selected = (await catalog()).models.find((model) => model.selector === current.config.models?.[slot]?.model);
        if (!selected) throw error;
        await setupProvider(ctx, signal, selected.provider);
      } else {
        try { await cancellable(shared(setups, current.path || "", () => setup(ctx, slot, current, signal)), signal); }
        catch (error) { check(signal); if (codeOf(error) !== "tool_cancelled") throw error; }
      }
    }
  }
}

/** @param {Context} ctx @param {{ name: string, message: string, model: Wire.AgentModelSlot }} args @param {Signal} signal @param {Site} site */
export async function spawnAgent(ctx, args, signal, site) {
  if (!args || (args.model !== "small" && args.model !== "medium")) throw failure("bad_request", "model must be small or medium; it has no default.");
  if (typeof args.name !== "string" || !NAME.test(args.name) || args.name === "root") throw failure("bad_request", "The child name is invalid.");
  if (typeof args.message !== "string" || !args.message.trim()) throw failure("bad_request", "The child needs a task message.");
  check(signal);
  const parent = await client.sessionGet(site.sessionId);
  const result = await withSlot(ctx, args.model, signal, () => client.sessionCreate({
    workspace_path: parent.session.root,
    initial_input: { type: "content", content: [{ type: "text", text: args.message }] },
    child: { slot: args.model, site: { session_id: site.sessionId, message_id: site.messageId, part_id: site.partId }, name: args.name },
  }));
  return { session_id: result.session.id, name: args.name, slot: args.model, model: result.session.model, input: result.input };
}

/** @param {Context} ctx @param {string} childId @param {Wire.AgentModelSlot | undefined} slot @param {Signal | undefined} signal */
export async function recoverAgent(ctx, childId, slot, signal) {
  interactive(ctx);
  const action = await select(ctx, "Subagent needs attention", ["Retry with the saved model", "Repair provider credentials", "Change this child's model"], signal);
  const child = await client.sessionGet(childId);
  if (action === "Repair provider credentials") {
    const model = (await catalog()).models.find((item) => item.selector === child.session.model);
    await setupProvider(ctx, signal, model?.provider);
  } else if (action === "Change this child's model") {
    const model = await pickModel(ctx, slot || "child", signal);
    check(signal);
    await client.agentsSetModel(childId, model);
    if (answer(await ctx.interaction.confirm("Slot default", "Save this model for future children too?", { signal }), signal)) {
      const target = slot || answer(await ctx.interaction.select("Slot default", ["small", "medium"], { signal }), signal);
      if (target !== "small" && target !== "medium") throw failure("bad_request", "The slot is invalid.");
      const current = await client.agentsGet();
      check(signal);
      await client.agentsUpdate({ revision: current.revision, config: { models: { ...current.config.models, [target]: model } } });
    }
  }
  check(signal);
}

/** @param {Context} ctx @param {Wire.AgentModelSlot} slot */
export async function editSlot(ctx, slot) {
  if (slot !== "small" && slot !== "medium") throw failure("bad_request", "The slot is invalid.");
  const current = await client.agentsGet();
  try { await shared(setups, current.path || "", () => setup(ctx, slot, current, undefined, true)); }
  catch (error) { if (codeOf(error) !== "setup_canceled" && codeOf(error) !== "setup_declined") throw error; }
}
