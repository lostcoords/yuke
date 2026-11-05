/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  ctx.notify("info", "Plugin loaded");
  return undefined;
}
