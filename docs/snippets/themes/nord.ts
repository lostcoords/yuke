import type { PluginContext } from "yuke:plugins";

export function apply(ctx: PluginContext): undefined {
  ctx.get("tui")?.styles.addTheme("nord", {
    dark: {
      palette: { fg: "#eceff4", bg: "#2e3440", accent: "#88c0d0", surface: "#3b4252" },
      groups: { "chat.title": { fg: "#ebcb8b" } },
    },
    light: {
      palette: { accent: "#2e6f8e" },
    },
  });
  return undefined;
}
