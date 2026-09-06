// yuke:command-ui — the palette that runs a user command by title.
import { command, keymap } from "yuke:core";
import { ui } from "yuke:ui";

// The first stroke that runs each command here. `candidates` drops what the context shadows.
/** @returns {Record<string, string>} */
function keyHints() {
  /** @type {Record<string, string>} */
  const hints = Object.create(null);
  for (const stroke in keymap.map) {
    const winner = keymap.candidates(stroke)[0];
    if (winner && typeof winner.fn === "string" && !(winner.fn in hints)) hints[winner.fn] = stroke;
  }
  return hints;
}

function openPalette() {
  const hints = keyHints();
  const cmds = command.list().map((c) => ({ ...c, hint: hints[c.name] || "" }));

  return ui.pick({
    title: "commands",
    footer: "type to filter · ↵ run · esc close",
    border: "rounded",
    width: 0.5,
    height: 0.5,
    items: cmds,
    key: c => c.name,
    filterText: c => c.title,
    format: c => ({ text: c.title, right: c.hint ? c.description + " · " + c.hint : c.description }),
    onAccept: c => command.perform(c.name),
  });
}

export const commandUiPlugin = {
  name: "command-ui",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.command(null, {
        "ui:palette": () => ctx.tui.overlay(openPalette().win),
      });
      ctx.tui.keymap({ "ctrl+p": "ui:palette" });
    });
  },
};
