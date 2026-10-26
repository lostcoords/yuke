// The entry of a plugin folder.
// plugin.json: {"name": "chat-api-example", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// Add a draft command and observe the current chat pane.
/** @import { Context } from "yuke" */
import { currentEntry, currentSession } from "yuke:session";
import { ChatView } from "yuke:chat";

/** @type {string | null} */
let focused = null;

/** Observe session focus and add a focused-draft command. Null TUI skips registration. A failed registration throws. @param {Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;
  ctx.on("pane.focused", () => {
    focused = currentSession()?.sessionId ?? null;
  });

  tui.command.add("prefix-draft", {
    desc: "Add an instruction to the focused draft",
    run: () => {
      const view = tui.root.active;
      if (!(view instanceof ChatView) || !view.composer) return ctx.interaction.notify("focus a chat pane with a composer", "warn");
      view.composer.input.insert("Please ");
    },
  });

  tui.status.add({
    side: "left",
    render: () => {
      const entry = currentEntry();
      return focused === null ? undefined : entry?.session.title || "new chat";
    },
  });
}
