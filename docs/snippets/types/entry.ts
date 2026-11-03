import type { PluginContext, SessionContext } from "yuke:plugins";

export function apply(ctx: PluginContext) {
  ctx.notify("info", "Plugin loaded");
  return undefined;
}

export function session(session: SessionContext) {
  session.hook("tool.before", (event) => {
    if (event.call.name === "exec") return { block: "This plugin blocks exec." };
    return undefined;
  });
  return undefined;
}
