// yuke:composer-vim — an opt-in modal layer for the chat composer. A user's index.js loads it, or
// the `composer-vim:toggle` command does. Normal mode disables the composer text input, so bare
// keys reach the keymap and scroll the transcript; insert mode types. It reverts on unload.
import {
  command,
  root,
  events,
  modalKey,
  isTextKey,
  register,
  prevGrapheme,
  nextGrapheme,
  nextWordStart,
  prevWordStart,
  nextWordEnd,
} from "yuke:core";
import { Composer } from "yuke:ui";

// The first key of a two-key command: "g", "d", or "c". No pending key survives an unload.
const pending = new WeakMap();

// The logical line under the caret. A wrapped row is not a line, as in vim.
function lineAt(text, caret) {
  const at = caret > 0 && caret === text.length && text[caret - 1] === "\n" ? caret - 1 : caret;
  const start = text.lastIndexOf("\n", Math.max(0, at - 1)) + 1;
  const end = text.indexOf("\n", at);
  return { start, end: end < 0 ? text.length : end };
}

// Normal mode holds the caret on a character, so it never sits past the last one of its line.
function clamp(text, caret) {
  const { start, end } = lineAt(text, caret);
  if (caret <= start) return start;
  return caret >= end && end > start ? prevGrapheme(text, end) : Math.min(caret, end);
}

function firstWord(text, caret) {
  const { start, end } = lineAt(text, caret);
  let i = start;
  while (i < end && (text[i] === " " || text[i] === "\t")) i++;
  return i;
}

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
  if (mode === "normal") c.input.caret = clamp(c.input.text, c.input.caret);
  events.emit("composer-vim:mode", mode);
  root.invalidate();
}

// Set every chat composer's mode on load and unload, so none is left unable to type.
function setAllModes(mode) {
  const rn = root.root_node;
  if (rn) {
    for (const leaf of rn.leaves()) {
      const v = leaf.view;
      if (!v || v.name !== "chat" || !v.composer) continue;
      v.composer.mode = mode;
      if (mode === "normal") v.composer.input.caret = clamp(v.composer.input.text, v.composer.input.caret);
    }
  }
  events.emit("composer-vim:mode", mode);
  root.invalidate();
}

// Move the caret and report that the key was used.
function holdColumn(c) {
  const goal = c.goalCol;
  c.input.caret = clamp(c.input.text, c.input.caret);
  c.goalCol = goal;
  return true;
}

function to(c, caret) {
  c.input.caret = Math.max(0, Math.min(caret, c.input.text.length));
  c.goalCol = null;
  return true;
}

// Delete [from, to) and keep the caret on a character. `stored` is what the register keeps, which
// is the line body for a linewise cut, never its separator.
function cut(c, from, to, linewise, stored) {
  if (to <= from && stored == null) return true;
  register.set(stored == null ? c.input.text.slice(from, to) : stored, linewise);
  c.input.replace(from, to, "");
  c.input.caret = clamp(c.input.text, from);
  return true;
}

// Put the register after the caret, or on its own line when the yank took whole lines.
function put(c, after) {
  const t = c.input;
  if (!register.text && !register.linewise) return true;
  if (register.linewise) {
    const { start, end } = lineAt(t.text, t.caret);
    const at = after ? end : start;
    t.replace(at, at, after ? "\n" + register.text : register.text + "\n");
    return to(c, at + (after ? 1 : 0));
  }
  const at = after ? Math.min(nextGrapheme(t.text, t.caret), lineAt(t.text, t.caret).end) : t.caret;
  t.replace(at, at, register.text);
  return to(c, clamp(t.text, prevGrapheme(t.text, at + register.text.length)));
}

function enter(c, caret) {
  c.input.caret = Math.max(0, Math.min(caret, c.input.text.length));
  setFocusedMode("insert");
  return true;
}

// The second key of "gg", "dd", or "cc". Any other key cancels the pair.
function pair(c, first, k) {
  const t = c.input;
  const { start, end } = lineAt(t.text, t.caret);
  if (first === "g" && k === "g") return to(c, 0);
  if (first === "d" && k === "d") {
    // A line takes its own newline with it, and the last line takes the one before it.
    const body = t.text.slice(start, end);
    if (end < t.text.length) return cut(c, start, end + 1, true, body);
    return cut(c, start > 0 ? start - 1 : 0, end, true, body);
  }
  if (first === "c" && k === "c") {
    register.set(t.text.slice(start, end), true);
    t.replace(start, end, "");
    return enter(c, start);
  }
  return true;
}

