/**
 * The bundled plugin `themes`. It applies the saved theme, and its command `themes:open` lists the themes in a picker.
 * The selected row shows at once. Enter saves it, and Esc gives the theme from before.
 */

import { FileSystemError, readTextFile, writeTextFile } from "yuke:fs";
import type { PluginContext } from "yuke:plugins";
import { Picker, type Tui } from "yuke:tui";

const FILE = "theme.json";

/** The name of the saved theme. A missing file gives none, and another failure is a notice. */
async function saved(ctx: PluginContext): Promise<string | undefined> {
  try {
    const value: unknown = JSON.parse(await readTextFile(FILE, { baseDir: ctx.dataDir, fatal: true }));
    const name = (value as { name?: unknown } | null)?.name;
    return typeof name === "string" && name !== "" ? name : undefined;
  } catch (error) {
    if (!(error instanceof FileSystemError && error.code === "ENOENT")) {
      ctx.notify("error", `the saved theme did not load: ${String(error)}`);
    }
    return undefined;
  }
}

function open(ctx: PluginContext, tui: Tui): void {
  const before = tui.styles.theme;
  // The active theme comes first, so the first selection changes nothing.
  const names = [before, ...[undefined, ...tui.styles.themes()].filter((name) => name !== before)];
  const items = names.map((name) => ({ name }));
  const picker = new Picker({
    items,
    key: (item) => item.name ?? "",
    label: (item) => item.name ?? "default",
    select: (item) => {
      if (item !== undefined) tui.styles.setTheme(item.name);
    },
    choose: (item) => {
      dialog.close();
      tui.styles.setTheme(item.name);
      const text = JSON.stringify(item.name === undefined ? {} : { name: item.name });
      writeTextFile(FILE, text, { baseDir: ctx.dataDir, atomic: true }).catch((error: unknown) =>
        ctx.notify("error", `the theme did not save: ${String(error)}`),
      );
    },
    cancel: () => {
      dialog.close();
      tui.styles.setTheme(before);
    },
  });
  const dialog = tui.dialog({ title: () => "Theme", body: picker });
}

export async function apply(ctx: PluginContext): Promise<undefined> {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  tui.styles.setTheme(await saved(ctx));
  tui.commands.add({
    name: "open",
    description: "Choose a theme",
    run: () => open(ctx, tui),
  });
  return undefined;
}
