// Show a session label below each composer. Add `"uses": ["chat"]` to the manifest entry.

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  if (!ctx.get("tui")) return undefined;
  return ctx.get("chat").addComposerRows("below", (pane) => [
    {
      text: pane.session ? `Session ${pane.session}` : "New conversation",
      style: { dim: true },
    },
  ]);
}