// One normal-mode key. Return false to leave the key for another layer.
function normalKey(c, k) {
  const t = c.input;
  const text = t.text;
  const { start, end } = lineAt(text, t.caret);
  switch (k) {
    case "h":
    case "left":
      return to(c, Math.max(start, prevGrapheme(text, t.caret)));
    case "l":
    case "right":
      return to(c, clamp(text, nextGrapheme(text, t.caret)));
    case "j":
    case "down":
      return c.moveRow(1) && holdColumn(c);
    case "k":
    case "up":
      return c.moveRow(-1) && holdColumn(c);
    case "0":
      return to(c, start);
    case "^":
      return to(c, firstWord(text, t.caret));
    case "$":
      return to(c, clamp(text, end));
    case "w":
      return to(c, clamp(text, nextWordStart(text, t.caret)));
    case "b":
      return to(c, prevWordStart(text, t.caret));
    case "e":
      return to(c, clamp(text, nextWordEnd(text, t.caret)));
    case "G":
      return to(c, clamp(text, text.length));
    case "g":
    case "d":
    case "c":
      pending.set(c, k);
      return true;
    case "i":
      return enter(c, t.caret);
    case "a":
      return enter(c, nextGrapheme(text, t.caret));
    case "I":
      return enter(c, firstWord(text, t.caret));
    case "A":
      return enter(c, end);
    case "o":
      t.replace(end, end, "\n");
      return enter(c, end + 1);
    case "O":
      t.replace(start, start, "\n");
      return enter(c, start);
    case "x":
      return cut(c, t.caret, Math.min(nextGrapheme(text, t.caret), end), false);
    case "s":
      register.set(text.slice(t.caret, nextGrapheme(text, t.caret)), false);
      t.replace(t.caret, nextGrapheme(text, t.caret), "");
      return enter(c, t.caret);
    case "D":
      return cut(c, t.caret, end, false);
    case "C":
      register.set(text.slice(t.caret, end), false);
      t.replace(t.caret, end, "");
      return enter(c, t.caret);
    case "p":
      return put(c, true);
    case "P":
      return put(c, false);
    // A chat composer sends from either mode, so normal mode keeps enter as submit.
    case "enter":
      c.submit();
      return true;
    case ":":
      command.perform("ui:cmdline");
      return true;
  }
  return false;
}

export const composerVim = {
  name: "composer-vim",
  apply(ctx) {
    const inChat = () => chatComposer() != null;

    ctx.command(inChat, {
      normal: () => setFocusedMode("normal"),
      insert: () => setFocusedMode("insert"),
      cmdline: () => command.perform("ui:cmdline"),
    });

    // Only `esc` needs a binding. Insert mode passes it through, and normal mode reads every other
    // key itself, so a bare letter never reaches a global command.
    ctx.keymap({ esc: "composer-vim:normal" });

    ctx.advise(Composer.prototype, "onKey", "around", function (inner, ev) {
      if (this.mode !== "normal") return inner(ev);
      const k = modalKey(ev);
      const first = pending.get(this);
      if (first) {
        pending.set(this, "");
        if (pair(this, first, k)) return true;
      }
      if (normalKey(this, k)) return true;
      // A named key or a chord still reaches the keymap. A bare character never does.
      return isTextKey(ev);
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

    // The bar shows the mode, so the composer never has to hide the draft to say which one.
    ctx.status({ side: "right", order: 0, render: () => (chatComposer() ? chatComposer().mode.toUpperCase() : "") });

    // Publish the mode so other plugins can gate their own normal-mode bindings on it.
    ctx.provide("composer-vim", {
      mode: () => (chatComposer() ? chatComposer().mode : null),
      isNormal: () => inChat() && chatComposer().mode === "normal",
    });

    setAllModes("normal"); // a vim user starts in normal mode
    // A pane that does not hold the focus must not keep a pending key across a reload.
    return () => {
      const rn = root.root_node;
      if (rn) {
        for (const leaf of rn.leaves()) {
          if (leaf.view && leaf.view.name === "chat" && leaf.view.composer) pending.delete(leaf.view.composer);
        }
      }
      setAllModes("insert");
    };
  },
};
