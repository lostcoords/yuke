// yuke:transcript-vim — opt-in cursor and yank keys for the transcript.
import { term } from "yuke:term";
import { root, copy, caretAtCol, prevGrapheme, nextGrapheme, nextWordStart, prevWordStart, nextWordEnd } from "yuke:core";
import { ChatView } from "yuke:transcript";
import { register } from "yuke:vim";
import { focusedChatView } from "yuke:chat";

/** @typedef {import("yuke:transcript").ChatView["transcript"]} Transcript */
/** @typedef {{ id: number, row: number, col: number }} Position */
/** @typedef {{ cursor: Position | null, src: number, anchor: Position | null, visual: boolean, goal: number | null }} VimState */
/** @typedef {{ x: number, y: number, visible: boolean }} Cursor */
/** @typedef {Extract<HostEvent, { type: "mouse" }>} HostMouseEvent */
/** @typedef {{ start: number, end: number, soft: boolean }} WrapRow */
/** @typedef {{ kind: string, at: number, end: number }} Block */

// The pane owns the region focus, so every binding sits on the atom the pane reports.
const TRANSCRIPT = "transcript";
const VISUAL = "transcript && transcript_visual == on";
const NOT_VISUAL = "transcript && transcript_visual != on";
const MOTION_KEYS = ["h", "l", "j", "k", "left", "right", "down", "up", "0", "home", "$", "end", "G", "w", "b", "e", "}", "{", "J", "K"];

/** @type {WeakMap<ChatView, VimState>} */
const panes = new WeakMap();

/** @param {ChatView} view @returns {VimState} */
function stateOf(view) {
  let s = panes.get(view);
  if (!s) {
    s = { cursor: null, src: -1, anchor: null, visual: false, goal: null };
    panes.set(view, s);
  }
  return s;
}

/** @param {Transcript} t @param {Position} pos @returns {string} */
function rowOf(t, pos) {
  return t.rowTextAt(pos.id, pos.row);
}

/** @param {Transcript} t @param {VimState} s @returns {void} */
function holdCol(t, s) {
  const cursor = /** @type {Position} */ (s.cursor);
  const body = rowOf(t, cursor);
  if (body.length === 0) return;
  if (cursor.col >= body.length) s.cursor = { ...cursor, col: prevGrapheme(body, body.length) };
}

/** @param {Transcript} t @returns {number[]} */
function idsOf(t) {
  return t.messages().map((m) => m.id);
}

/** @param {Transcript} t @param {VimState} s @returns {void} */
function anchor(t, s) {
  if (s.cursor) s.src = t.sourceAt(s.cursor);
}

/** @param {ChatView} view @param {VimState} s @returns {boolean} */
function place(view, s) {
  const t = view.transcript;
  anchor(t, s);
  root.invalidate();
  return true;
}

/** @param {Transcript} t @param {VimState} s @returns {void} */
function reanchor(t, s) {
  if (!s.cursor || s.src < 0 || t.sourceAt(s.cursor) === s.src) return;
  const pos = t.posAtSource(s.cursor.id, s.src);
  if (pos) s.cursor = pos;
}

/** @param {ChatView} view @param {VimState} s @returns {void} */
function seed(view, s) {
  const t = view.transcript;
  if (s.cursor && t.screenAt(s.cursor)) return;
  const r = t.pager.rect();
  for (let y = r ? r.y + r.h - 1 : -1; r && y >= r.y; y--) {
    const pos = t.posAt(r.x, y, false);
    if (pos && rowOf(t, pos) !== "") {
      s.cursor = pos;
      anchor(t, s);
      return;
    }
  }
  toEnd(t, s, true);
  anchor(t, s);
}

/** @param {Transcript} t @param {Position | null} pos @returns {Cursor | null} */
function cursorOf(t, pos) {
  if (!pos) return null;
  const at = t.screenAt(pos);
  return at ? { x: at.x, y: at.y, visible: true } : { x: 0, y: 0, visible: false };
}

