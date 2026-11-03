// Add one command. This plugin needs no service in `uses`.

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;

  tui.commands.add({
    name: "hi",
    description: "Say hi",
    run: () => ctx.notify("info", "hi from hello"),
  });
  tui.keys.bind("ctrl+g", "hi");
  return undefined;
}
