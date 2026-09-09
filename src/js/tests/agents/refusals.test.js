(async () => {
  for (const model of [undefined, null, "large", "p/model"]) {
    try { await spawnAgent(ctx, { name: "one", message: "task", model }, undefined, site); throw new Error("accepted"); }
    catch (e) { if (e.code !== "bad_request") throw e; }
  }
  if (stats.gets || stats.prompts) throw new Error("validation ran too late");
  ctx.interaction.interactive = false;
  try { await spawnAgent(ctx, { name: "headless", message: "task", model: "small" }, undefined, site); throw new Error("headless accepted"); }
  catch (e) { if (e.code !== "setup_required") throw e; }
  ctx.interaction.interactive = true;
  ctx.interaction.confirm = async () => false;
  try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, undefined, site); throw new Error("canceled accepted"); }
  catch (e) { if (e.code !== "setup_declined") throw e; }
  ctx.interaction.confirm = async () => undefined;
  try { await spawnAgent(ctx, { name: "dismissed", message: "task", model: "small" }, undefined, site); throw new Error("dismissed accepted"); }
  catch (e) { if (e.code !== "setup_canceled") throw e; }
  if (stats.saves || stats.creates) throw new Error("side effect");
  result = "ok";
})().catch((e) => result = e.stack || e.message);
