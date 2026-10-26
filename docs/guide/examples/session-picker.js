// Save this entry as index.js in a plugin folder, and list the folder in config.json.
// plugin.json: {"name": "session-picker", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// This browser lists top-level sessions across workspaces without claiming their ownership.
import { client } from "yuke";
import { currentPane, showSession } from "yuke:session";
import { ui } from "yuke:ui";

/** @typedef {{ id: string, title: string, root: string }} Item */

/** Add a paginated session picker in the TUI. Null TUI skips registration. Query failures become notifications. @param {import("yuke").Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;

  let loading = false;
  /** @type {import("yuke").Disposer | null} */
  let close = null;
  tui.command.add("browse-sessions", {
    desc: "Browse sessions across workspaces",
    slash: true,
    async run() {
      if (loading || !ctx.alive) return;
      loading = true;
      try {
        /** @type {Item[]} */
        const items = [];
        /** @type {string | undefined} */
        let cursor;
        do {
          const page = await client.sessionList({ population: { type: "top_level" }, limit: 20, cursor });
          if (!ctx.alive) return;
          for (let i = 0; i < page.items.length; i++) {
            const session = page.items[i].session;
            items.push({ id: session.id, title: session.title, root: session.root });
          }
          cursor = page.next_cursor;
        } while (cursor != null);

        if (close) close();
        const { win } = ui.pick({
          title: "Sessions",
          items,
          filterText: (item) => item.title + " " + item.root,
          format: (item) => item.title + " — " + item.root,
          key: (item) => item.id,
          body: items.length === 0 ? "No sessions found." : "Choose a session to open.",
          onAccept: (item) => {
            if (!ctx.alive) return;
            const pane = currentPane();
            if (!pane) return ctx.interaction.notify("No current session pane", "warn");
            showSession(pane, item.id);
          },
          onCancel: () => { ctx.interaction.notify("Session selection canceled"); },
        });
        close = tui.overlay(win, () => { close = null; });
      } catch (error) {
        if (ctx.alive) ctx.interaction.notify("Could not list sessions: " + String(error), "error");
      } finally {
        loading = false;
      }
    },
  });
}
