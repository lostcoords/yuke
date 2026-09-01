// yuke:command-ui — the two ways to run a command by name: the palette and the `:` line.
import { command, keymap, root, clip, fill, text, strokeOf, TextInput, caretCol } from "yuke:core";
import { term } from "yuke:term";
import { ui } from "yuke:ui";

// The first stroke bound to a command, or "". A command with two keys shows the first one found.
/** @param {string} name @returns {string} */
function keyHint(name) {
  for (const stroke in keymap.map) {
    const list = keymap.map[stroke];
    if (list && list.some((e) => e.fn === name)) return stroke;
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

// A vim-style ":" line: it matches a command's short name exactly or by unique prefix, gated to
// the commands the current context allows.
function commandShortNames() {
  const names = Object.create(null);
  for (const full in command.map) {
    if (!command.available(full)) continue;
    const short = full.slice(full.lastIndexOf(":") + 1);
    if (!names[short]) names[short] = full;
  }
  return names;
}

/** @param {string} word @returns {string | null} */
function resolveCommand(word) {
  const names = commandShortNames();
  if (names[word]) return names[word];
  let hit = null;
  for (const short in names) {
    if (short.indexOf(word) !== 0) continue;
    if (hit) return null; // an ambiguous prefix
    hit = names[short];
  }
  return hit;
}

// A single bottom row that edits a command word and runs it on Enter. It is modal while open; Esc,
// or Backspace past the prompt, cancels.
class CommandLine {
  constructor() {
    this.input = new TextInput({ onChange: () => (this.error = "") });
    this.error = "";
  }

  get name() {
    return "command-line";
  }

  draw() {
    const w = term.width;
    const h = term.height;
    if (h <= 0 || w <= 0) return;
    const y = h - 1;
    const err = this.error !== "";
    fill(0, y, w, 1, "Normal");
    text(0, y, clip(err ? this.error : ":" + this.input.text, w), err ? "YukeCmdlineErr" : "YukeCmdline");
  }

  cursor() {
    if (this.error) return null;
    return { x: caretCol(term.width, ":", this.input.beforeCaret()), y: term.height - 1, visible: true };
  }

  submit() {
    const word = this.input.text.trim();
    if (word === "") {
      root.popOverlay(this);
      return;
    }
    const name = resolveCommand(word);
    if (!name) {
      this.error = "not a command: " + word;
      return;
    }
    root.popOverlay(this);
    command.perform(name);
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    const s = strokeOf(/** @type {Extract<HostEvent, { type: "key" }>} */ (ev));
    if (s === "esc") {
      root.popOverlay(this);
      return true;
    }
    if (s === "enter") {
      this.submit();
      return true;
    }
    // Backspace past the empty prompt closes the line; otherwise the edit goes to the buffer.
    if (s === "backspace" && this.input.text === "") {
      root.popOverlay(this);
      return true;
    }
    this.input.onKey(ev);
    return true; // modal: consume every key
  }
}

function openCommandLine() {
  return root.pushOverlay(new CommandLine());
}

// The palette, the `:` line, and the styles that line paints itself in.
export const commandUiPlugin = {
  name: "command-ui",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.style({ YukeCmdline: { link: "Normal" }, YukeCmdlineErr: { fg: "danger", bold: true } });
    ctx.command(null, {
      "ui:palette": () => ctx.overlay(openPalette().win),
      "ui:cmdline": () => ctx.overlay(openCommandLine()),
    });
    ctx.keymap({ "ctrl+p": "ui:palette" });
  },
};
