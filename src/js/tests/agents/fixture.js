import { client } from "yuke:client";
import { spawnAgent, recoverAgent } from "yuke:agents";
globalThis.client = client;
globalThis.spawnAgent = spawnAgent;
globalThis.recoverAgent = recoverAgent;
globalThis.map = { path: "/config/agents.json", revision: "1", config: { models: {} } };
globalThis.stats = { prompts: 0, saves: 0, creates: 0, gets: 0, changes: 0 };
const clone = (value) => JSON.parse(JSON.stringify(value));
client.agentsGet = async () => clone(globalThis.map);
client.agentsUpdate = async (next) => {
  if (next.revision !== map.revision) throw Object.assign(new Error("stale"), { code: "config_conflict" });
  stats.saves++; map = { ...map, revision: String(Number(map.revision) + 1), config: clone(next.config) }; return clone(map);
};
client.agentsResolve = async (slot) => {
  const entry = map.config.models[slot];
  if (!entry) throw Object.assign(new Error("setup"), { code: "setup_required" });
  return { slot, model: entry.model, reasoning: entry.reasoning || "medium", revision: map.revision };
};
client.catalogList = async () => ({ type: "full", providers: [{ id: "p", state: "ready" }], models: [{ provider: "p", selector: "p/family/model", name: "model", supports_tools: true, reasoning_levels: ["low", "medium", "high"], default_reasoning: "medium", cost: { input: 1, output: 2 } }] });
client.sessionGet = async () => { stats.gets++; return { session: { id: "parent", root: "/work", model: "parent/large", origin: { type: "root" } } }; };
client.sessionCreate = async (params) => { const selected = await client.agentsResolve(params.child.slot); stats.creates++; globalThis.created = params; return { session: { id: "child", model: selected.model }, input: { type: "queued", input_id: 1, reason: "concurrency_limit", capacity: { active: 8, limit: 8 } } }; };
client.agentsSetModel = async () => { stats.changes++; return { config: { config_rev: 1 } }; };
globalThis.ctx = { interaction: { interactive: true,
  confirm: async () => { stats.prompts++; return true; },
  select: async (_title, options) => options[0],
  input: async () => "key", notify: () => {},
} };
globalThis.site = { sessionId: "parent", messageId: 2, partId: 0 };
globalThis.result = "pending";
