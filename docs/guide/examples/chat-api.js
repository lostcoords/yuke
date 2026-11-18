// Show a session label below each composer. Add `"uses": ["chat"]` to the manifest entry.

import { composerRows } from "yuke:chat";

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  if (!ctx.get("tui")) return undefined;
  return ctx.get("chat").addComposerView("below", (_mount, pane) =>
    composerRows(() => [
      {
        text: pane.session ? `Session ${pane.session}` : "New conversation",
        style: { dim: true },
      },
    ]),
  );
}
