import { agents } from "yuke:agents";
const bad = [
  [undefined, "options must be an object"], [[], "options must be an object"], [{}, "agents must be an object"], [{ agents: [] }, "agents must be an object"],
  [{ agents: {} }, "at least one agent"], [{ agents: { Root: {} } }, "bad key"], [{ agents: { root: {} } }, "bad key"], [{ agents: { "a b": {} } }, "bad key"],
  [{ agents: { a: {}, b: {} } }, "default must name"], [{ agents: { a: {} }, default: "b" }, "default must name"], [{ agents: { a: {} }, default: "toString" }, "default must name"],
  [{ agents: { a: { tools: [] } } }, "tools must be"], [{ agents: { a: { tools: ["bash"] } } }, "tools must be"], [{ agents: { a: { tools: ["read", "read"] } } }, "tools must be"],
  [{ agents: { a: { model: "" } } }, "nonempty string model"], [{ agents: { a: { prompt: 3 } } }, "nonempty string prompt"], [{ agents: { a: { extra: 1 } } }, "unknown field extra"], [{ agents: { a: null } }, "must be an object"],
  [{ agents: { a: {} }, maxRounds: 0 }, "maxRounds must be"], [{ agents: { a: {} }, maxDepth: 1.5 }, "maxDepth must be"], [{ agents: { a: {} }, nope: 1 }, "unknown option nope"],
];
const failures = [];
for (const [options, fragment] of bad) {
  try { agents(options); failures.push("accepted " + JSON.stringify(options)); }
  catch (error) { if (!(error instanceof TypeError) || !error.message.startsWith("agents: ") || !error.message.includes(fragment)) failures.push(String(error.message)); }
}
const single = agents({ agents: { only: { description: "d" } } });
const pair = agents({ default: "b", agents: { a: {}, b: { tools: ["read"] } }, maxRounds: 3 });
if (single.name !== "agents" || pair.name !== "agents") failures.push("plugin name");
globalThis.result = failures.length ? failures.join(" | ") : "ok";
