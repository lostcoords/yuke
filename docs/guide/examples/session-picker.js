// Show a saved session. Add `"uses": ["chat"]` to the manifest entry.

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;
  const sessions = ctx.get("sessions");
  const chat = ctx.get("chat");

  tui.commands.add({
    name: "open",
    description: "Open one of the newest 20 saved sessions",
    run: async () => {
      const page = await sessions.list({ limit: 20 });
      const selected = await tui.select({
        title: "Recent sessions",
        items: page.sessions,
        label: (row) => row.session.sessionId,
        signal: ctx.signal,
      });
      if (selected) await chat.show(selected.session.sessionId);
    },
  });
  return undefined;
}
