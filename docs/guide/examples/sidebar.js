// Add a help column beside the pane tree. This plugin needs no service in `uses`.

import { stack } from "yuke:tui";

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;

  const root = tui.setRoot(() =>
    stack("row", [
      { view: tui.panes.view, size: "fill" },
      {
        size: (size) => (size.width >= 80 ? 24 : 0),
        view: {
          draw: (canvas) => {
            canvas.text(1, 0, "Shortcuts", { bold: true });
            canvas.text(1, 2, "/       Commands");
            canvas.text(1, 3, "ctrl+k  Pane keys");
          },
        },
      },
    ]),
  );
  return () => root.close();
}
