// yuke:command-ui — the palette that runs a command by name.
import { command, keymap } from "yuke:core";
import { ui } from "yuke:ui";

// The first stroke that runs a command here, or "". `candidates` drops what the context shadows.
/** @param {string} name @returns {string} */
function keyHint(name) {
  for (const stroke in keymap.map) {
    const winner = keymap.candidates(stroke)[0];
    if (winner && winner.fn === name) return stroke;
  }
  return "";
}

function openPalette() {
  const cmds = Object.keys(command.map)
    .sort()
    .filter((name) => command.available(name))
    .map((name) => ({ name: name, hint: keyHint(name) }));

  const opened = ui.pick({
    title: "commands",
    footer: "type to filter · ↵ run · esc close",
    border: "rounded",
    width: 0.5,
    height: 0.5,
    items: cmds,
    key: c => c.name,
    filterText: c => c.name,
    format: c => ({ text: c.name, right: c.hint }),
    onAccept: c => command.perform(c.name),
  });
  return opened;
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
