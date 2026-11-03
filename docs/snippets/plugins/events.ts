import type { PluginContext } from "yuke:plugins";

export function apply(ctx: PluginContext): undefined {
  ctx.on("session.update", (event) => {
    if (event.update.sessionUpdate === "state") {
      ctx.notify("info", `${event.sessionId}: ${event.update.state}`);
    }
  });
  return undefined;
}
