// yuke:vim — opt-in modal editing for the chat composer. Off by default; load via the `vim:toggle`
// command or `config.vim`. Normal mode disables the composer's text input so bare keys fall through
// to the keymap and the transcript scrolls; insert mode types. A plugin, so it reverts on unload.
import { command, root, events } from "yuke:core";

// The focused chat pane's composer, or null when a non-chat view is focused.
function chatComposer() {
  const v = root.active;
  return v && v.name === "chat" ? v.composer : null;
}

// Put the focused composer into `mode`, announcing the change so other plugins can react.
function setFocusedMode(mode) {
  const c = chatComposer();
  if (!c || c.mode === mode) return;

  c.mode = mode;
  events.emit("vim:mode", mode);
  root.invalidate();
}

// Set every chat composer's mode (on load/unload), so none is left stuck unable to type.
function setAllModes(mode) {
  const rn = root.root_node;
  if (rn) {
    for (const leaf of rn.leaves()) {
      const v = leaf.view;
      if (v && v.name === "chat" && v.composer) v.composer.mode = mode;
    }
  }

  events.emit("vim:mode", mode);
  root.invalidate();
}

export const vim = {
  name: "vim",
  apply(ctx) {
    const inChat = () => chatComposer() != null;

    // In insert mode the composer swallows i/a/":" as text, so the keymap only sees them in normal
    // mode — the composer's mode gate is the context selection, no per-key predicate needed beyond
    // "a chat is focused". j/k/gg/G already scroll because the transcript handles them.
    ctx.command(inChat, {
      normal: () => setFocusedMode("normal"),
      insert: () => setFocusedMode("insert"),
      cmdline: () => command.perform("ui:cmdline"),
    });

    ctx.keymap({
      esc: "vim:normal",
      i: "vim:insert",
      a: "vim:insert",
      ":": "vim:cmdline",
    });

    // Neovim-style window chords. In insert the composer eats ctrl+w (word-erase), so these only
    // reach the keymap in normal mode or on a non-input pane. ctrl+k does the same in every mode.
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
    ctx.provide("vim", {
      mode: () => (chatComposer() ? chatComposer().mode : null),
      isNormal: () => inChat() && chatComposer().mode === "normal",
    });

    setAllModes("normal"); // vim users expect to start in normal mode

    return () => setAllModes("insert");
  },
};
