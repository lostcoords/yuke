// yuke:composer-vim — an opt-in modal layer for the chat composer. A user's index.js loads it, or
// the `composer-vim:toggle` command does. Normal mode disables the composer text input, so bare
// keys reach the keymap and scroll the transcript; insert mode types. It reverts on unload.
import { command, root, events } from "yuke:core";

// The focused chat pane's composer, or null when a non-chat view is focused.
function chatComposer() {
  const v = root.active;
  return v && v.name === "chat" ? v.composer : null;
}

// Put the focused composer into `mode`, and announce the change so other plugins can react.
function setFocusedMode(mode) {
  const c = chatComposer();
  if (!c || c.mode === mode) return;
  c.mode = mode;
  events.emit("composer-vim:mode", mode);
  root.invalidate();
}

// Set every chat composer's mode on load and unload, so none is left unable to type.
function setAllModes(mode) {
  const rn = root.root_node;
  if (rn) {
    for (const leaf of rn.leaves()) {
      const v = leaf.view;
      if (v && v.name === "chat" && v.composer) v.composer.mode = mode;
    }
  }
  events.emit("composer-vim:mode", mode);
  root.invalidate();
}

export const composerVim = {
  name: "composer-vim",
  apply(ctx) {
    const inChat = () => chatComposer() != null;

    // In insert mode the composer keeps i/a/":" as text, so the keymap sees them only in normal
    // mode. The composer mode gate is the context; j/k/gg/G already scroll through the transcript.
    ctx.command(inChat, {
      normal: () => setFocusedMode("normal"),
      insert: () => setFocusedMode("insert"),
      cmdline: () => command.perform("ui:cmdline"),
    });

    ctx.keymap({
      esc: "composer-vim:normal",
      i: "composer-vim:insert",
      a: "composer-vim:insert",
      ":": "composer-vim:cmdline",
    });

    // Neovim-style window chords. In insert the composer eats ctrl+w (word-erase), so these reach
    // the keymap only in normal mode or on a non-input pane. ctrl+k does the same in every mode.
    ctx.keymap({
      "ctrl+w h": "focus:left",
      "ctrl+w j": "focus:down",
      "ctrl+w k": "focus:up",
      "ctrl+w l": "focus:right",
      "ctrl+w left": "focus:left",
      "ctrl+w down": "focus:down",
      "ctrl+w up": "focus:up",
      "ctrl+w right": "focus:right",
      "ctrl+w w": "focus:next",
      "ctrl+w v": "window:split-right",
      "ctrl+w s": "window:split-down",
      "ctrl+w c": "window:close",
    });

    // Publish the mode so other plugins can gate their own normal-mode bindings on it.
    ctx.provide("composer-vim", {
      mode: () => (chatComposer() ? chatComposer().mode : null),
      isNormal: () => inChat() && chatComposer().mode === "normal",
    });

    setAllModes("normal"); // a vim user starts in normal mode
    return () => setAllModes("insert");
  },
};
