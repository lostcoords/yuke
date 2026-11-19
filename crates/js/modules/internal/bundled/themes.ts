/**
 * The bundled plugin `themes`. It applies the saved theme, and its command `themes:open` lists the themes in a picker.
 * The selected row shows at once. Enter saves it, and Esc gives the theme from before.
 */

import { FileSystemError, readTextFile, writeTextFile } from "yuke:fs";
import type { PluginContext } from "yuke:plugins";
import { Picker, type Tui } from "yuke:tui";

const FILE = "theme.json";
const DEFAULT = "default";

/** The name of the saved theme, or the default theme without one. A file that does not read gives a notice too. */
async function saved(ctx: PluginContext): Promise<string> {
  try {
    const value: unknown = JSON.parse(await readTextFile(FILE, { folder: ctx.dataDir, fatal: true }));
    const name = (value as { name?: unknown } | null)?.name;
    return typeof name === "string" && name !== "" ? name : DEFAULT;
  } catch (error) {
    if (!(error instanceof FileSystemError && error.code === "ENOENT")) {
      ctx.notify("error", `The saved theme did not load: ${String(error)}`);
    }
    return DEFAULT;
  }
}

/** Show the picker. A choice replaces `applied`, the theme of this plugin. */
function open(ctx: PluginContext, tui: Tui, applied: { remove: () => void }): void {
  const before = tui.styles.theme;
  // The active theme comes first, so the first selection changes nothing.
  const names = [before, ...tui.styles.themes().filter((name) => name !== before)];
  const items = names.map((name) => ({ name }));
  // The theme of the selected row. Its remover brings back the theme from before.
  let preview: (() => void) | undefined;
  const picker = new Picker({
    items,
    id: (item) => item.name,
    label: (item) => item.name,
    onSelectionChange: (item) => {
      if (item === undefined) return;
      const next = tui.styles.setTheme(item.name);
      preview?.();
      preview = next;
    },
    onChoose: (item) => {
      dialog.close();
      const chosen = preview ?? tui.styles.setTheme(item.name);
      preview = undefined;
      applied.remove();
      applied.remove = chosen;
      writeTextFile(FILE, JSON.stringify({ name: item.name }), { folder: ctx.dataDir, atomic: true }).catch(
        (error: unknown) => ctx.notify("error", `yuke could not save the theme: ${String(error)}`),
      );
    },
    onCancel: () => {
      dialog.close();
      preview?.();
      preview = undefined;
    },
  });
  const dialog = tui.dialog({ title: "Theme", body: picker });
}

export async function apply(ctx: PluginContext): Promise<undefined> {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const applied = { remove: tui.styles.setTheme(await saved(ctx)) };
  tui.commands.add({
    name: "open",
    slash: "themes",
    description: "Choose a theme",
    run: () => open(ctx, tui, applied),
  });
  return undefined;
}
