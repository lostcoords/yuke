// Shorten the composer prompt. This plugin needs no service in `uses`.

import { TextEditor } from "yuke:tui";

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;

  return tui.widgets.watch((mount) => {
    if (!(mount.widget instanceof TextEditor) || mount.widget.role !== "composer") return undefined;
    const extension = mount.widget.extend(mount.signal);
    extension.setAppearance({ prompt: "> " });
    return () => extension.dispose();
  });
}
