(async () => {
  ctx.interaction.select = async (title, options) => title === "Subagent needs attention" ? options[2] : options[0];
  ctx.interaction.confirm = async () => false;
  await recoverAgent(ctx, "child", "small");
  if (stats.changes !== 1 || stats.saves || stats.creates) throw new Error(JSON.stringify(stats));
  if (patched.id !== "child" || patched.patch.model !== "p/family/model") throw new Error(JSON.stringify(patched));
  result = "ok";
})().catch((e) => result = e.stack || e.message);
