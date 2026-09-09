import { editSlot } from "yuke:agents";
(async () => {
  ctx.interaction.confirm = async () => { throw new Error("unexpected onboarding"); };
  await editSlot(ctx, "small");
  if (map.config.models.small.model !== "p/family/model" || map.config.models.medium || stats.creates) throw new Error("wrong edit scope");
  await editSlot(ctx, "medium");
  if (stats.saves !== 2 || map.config.models.small.model !== "p/family/model" || map.config.models.medium.model !== "p/family/model") throw new Error("lost slot");
  ctx.interaction.select = async () => undefined;
  await editSlot(ctx, "small");
  if (stats.saves !== 2) throw new Error("canceled edit saved");
  result = "ok";
})().catch((e) => result = e.stack || e.message);