/** @param {Transcript} t @param {VimState} s @param {number} d @returns {boolean} */
function stepCol(t, s, d) {
  const cursor = /** @type {Position} */ (s.cursor);
  const body = rowOf(t, cursor);
  const col = d < 0 ? prevGrapheme(body, cursor.col) : nextGrapheme(body, cursor.col);
  if (col === cursor.col) return false;
  s.cursor = { id: cursor.id, row: cursor.row, col: Math.min(col, body.length) };
  return true;
}

/** @param {Transcript} t @param {VimState} s @param {number} d @returns {boolean} */
function stepRow(t, s, d) {
  const ids = idsOf(t);
  const cursor = /** @type {Position} */ (s.cursor);
  let i = ids.indexOf(cursor.id);
  if (i < 0) return false;

  let r = cursor.row + d;
  let id = /** @type {number} */ (ids[i]);
  while (r < 0 || r >= t.rowCountOf(id)) {
    if (r < 0) {
      if (i === 0) return false;
      i--;
      id = /** @type {number} */ (ids[i]);
      r += t.rowCountOf(id);
    } else {
      if (i === ids.length - 1) return false;
      r -= t.rowCountOf(id);
      i++;
      id = /** @type {number} */ (ids[i]);
    }
  }

  const goal = s.goal == null ? term.measure(rowOf(t, cursor).slice(0, cursor.col)) : s.goal;
  const body = t.rowTextAt(id, r);
  const row = /** @type {WrapRow} */ ({ start: 0, end: body.length });
  s.cursor = { id, row: r, col: caretAtCol(body, row, goal) };
  s.goal = goal;
  return true;
}

/** @param {Transcript} t @param {VimState} s @param {(text: string, at: number) => number} find @param {number} edge @returns {boolean} */
function wordStep(t, s, find, edge) {
  const cursor = /** @type {Position} */ (s.cursor);
  const body = rowOf(t, cursor);
  const col = find(body, cursor.col);
  if (col !== cursor.col) {
    s.cursor = { ...cursor, col };
    return true;
  }
  if (!stepRow(t, s, edge)) return false;
  const next = /** @type {Position} */ (s.cursor);
  s.cursor = { ...next, col: edge > 0 ? 0 : rowOf(t, next).length };
  return true;
}

/** @param {Transcript} t @param {VimState} s @param {number} d @returns {boolean} */
function blockStep(t, s, d) {
  const ids = idsOf(t);
  const cursor = /** @type {Position} */ (s.cursor);
  let i = ids.indexOf(cursor.id);
  if (i < 0) return false;

  let id = /** @type {number} */ (ids[i]);
  let blocks = t.blocksOf(id);
  let here = t.sourceAt(cursor);
  for (let r = cursor.row - 1; here < 0 && r >= 0; r--) here = t.sourceAt({ ...cursor, row: r });
  let k = -1;
  for (let n = 0; n < blocks.length; n++) {
    const block = /** @type {Block} */ (blocks[n]);
    if (here >= block.at) k = n;
  }
  k += d;

  while (k < 0 || k >= blocks.length) {
    i += d;
    if (i < 0 || i >= ids.length) return false;
    id = /** @type {number} */ (ids[i]);
    blocks = t.blocksOf(id);
    k = d > 0 ? 0 : blocks.length - 1;
  }

  const block = /** @type {Block} */ (blocks[k]);
  const pos = t.posAtSource(id, block.at);
  if (!pos) return false;
  s.cursor = pos;
  return true;
}

/** @param {Transcript} t @param {VimState} s @param {boolean} last @returns {boolean} */
function toEnd(t, s, last) {
  const ids = idsOf(t);
  if (ids.length === 0) return false;
  const id = /** @type {number} */ (last ? ids[ids.length - 1] : ids[0]);
  const count = t.rowCountOf(id);
  if (count === 0) return false;
  let r = last ? count - 1 : 0;
  while (last && r > 0 && t.rowTextAt(id, r) === "") r--;
  s.cursor = { id, row: r, col: 0 };
  return true;
}

