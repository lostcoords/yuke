// Add a draft command and observe the current chat pane.
import { plugins } from "yuke";
import { currentEntry, currentPane, currentSession } from "yuke:session";

/** @type {string | null} */
let focused = null;

plugins.use({
  name: "chat-api-example",
  apply(ctx) {
    ctx.inject(["tui"], (c) => {
      c.on("pane.focused", () => {
        focused = currentSession()?.sessionId ?? null;
      });

      c.tui.command.add("prefix-draft", {
        desc: "Add an instruction to the current draft",
        run: () => {
          const input = currentPane()?.composer?.input;
          if (!input) return c.interaction.notify("the current pane has no composer", "warn");
          input.insert(input.text === "" ? "Please " : "\nPlease ");
        },
      });

      c.tui.status.add({
        side: "left",
        render: () => {
          const entry = currentEntry();
          return focused === null ? null : entry?.session.title || "new chat";
        },
      });
    });
  },
});
