(async () => {
  const list = client.catalogList;
  let ready = false;
  client.catalogList = async () => { const c = await list(); c.providers[0].state = ready ? "ready" : "needs_api_key"; return c; };
  client.authList = async () => ({ providers: [{ provider_id: "p", can_login: false }] });
  ctx.interaction.input = async (_title, _placeholder, options) => { if (!options.secret) throw new Error("visible key"); return "secret"; };
  client.authSetApiKey = async (id, key) => { if (id !== "p" || key !== "secret") throw new Error("credential"); ready = true; };
  client.catalogReload = async () => {};
  await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, undefined, site);
  if (!ready || stats.saves !== 1 || stats.creates !== 1) throw new Error(JSON.stringify(stats));
  result = "ok";
})().catch((e) => result = e.stack || e.message);
