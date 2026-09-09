(async () => {
  ctx.interaction.confirm = async () => { map.revision = "2"; map.config.models.medium = { model: "other/model" }; return true; };
  await spawnAgent(ctx, { name: "saved", message: "task", model: "small" }, undefined, site);
  if (map.config.models.medium.model !== "other/model" || map.config.models.small.model !== "p/family/model") throw new Error("lost edit");
  map.config.models = {};
  ctx.interaction.confirm = async () => true;
  client.agentsUpdate = async () => { throw Object.assign(new Error("disk full"), { code: "runtime_failed" }); };
  try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, undefined, site); throw new Error("save accepted"); }
  catch (e) { if (e.code !== "runtime_failed") throw e; }
  if (stats.creates !== 1) throw new Error("spawn after save failure");
  result = "ok";
})().catch((e) => result = e.stack || e.message);