/** @param {Transcript} t @param {VimState} s @param {string} k @returns {boolean} */
function move(t, s, k) {
  if (!s.cursor) return false;
  switch (k) {
    case "h":
    case "left":
      return stepCol(t, s, -1);
    case "l":
    case "right":
      return stepCol(t, s, 1);
    case "j":
    case "down":
      return stepRow(t, s, 1);
    case "k":
    case "up":
      return stepRow(t, s, -1);
    case "0":
    case "home":
      s.cursor = { ...s.cursor, col: 0 };
      return true;
    case "$":
    case "end":
      s.cursor = { ...s.cursor, col: rowOf(t, s.cursor).length };
      return true;
    case "G":
      return toEnd(t, s, true);
    case "w":
      return wordStep(t, s, nextWordStart, 1);
    case "b":
      return wordStep(t, s, prevWordStart, -1);
    case "e":
      return wordStep(t, s, nextWordEnd, 1);
    case "}":
      return blockStep(t, s, 1);
    case "{":
      return blockStep(t, s, -1);
    case "J": {
      const pos = t.partStep(s.cursor, 1);
      if (!pos) return false;
      s.cursor = pos;
      return true;
    }
    case "K": {
      const pos = t.partStep(s.cursor, -1);
      if (!pos) return false;
      s.cursor = pos;
      return true;
    }
  }
  return false;
}

/** @param {Transcript} t @param {Position} a @param {Position} b @returns {number} */
function cmp(t, a, b) {
  if (a.id !== b.id) {
    const ids = idsOf(t);
    return ids.indexOf(a.id) - ids.indexOf(b.id);
  }
  return a.row !== b.row ? a.row - b.row : a.col - b.col;
}

/** @param {Transcript} t @param {VimState} s @returns {void} */
function expandLines(t, s) {
  if (!s.cursor || !s.anchor) return;
  const after = cmp(t, s.cursor, s.anchor) >= 0;
  const lo = after ? s.anchor : s.cursor;
  const hi = after ? s.cursor : s.anchor;
  t.select({ ...lo, col: 0 }, { ...hi, col: rowOf(t, hi).length });
}

/** @param {Transcript} t @param {VimState} s @param {boolean} source @param {boolean | undefined} [linewise] @returns {void} */
function yank(t, s, source, linewise) {
  if (!s.cursor) return;
  if (!s.visual) {
    const body = rowOf(t, s.cursor);
    t.select({ ...s.cursor, col: 0 }, { ...s.cursor, col: body.length });
  }
  const text = source ? t.selectedSource() : t.selectedText();
  register.set(text, linewise === undefined ? !s.visual : linewise);
  copy(text, source ? "source" : "selection");
  s.visual = false;
  s.anchor = null;
  t.clearSelection();
}

/** @param {Transcript} t @param {VimState} s @returns {void} */
function syncSelection(t, s) {
  if (!s.visual || !s.cursor || !s.anchor) return;
  t.select(s.anchor, s.cursor, { inclusive: true });
}

