// Save this entry as index.js in a plugin folder, and list the folder in config.json.
// plugin.json: {"name": "picker-example", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// Both commands need the TUI. `yuke check` registers them but does not ask a question.
import { ui } from "yuke:ui";

/** Add a validated picker and a one-line prompt. A failed registration throws; prompt failures become notifications. @param {import("yuke").Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;

  tui.command.add("choose", {
    desc: "Choose an example action",
    slash: true,
    run() {
      const { win } = ui.pick({
        title: "Choose an action",
        items: ["Explain", "Summarize", "Unavailable"],
        body: "Unavailable demonstrates validation: it keeps this window open.",
        validate: (item) => {
          if (item !== "Unavailable") return true;
          ctx.interaction.notify("That action is unavailable", "warn");
          return false;
        },
        onAccept: (item) => {
          ctx.interaction.notify("Selected " + item);
        },
        onCancel: () => {
          ctx.interaction.notify("Selection canceled");
        },
      });
      tui.overlay(win);
    },
  });

  tui.command.add("name", {
    desc: "Ask for one line of text",
    slash: true,
    async run() {
      try {
        const value = await ctx.interaction.input("Name", "Your name", { signal: ctx.signal });
        if (!ctx.alive || value == null) return;
        const name = value.trim();
        if (name === "") return ctx.interaction.notify("Enter a nonempty name", "warn");
        ctx.interaction.notify("Hello " + name);
      } catch (error) {
        if (ctx.alive) ctx.interaction.notify(String(error), "error");
      }
    },
  });
}
