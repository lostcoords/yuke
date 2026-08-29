// yuke:composer-vim — opt-in modal keys for the chat composer.
import {
  command,
  root,
  events,
  modalKey,
  isTextKey,
  takePrefix,
  armPrefix,
  prevGrapheme,
  nextGrapheme,
  nextWordStart,
  prevWordStart,
  nextWordEnd,
} from "yuke:core";
import { Composer } from "yuke:ui";
import { register, chatView } from "yuke:vim";

const NORMAL_PROMPT = "▪ ";
const states = new WeakMap();

function stateOf(c) {
  let s = states.get(c);
  if (!s) {
    s = { mode: "insert", pending: "" };
    states.set(c, s);
  }
  return s;
}

export function composerMode(c) {
  return c ? stateOf(c).mode : null;
}

export function setComposerMode(c, mode) {
  if (!c) return;
  const s = stateOf(c);
  if (s.mode === mode) return;
  s.mode = mode;
  s.pending = "";
  if (mode === "normal") c.input.caret = clamp(c.input.text, c.input.caret);
  events.emit("composer-vim:mode", mode);
  root.invalidate();
}

function lineAt(text, caret) {
  const at = caret > 0 && caret === text.length && text[caret - 1] === "\n" ? caret - 1 : caret;
  const start = text.lastIndexOf("\n", Math.max(0, at - 1)) + 1;
  const end = text.indexOf("\n", at);
  return { start, end: end < 0 ? text.length : end };
}

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

function chatComposer() {
  const v = chatView();
  return v ? v.composer : null;
}

function setFocusedMode(mode) {
  setComposerMode(chatComposer(), mode);
}

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

function cut(c, from, to, linewise, stored) {
  if (to <= from && stored == null) return true;
  register.set(stored == null ? c.input.text.slice(from, to) : stored, linewise);
  c.input.replace(from, to, "");
  c.input.caret = clamp(c.input.text, from);
  return true;
}

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
  setComposerMode(c, "insert");
  return true;
}

function pair(c, first, k) {
  const t = c.input;
  const { start, end } = lineAt(t.text, t.caret);
  if (first === "g" && k === "g") return to(c, 0);
  if (first === "d" && k === "d") {
    const body = t.text.slice(start, end);
    if (end < t.text.length) return cut(c, start, end + 1, true, body);
    return cut(c, start > 0 ? start - 1 : 0, end, true, body);
  }
  if (first === "c" && k === "c") {
    register.set(t.text.slice(start, end), true);
    t.replace(start, end, "");
    return enter(c, start);
  }
  return false;
}

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
      armPrefix(stateOf(c), k);
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

    ctx.keymap({ esc: "composer-vim:normal" });

    ctx.advise(Composer.prototype, "onKey", "around", function (inner, ev) {
      if (composerMode(this) !== "normal") return inner(ev);
      const k = modalKey(ev);
      const first = takePrefix(stateOf(this));
      if (first) {
        if (pair(this, first, k)) return true;
        // An unknown second key still runs, so `gh` moves as `h`.
      }
      if (normalKey(this, k)) return true;
      return isTextKey(ev);
    });

    ctx.advise(Composer.prototype, "_prompt", "around", function (inner) {
      return composerMode(this) === "normal" ? NORMAL_PROMPT : inner();
    });

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

    ctx.status({ side: "right", order: 0, render: () => {
      const mode = composerMode(chatComposer());
      return mode ? mode.toUpperCase() : "";
    } });

    ctx.provide("composer-vim", {
      mode: () => composerMode(chatComposer()),
      isNormal: () => inChat() && composerMode(chatComposer()) === "normal",
    });

    setFocusedMode("normal");
    return () => {
      const c = chatComposer();
      if (c) {
        setComposerMode(c, "insert");
        states.delete(c);
      }
    };
  },
};