export const transcriptVim = {
  name: "transcript-vim",
  /** @param {import("yuke:ext").Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // Normal keys reach the keymap only where the transcript holds the region focus.
      ctx.tui.route("keymap", TRANSCRIPT);

      // Visual mode is plugin state, so it rides a flag rather than an atom.
      ctx.tui.context({
        transcript_visual: () => {
          const v = /** @type {ChatView | null} */ (focusedChatView());
          const s = v ? panes.get(v) : undefined;
          return s && s.visual ? "on" : "";
        },
      });

      // A region change ends visual mode, so a return to the transcript starts clean.
      ctx.on("region.focused", /** @param {ChatView} view @param {import("yuke:transcript").ChatRegion} region @returns {void} */ (view, region) => {
        const s = panes.get(view);
        if (!s) return;
        s.visual = false;
        s.anchor = null;
        if (region !== "transcript") view.transcript.clearSelection();
      });

      /** @param {(view: ChatView, s: VimState, t: Transcript) => boolean} fn @returns {() => boolean} */
      const act = (fn) => () => {
        // The binding context already limits this to a focused transcript in the active pane.
        const view = /** @type {ChatView | null} */ (focusedChatView());
        if (!view) return false;
        const s = stateOf(view);
        const t = view.transcript;
        if (!s.cursor) seed(view, s);
        reanchor(t, s);
        return fn(view, s, t);
      };

      // A motion holds the column, syncs a visual selection, and scrolls the cursor into view.
      /** @param {ChatView} view @param {VimState} s @param {Transcript} t @returns {boolean} */
      const settle = (view, s, t) => {
        holdCol(t, s);
        syncSelection(t, s);
        t.ensureVisible(/** @type {Position} */ (s.cursor));
        return place(view, s);
      };

      /** @type {Record<string, () => boolean>} */
      const motions = {};
      for (const k of MOTION_KEYS) {
        motions[k] = act((view, s, t) => {
          // Only a vertical motion keeps the goal column.
          if (k !== "j" && k !== "k" && k !== "up" && k !== "down") s.goal = null;
          if (!move(t, s, k)) return false;
          return settle(view, s, t);
        });
      }
      ctx.tui.keymap(motions, TRANSCRIPT);

      ctx.tui.keymap(
        {
          enter: act((view, s, t) => {
            const hit = t.partAt(/** @type {Position} */ (s.cursor));
            if (hit && (hit.kind === "report-header" || hit.kind === "report-body" || hit.kind === "tool-header" || hit.kind === "tool-body" || hit.kind === "reasoning-header" || hit.kind === "reasoning-body")) {
              t.togglePart(hit.id, hit.partId);
              const header = t.partHeader(hit.id, hit.partId);
              if (header) s.cursor = header;
              t.ensureVisible(/** @type {Position} */ (s.cursor));
            }
            return place(view, s);
          }),
          esc: act((view, s, t) => {
            s.visual = false;
            s.anchor = null;
            t.clearSelection();
            return place(view, s);
          }),
          v: act((view, s, t) => {
            s.visual = !s.visual;
            s.anchor = s.visual ? s.cursor : null;
            if (s.visual) syncSelection(t, s);
            else t.clearSelection();
            return place(view, s);
          }),
          Y: act((view, s, t) => {
            if (s.visual) expandLines(t, s);
            yank(t, s, false, true);
            return place(view, s);
          }),
        },
        TRANSCRIPT,
      );

      // `o` swaps the ends of a selection and `y` copies it, so both need visual mode.
      ctx.tui.keymap(
        {
          o: act((view, s, t) => {
            const swap = s.anchor;
            s.anchor = s.cursor;
            s.cursor = swap;
            syncSelection(t, s);
            t.ensureVisible(/** @type {Position} */ (s.cursor));
            return place(view, s);
          }),
          y: act((view, s, t) => {
            yank(t, s, false, false);
            return place(view, s);
          }),
        },
        VISUAL,
      );

      ctx.tui.keymap(
        {
          "g g": act((view, s, t) => (toEnd(t, s, false) ? settle(view, s, t) : false)),
          "g y": act((view, s, t) => {
            yank(t, s, true);
            return place(view, s);
          }),
        },
        TRANSCRIPT,
      );

      // Outside visual mode `yy` waits like an operator, so a pause never cancels it.
      ctx.tui.keymap(
        {
          "y y": act((view, s, t) => {
            yank(t, s, false);
            return place(view, s);
          }),
        },
        NOT_VISUAL,
        { pending: "operator" },
      );

      // The transcript supplies the caret only while it holds the region.
      ctx.tui.slot(ChatView, "cursor", /** @param {ChatView} view @returns {Cursor | null} */ (view) => {
        if (view.focus !== "transcript") return null;
        const s = stateOf(view);
        if (!s.cursor) seed(view, s);
        reanchor(view.transcript, s);
        return cursorOf(view.transcript, s.cursor);
      });

      // A click is the plugin's own way into the region, so it moves the focus itself.
      ctx.tui.slot(ChatView, "press", /** @param {ChatView} view @param {HostMouseEvent} ev @returns {boolean} */ (view, ev) => {
        const s = stateOf(view);
        const pos = view.transcript.posAt(ev.col, ev.row, false);
        if (!pos) {
          view.focusRegion("composer");
          return false;
        }
        view.focusRegion("transcript");
        s.cursor = pos;
        s.goal = null;
        s.visual = false;
        s.anchor = null;
        return place(view, s);
      });

      return () => {
        const view = /** @type {ChatView | null} */ (focusedChatView());
        if (view) {
          panes.delete(view);
          view.transcript.clearSelection();
          // The region outlives the plugin, so an unload hands the keyboard back to the composer.
          view.focusRegion("composer");
        }
        root.invalidate();
      };
      });
},
};
