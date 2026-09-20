import { agents } from "yuke:agents";
const bad = [
  [undefined, "options must be an object"], [[], "options must be an object"], [{}, "catalog must be an object"], [{ catalog: [] }, "catalog must be an object"],
  [{ catalog: {} }, "at least one agent"], [{ catalog: { Root: {} } }, "bad key"], [{ catalog: { root: {} } }, "bad key"], [{ catalog: { "a b": {} } }, "bad key"],
  [{ catalog: { a: {}, b: {} } }, "default must name"], [{ catalog: { a: {} }, default: "b" }, "default must name"], [{ catalog: { a: {} }, default: "toString" }, "default must name"],
  [{ catalog: { a: { tools: [] } } }, "tools must be"], [{ catalog: { a: { tools: ["bash"] } } }, "tools must be"], [{ catalog: { a: { tools: ["read", "read"] } } }, "tools must be"],
  [{ catalog: { a: { model: "" } } }, "nonempty string model"], [{ catalog: { a: { prompt: 3 } } }, "nonempty string prompt"], [{ catalog: { a: { extra: 1 } } }, "unknown field extra"], [{ catalog: { a: null } }, "must be an object"],
  [{ catalog: { a: {} }, maxConcurrent: 0 }, "maxConcurrent must be"], [{ catalog: { a: {} }, maxRounds: 0 }, "maxRounds must be"], [{ catalog: { a: {} }, maxDepth: 1.5 }, "maxDepth must be"], [{ catalog: { a: {} }, nope: 1 }, "unknown option nope"],
];
const failures = [];
for (const [options, fragment] of bad) {
  try { agents(options); failures.push("accepted " + JSON.stringify(options)); }
  catch (error) { if (!(error instanceof TypeError) || !error.message.startsWith("agents: ") || !error.message.includes(fragment)) failures.push(String(error.message)); }
}
const single = agents({ catalog: { only: { description: "d" } } });
const pair = agents({ default: "b", catalog: { a: {}, b: { tools: ["read"] } }, maxDepth: 3 });
if (single.name !== "agents" || pair.name !== "agents") failures.push("plugin name");
globalThis.result = failures.length ? failures.join(" | ") : "ok";
