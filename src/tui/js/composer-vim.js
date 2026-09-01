// yuke:composer-vim — opt-in modal keys for the chat composer.
import {
  command,
  root,
  Emitter,
  prevGrapheme,
  nextGrapheme,
  nextWordStart,
  prevWordStart,
  nextWordEnd,
} from "yuke:core";
import { Composer } from "yuke:ui";
import { register, chatView } from "yuke:vim";

/** @typedef {import("yuke:ui").Composer} ComposerType */
/** @typedef {"insert" | "normal"} ComposerMode */
/** @typedef {{ mode: ComposerMode }} ComposerVimState */
/** @typedef {{ start: number, end: number }} LineBounds */

const NORMAL_PROMPT = "▪ ";

// The context every normal-mode binding shares. The `chat` atom keeps them off another pane.
const NORMAL_MODE = "composer && composer_vim == normal";

// Normal mode maps these strokes to `normalKey`.
const NORMAL_KEYS = [
  "h", "l", "j", "k", "0", "^", "$", "w", "b", "e", "G",
  "i", "a", "I", "A", "o", "O", "x", "s", "D", "C", "p", "P",
  "left", "right", "up", "down", "enter", ":",
];
/** @type {WeakMap<ComposerType, ComposerVimState>} */
const states = new WeakMap();

// Each load owns its bus, so a listener never carries across an unload.
let bus = new Emitter();

/** @param {ComposerType} c @returns {ComposerVimState} */
function stateOf(c) {
  let s = states.get(c);
  if (!s) {
    s = { mode: "insert" };
    states.set(c, s);
  }
  return s;
}

/** @param {ComposerType | null} c @returns {ComposerMode | null} */
export function composerMode(c) {
  return c ? stateOf(c).mode : null;
}

/** @param {ComposerType | null} c @param {ComposerMode} mode @returns {void} */
export function setComposerMode(c, mode) {
  if (!c) return;
  const s = stateOf(c);
  if (s.mode === mode) return;
  s.mode = mode;
  if (mode === "normal") c.input.caret = clamp(c.input.text, c.input.caret);
  bus.emit("mode", mode);
  root.invalidate();
}

/** @param {string} text @param {number} caret @returns {LineBounds} */
function lineAt(text, caret) {
  const at = caret > 0 && caret === text.length && text[caret - 1] === "\n" ? caret - 1 : caret;
  const start = text.lastIndexOf("\n", Math.max(0, at - 1)) + 1;
  const end = text.indexOf("\n", at);
  return { start, end: end < 0 ? text.length : end };
}

/** @param {string} text @param {number} caret @returns {number} */
function clamp(text, caret) {
  const { start, end } = lineAt(text, caret);
  if (caret <= start) return start;
  return caret >= end && end > start ? prevGrapheme(text, end) : Math.min(caret, end);
}

/** @param {string} text @param {number} caret @returns {number} */
function firstWord(text, caret) {
  const { start, end } = lineAt(text, caret);
  let i = start;
  while (i < end && (text[i] === " " || text[i] === "\t")) i++;
  return i;
}

/** @returns {ComposerType | null} */
function chatComposer() {
  const v = /** @type {import("yuke:transcript").ChatView | null} */ (chatView());
  return v ? v.composer : null;
}

/** @param {ComposerMode} mode @returns {void} */
function setFocusedMode(mode) {
  setComposerMode(chatComposer(), mode);
}

/** @param {ComposerType} c @returns {true} */
function holdColumn(c) {
  const goal = c.goalCol;
  c.input.caret = clamp(c.input.text, c.input.caret);
  c.goalCol = goal;
  return true;
}

/** @param {ComposerType} c @param {number} caret @returns {true} */
function to(c, caret) {
  c.input.caret = Math.max(0, Math.min(caret, c.input.text.length));
  c.goalCol = null;
  return true;
}

/** @param {ComposerType} c @param {number} from @param {number} to @param {boolean} linewise @param {string | null | undefined} [stored] @returns {true} */
function cut(c, from, to, linewise, stored) {
  if (to <= from && stored == null) return true;
  register.set(stored == null ? c.input.text.slice(from, to) : stored, linewise);
  c.input.replace(from, to, "");
  c.input.caret = clamp(c.input.text, from);
  return true;
}

/** @param {ComposerType} c @param {boolean} after @returns {true} */
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

/** @param {ComposerType} c @param {number} caret @returns {true} */
function enter(c, caret) {
  c.input.caret = Math.max(0, Math.min(caret, c.input.text.length));
  setComposerMode(c, "insert");
  return true;
}

/** @param {ComposerType} c @param {string} first @param {string} k @returns {boolean} */
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

/** @param {ComposerType} c @param {string} k @returns {boolean} */
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
  /** @param {import("yuke:ext").Context} ctx @returns {() => void} */
  apply(ctx) {
    bus = new Emitter();
    const inChat = () => chatComposer() != null;

    ctx.command(inChat, {
      normal: () => setFocusedMode("normal"),
      insert: () => setFocusedMode("insert"),
      cmdline: () => command.perform("ui:cmdline"),
    });

    ctx.keymap({ esc: "composer-vim:normal" });

    // The plugin exposes the mode as a flag, so each binding gates on it.
    ctx.context({ composer_vim: () => composerMode(chatComposer()) || "" });

    // Normal mode sends a key to the keymap, so no pane inside the chat reads it.
    ctx.route("keymap", NORMAL_MODE);

    /** @param {string} k @returns {() => boolean} */
    const motion = (k) => () => {
      const c = chatComposer();
      return c ? normalKey(c, k) : false;
    };
    /** @type {Record<string, () => boolean>} */
    const normal = {};
    for (const k of NORMAL_KEYS) normal[k] = motion(k);
    ctx.keymap(normal, NORMAL_MODE);

    /** @param {(c: ComposerType) => boolean} fn @returns {() => boolean} */
    const edit = (fn) => () => {
      const c = chatComposer();
      return c ? fn(c) : false;
    };
    // `gg` is a chord, while `dd` and `cc` are operators that never expire.
    ctx.keymap({ "g g": edit((c) => pair(c, "g", "g")) }, NORMAL_MODE);
    ctx.keymap(
      { "d d": edit((c) => pair(c, "d", "d")), "c c": edit((c) => pair(c, "c", "c")) },
      NORMAL_MODE,
      { pending: "operator" },
    );

    // A null answer leaves the composer its own glyph.
    ctx.slot(Composer, "prompt", /** @param {ComposerType} c @returns {string | null} */ (c) => (composerMode(c) === "normal" ? NORMAL_PROMPT : null));

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
      bus,
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
