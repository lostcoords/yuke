import type { PluginContext } from "yuke:plugins";

export function apply(ctx: PluginContext): undefined {
  ctx.addListener("session.update", (event) => {
    if (event.update.kind === "state") {
      ctx.notify("info", `${event.sessionId}: ${event.update.state}`);
    }
  });
  return undefined;
}
