// yuke:transcript-vim — opt-in cursor and yank keys for the transcript.
import { term } from "yuke:term";
import { root, copy, modalKey, caretAtCol, takePrefix, armPrefix, prevGrapheme, nextGrapheme, nextWordStart, prevWordStart, nextWordEnd } from "yuke:core";
import { ChatView } from "yuke:ui";
import { register, chatView } from "yuke:vim";

/** @typedef {import("yuke:ui").ChatView["transcript"]} Transcript */
/** @typedef {{ id: number, row: number, col: number }} Position */
/** @typedef {{ on: boolean, cursor: Position | null, src: number, anchor: Position | null, visual: boolean, goal: number | null, pending: string }} VimState */
/** @typedef {{ x: number, y: number, visible: boolean }} Cursor */
/** @typedef {Extract<HostEvent, { type: "key" }>} HostKeyEvent */
/** @typedef {Extract<HostEvent, { type: "mouse" }>} HostMouseEvent */
/** @typedef {{ start: number, end: number, soft: boolean }} WrapRow */
/** @typedef {{ kind: string, at: number, end: number }} Block */
/** @typedef {{ command: (predicate: () => boolean, map: Record<string, () => void>) => unknown, keymap: (bindings: Record<string, string>) => unknown, advise: (obj: object, prop: string, where: string, fn: (...args: never[]) => unknown) => unknown }} PluginContext */

/** @type {WeakMap<ChatView, VimState>} */
const panes = new WeakMap();

/** @param {ChatView} view @returns {VimState} */
function stateOf(view) {
  let s = panes.get(view);
  if (!s) {
    s = { on: false, cursor: null, src: -1, anchor: null, visual: false, goal: null, pending: "" };
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
  /** @param {PluginContext} ctx */
  apply(ctx) {
    const toggle = () => {
      const v = /** @type {ChatView | null} */ (chatView());
      if (!v) return;
      const s = stateOf(v);
      s.on = !s.on;
      s.pending = "";
      if (s.on) seed(v, s);
      root.invalidate();
    };

    ctx.command(() => chatView() != null, { focus: toggle });
    ctx.keymap({ tab: "transcript-vim:focus" });

    ctx.advise(ChatView.prototype, "onFocus", "before", /** @this {ChatView} @returns {void} */ function () {
      const s = panes.get(this);
      if (!s) return;
      s.on = false;
      s.pending = "";
      s.visual = false;
      s.anchor = null;
      this.transcript.clearSelection();
    });

    ctx.advise(ChatView.prototype, "onKey", "around", /** @this {ChatView} @param {(ev: HostEvent) => boolean} inner @param {HostKeyEvent} ev @returns {boolean} */ function (inner, ev) {
      const s = panes.get(this);
      if (!s || !s.on) return inner(ev);

      const t = this.transcript;
      if (!s.cursor) seed(this, s);
      const active = /** @type {{ cursor: Position }} */ (s);
      reanchor(t, s);
      const k = modalKey(ev);
      const first = takePrefix(s);
      if (first === "g") {
        if (k === "g" && toEnd(t, s, false)) {
          holdCol(t, s);
          syncSelection(t, s);
          t.ensureVisible(active.cursor);
          return place(this, s);
        }
        if (k === "y") {
          yank(t, s, true);
          return place(this, s);
        }
      }
      if (first === "y") {
        if (k === "y") yank(t, s, false);
        return place(this, s);
      }
      if (k === "g") {
        armPrefix(s, "g");
        return place(this, s);
      }

      if (k === "enter") {
        const hit = t.partAt(s.cursor);
        if (hit && (hit.kind === "tool-header" || hit.kind === "tool-body" || hit.kind === "reasoning-header" || hit.kind === "reasoning-body")) {
          t.togglePart(hit.id, hit.partId);
          const header = t.partHeader(hit.id, hit.partId);
          if (header) s.cursor = header;
          t.ensureVisible(active.cursor);
        }
        return place(this, s);
      }
      if (k === "esc") {
        s.visual = false;
        s.anchor = null;
        t.clearSelection();
        return place(this, s);
      }
      if (k === "v") {
        s.visual = !s.visual;
        s.anchor = s.visual ? s.cursor : null;
        if (s.visual) syncSelection(t, s);
        else t.clearSelection();
        return place(this, s);
      }
      if (k === "o" && s.visual) {
        const swap = s.anchor;
        s.anchor = s.cursor;
        s.cursor = swap;
        syncSelection(t, s);
        t.ensureVisible(active.cursor);
        return place(this, s);
      }
      if (k === "Y") {
        if (s.visual) expandLines(t, s);
        yank(t, s, false, true);
        return place(this, s);
      }
      if (k === "y") {
        if (s.visual) yank(t, s, false, false);
        else armPrefix(s, "y");
        return place(this, s);
      }

      if (k !== "j" && k !== "k" && k !== "up" && k !== "down") s.goal = null;
      if (!move(t, s, k)) return false;
      holdCol(t, s);
      syncSelection(t, s);
      t.ensureVisible(active.cursor);
      return place(this, s);
    });

    ctx.advise(ChatView.prototype, "cursor", "around", /** @this {ChatView} @param {() => Cursor | null} inner @returns {Cursor | null} */ function (inner) {
      const s = panes.get(this);
      if (!s || !s.on) return inner();
      if (!s.cursor) seed(this, s);
      reanchor(this.transcript, s);
      return cursorOf(this.transcript, s.cursor) || inner();
    });

    ctx.advise(ChatView.prototype, "onMouse", "around", /** @this {ChatView} @param {(ev: HostEvent) => boolean} inner @param {HostMouseEvent} ev @returns {boolean} */ function (inner, ev) {
      const taken = inner(ev);
      if (ev.event !== "press" || ev.button !== "left") return taken;
      const s = stateOf(this);
      const pos = this.transcript.posAt(ev.col, ev.row, false);
      if (!pos) {
        s.on = false;
        s.visual = false;
        s.anchor = null;
        s.pending = "";
        return taken;
      }
      s.on = true;
      s.cursor = pos;
      s.goal = null;
      s.visual = false;
      s.anchor = null;
      s.pending = "";
      return place(this, s);
    });

    return () => {
      const view = /** @type {ChatView | null} */ (chatView());
      if (view) {
        panes.delete(view);
        view.transcript.clearSelection();
      }
      root.invalidate();
    };
  },
};
