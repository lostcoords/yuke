// Watch session opens. This plugin needs no service in `uses`.

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  return ctx.addListener("session.opened", (event) => {
    ctx.notify("info", `Opened ${event.sessionId}`);
  });
}
