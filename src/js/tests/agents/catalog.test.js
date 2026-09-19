import { agents } from "yuke:agents";
const bad = [
  undefined, [], {}, { agents: [] }, { agents: {} },
  { agents: { Root: {} } }, { agents: { root: {} } }, { agents: { "a b": {} } },
  { agents: { a: {}, b: {} } }, { agents: { a: {} }, default: "b" },
  { agents: { a: { tools: [] } } }, { agents: { a: { tools: ["bash"] } } }, { agents: { a: { tools: ["read", "read"] } } },
  { agents: { a: { model: "" } } }, { agents: { a: { prompt: 3 } } }, { agents: { a: { extra: 1 } } }, { agents: { a: null } },
  { agents: { a: {} }, maxRounds: 0 }, { agents: { a: {} }, maxDepth: 1.5 }, { agents: { a: {} }, nope: 1 },
];
let rejected = 0;
for (const options of bad) {
  try { agents(options); } catch (error) { if (error instanceof TypeError && error.message.startsWith("agents: ")) rejected++; }
}
const single = agents({ agents: { only: { description: "d" } } });
const pair = agents({ default: "b", agents: { a: {}, b: { tools: ["read"] } }, maxRounds: 3 });
globalThis.result = rejected === bad.length && single.name === "agents" && pair.name === "agents" ? "ok" : "rejected " + rejected + " of " + bad.length;
