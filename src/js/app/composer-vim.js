// Opt-in modal keys for the chat composer.
import { events } from "yuke:internal/kernel";
import { windowKeys } from "yuke:internal/keys";
import { prevGrapheme, nextGrapheme, nextWordStart, prevWordStart, nextWordEnd } from "yuke:internal/text-input";
import { register } from "yuke:internal/vim";
import { focusedChatView } from "yuke:internal/chat";

/** @import { ChatView } from "yuke:internal/chat-view" */
/** @import { Context } from "yuke:internal/ext" */
/** @import { Composer as ComposerType } from "yuke:internal/ui" */
/** @typedef {"insert" | "normal"} ComposerMode */
/** @typedef {{ mode: (c: ComposerType | null) => ComposerMode | null, setMode: (c: ComposerType | null, mode: ComposerMode) => void }} ComposerVim */
// A key answers false when it does not apply, true when it edits, and "insert" when it also leaves normal mode.
/** @typedef {boolean | "insert"} KeyResult */
/** @typedef {{ start: number, end: number }} LineBounds */

const NORMAL_PROMPT = "▪ ";

// The context every normal-mode binding shares. The `chat` atom keeps them off another pane.
const NORMAL_MODE = "composer && composer_vim == normal";

// Normal mode maps these strokes to `normalKey`.
const NORMAL_KEYS = [
  "h", "l", "j", "k", "0", "^", "$", "w", "b", "e", "G",
  "i", "a", "I", "A", "o", "O", "x", "s", "D", "C", "p", "P",
  "left", "right", "up", "down", "enter",
];
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
  const v = /** @type {ChatView | null} */ (focusedChatView());
  return v ? v.composer : null;
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

// Place the caret for an insert command; the caller leaves normal mode.
/** @param {ComposerType} c @param {number} caret @returns {"insert"} */
function enter(c, caret) {
  c.input.caret = Math.max(0, Math.min(caret, c.input.text.length));
  return "insert";
}

// `dd` and `cc` take the whole line; the register keeps only its body.
/** @param {ComposerType} c @param {"d" | "c"} op @returns {KeyResult} */
function lineOp(c, op) {
  const t = c.input;
  const { start, end } = lineAt(t.text, t.caret);
  const body = t.text.slice(start, end);
  if (op === "c") return cut(c, start, end, true, body) && enter(c, start);
  if (end < t.text.length) return cut(c, start, end + 1, true, body);
  return cut(c, start > 0 ? start - 1 : 0, end, true, body);
}

/** @param {ComposerType} c @param {string} k @returns {KeyResult} */
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
    // `s` stops at the line end like `x`, so an empty line keeps its line break.
    case "s":
    case "C": {
      const at = t.caret;
      cut(c, at, k === "s" ? Math.min(nextGrapheme(text, at), end) : end, false);
      return enter(c, at);
    }
    case "D":
      return cut(c, t.caret, end, false);
    case "p":
      return put(c, true);
    case "P":
      return put(c, false);
    case "enter":
      c.submit();
      return true;
  }
  return false;
}

export const composerVim = {
  name: "composer-vim",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The block owns the modes, so an unload drops them and every composer types again.
      /** @type {WeakSet<ComposerType>} */
      const normal = new WeakSet();
      /** @param {ComposerType | null} c @returns {ComposerMode | null} */
      const mode = (c) => (c ? (normal.has(c) ? "normal" : "insert") : null);
      /** @param {ComposerType | null} c @param {ComposerMode} next @returns {void} */
      const setMode = (c, next) => {
        if (!c || mode(c) === next) return;
        if (next === "normal") {
          normal.add(c);
          c.input.caret = clamp(c.input.text, c.input.caret);
        } else normal.delete(c);
        events.emit("composer-vim:mode", c, next);
        ctx.tui.invalidate();
      };
      const inChat = () => chatComposer() != null;

      ctx.tui.command(inChat, {
        normal: () => setMode(chatComposer(), "normal"),
        insert: () => setMode(chatComposer(), "insert"),
      });

      ctx.tui.keymap({ esc: "composer-vim:normal" });

      // The plugin exposes the mode as a flag, so each binding gates on it.
      ctx.tui.context({ composer_vim: () => mode(chatComposer()) || "" });

      // Normal mode sends a key to the keymap, so no pane inside the chat reads it.
      ctx.tui.route("keymap", NORMAL_MODE);

      /** @param {(c: ComposerType) => KeyResult} fn @returns {() => boolean} */
      const edit = (fn) => () => {
        const c = chatComposer();
        if (!c) return false;
        const done = fn(c);
        if (done === "insert") setMode(c, "insert");
        return done !== false;
      };
      /** @type {Record<string, () => boolean>} */
      const keys = {};
      for (const k of NORMAL_KEYS) keys[k] = edit((c) => normalKey(c, k));
      ctx.tui.keymap(keys, NORMAL_MODE);
      // `gg` is a chord, while `dd` and `cc` are operators that never expire.
      ctx.tui.keymap({ "g g": edit((c) => to(c, 0)) }, NORMAL_MODE);
      ctx.tui.keymap(
        { "d d": edit((c) => lineOp(c, "d")), "c c": edit((c) => lineOp(c, "c")) },
        NORMAL_MODE,
        { pending: "operator" },
      );

      // A null answer leaves the composer its own glyph.
      ctx.on("composer.prompt", /** @param {ComposerType} c @returns {string | null} */ (c) => (normal.has(c) ? NORMAL_PROMPT : null));

      ctx.tui.keymap(windowKeys("ctrl+w"));

      ctx.tui.status({ side: "right", order: 0, render: () => {
        const m = mode(chatComposer());
        return m ? m.toUpperCase() : "";
      } });

      /** @type {ComposerVim} */
      const service = { mode, setMode };
      ctx.provide("composer-vim", service);

      setMode(chatComposer(), "normal");
    });
  },
};
