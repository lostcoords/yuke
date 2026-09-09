import { stopAllChildren } from "yuke:agent-tools";
(async () => {
  client.sessionList = async () => ({ items: ["active", "idle", "foreign-owner"].map((id) => ({ session: { id } })), next_cursor: null });
  client.sessionCancelRun = async (id) => { if (id === "foreign-owner") throw new Error("busy"); return { canceled_run: id === "active" ? 1 : null, cleared_inputs: [] }; };
  const stopped = await stopAllChildren("parent");
  if (stopped.stopped !== 1 || stopped.unchanged !== 1 || stopped.failed !== 1) throw new Error(JSON.stringify(stopped));
  result = "ok";
})().catch((e) => result = e.stack || e.message);
