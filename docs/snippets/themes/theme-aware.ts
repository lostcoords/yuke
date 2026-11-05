import type { PluginContext } from "yuke:plugins";

export function apply(ctx: PluginContext): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  let undo = (): void => {};
  const look = (): void => {
    undo();
    undo = tui.styles.theme === "nord" ? tui.styles.set({ "notes.title": { fg: "#ebcb8b" } }) : () => {};
  };
  look();
  ctx.on("theme.changed", look);
  return undefined;
}
