import { defineConfig } from "yuke:kernel";
(async () => {
  const results = await Promise.all([
    spawnAgent(ctx, { name: "one", message: "task one", model: "small" }, undefined, site),
    spawnAgent(ctx, { name: "two", message: "task two", model: "medium" }, undefined, site),
  ]);
  if (stats.saves !== 1 || stats.prompts !== 2 || stats.creates !== 2) throw new Error(JSON.stringify(stats));
  if (results[0].state !== "queued" || results[1].model !== "p/family/model" || !results[0].note.includes("end your turn")) throw new Error("receipt");
  if (created.max_rounds !== 50) throw new Error("max_rounds");
  defineConfig({ agents: { maxRounds: 7 } });
  await spawnAgent(ctx, { name: "four", message: "task", model: "small" }, undefined, site);
  if (created.max_rounds !== 7) throw new Error("configured max_rounds");
  try { defineConfig({ agents: { maxRounds: 0 } }); throw new Error("accepted zero max_rounds"); }
  catch (error) { if (!(error instanceof TypeError)) throw error; }
  if (created.model || created.reasoning || !created.initial_input || created.child.site.message_id !== 2) throw new Error("admission");
  await spawnAgent(ctx, { name: "three", message: "task", model: "small" }, undefined, site);
  if (stats.prompts !== 2 || stats.saves !== 1) throw new Error("repeat setup");
  result = "ok";
})().catch((e) => result = e.stack || e.message);
