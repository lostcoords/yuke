// yuke:transcript-vim — an opt-in layer that gives the transcript a cursor. Tab moves the focus
// between the composer and the transcript, and the motions then move a cursor, not the viewport.
import { term } from "yuke:term";
import { root, command, modalKey, caretAtCol, register, prevGrapheme, nextGrapheme, nextWordStart, prevWordStart, nextWordEnd } from "yuke:core";
import { ChatView, rowText } from "yuke:ui";

// Per-pane state, so a split keeps its own cursor. A pane that goes away drops with the map.
const panes = new WeakMap();

function stateOf(view) {
  let s = panes.get(view);
  if (!s) {
    s = { on: false, cursor: null, anchor: null, visual: false, goal: null, gPending: false, yPending: false };
    panes.set(view, s);
  }
  return s;
}

// The focused chat pane, or null when another view holds the focus.
function chatPane() {
  const v = root.active;
  return v && v.name === "chat" ? v : null;
}

// The rendered text of the cursor's row, or "" when the row is gone.
function rowOf(t, pos) {
  const rows = t.rowsOf(pos.id);
  return pos.row < rows.length ? rowText(rows[pos.row]) : "";
}

// The message ids in transcript order.
function idsOf(t) {
  return t.messages().map((m) => m.id);
}

// Put the cursor back where it was. A stale position takes the lowest drawn row, as tmux does.
// The pane bottom can hold no row, so the scan walks up to the last one that does.
function seed(view, s) {
  const t = view.transcript;
  if (s.cursor && t.screenAt(s.cursor)) return;
  const r = t.pager.rect();
  for (let y = r ? r.y + r.h - 1 : -1; r && y >= r.y; y--) {
    const pos = t.posAt(r.x, y, false);
    if (pos && rowOf(t, pos) !== "") {
      s.cursor = pos;
      return;
    }
  }
  toEnd(t, s, true);
}

// Step one grapheme along the row. A step never leaves the row, as `h` and `l` do in vim.
function stepCol(t, s, d) {
  const body = rowOf(t, s.cursor);
  const col = d < 0 ? prevGrapheme(body, s.cursor.col) : nextGrapheme(body, s.cursor.col);
  if (col === s.cursor.col) return false;
  s.cursor = { id: s.cursor.id, row: s.cursor.row, col: Math.min(col, body.length) };
  return true;
}

// Move `d` rows, crossing into the next message at the edge. The goal column survives a short row.
function stepRow(t, s, d) {
  const ids = idsOf(t);
  let i = ids.indexOf(s.cursor.id);
  if (i < 0) return false;

  let r = s.cursor.row + d;
  while (r < 0 || r >= t.rowsOf(ids[i]).length) {
    if (r < 0) {
      if (i === 0) return false;
      i--;
      r += t.rowsOf(ids[i]).length;
    } else {
      if (i === ids.length - 1) return false;
      r -= t.rowsOf(ids[i]).length;
      i++;
    }
  }

  const goal = s.goal == null ? term.measure(rowOf(t, s.cursor).slice(0, s.cursor.col)) : s.goal;
  const body = rowText(t.rowsOf(ids[i])[r]);
  s.cursor = { id: ids[i], row: r, col: caretAtCol(body, { start: 0, end: body.length }, goal) };
  s.goal = goal;
  return true;
}

// Document order over two positions: message, then row, then column.
function cmp(t, a, b) {
  if (a.id !== b.id) {
    const ids = idsOf(t);
    return ids.indexOf(a.id) - ids.indexOf(b.id);
  }
  return a.row !== b.row ? a.row - b.row : a.col - b.col;
}

// Vim visual holds both ends, but the core selection is half open. Grow the later end by one
// grapheme, so the character under the cursor stays inside.
function syncSelection(t, s) {
  if (!s.visual || !s.cursor || !s.anchor) return;
  const grow = (p) => {
    const body = rowOf(t, p);
    return { id: p.id, row: p.row, col: Math.min(nextGrapheme(body, p.col), body.length) };
  };
  const after = cmp(t, s.cursor, s.anchor) >= 0;
  t.selection = after ? { anchor: s.anchor, cursor: grow(s.cursor) } : { anchor: grow(s.anchor), cursor: s.cursor };
}

// A word motion runs inside the row. The row edge steps to the next row, once.
function wordStep(t, s, find, edge) {
  const body = rowOf(t, s.cursor);
  const col = find(body, s.cursor.col);
  if (col !== s.cursor.col) {
    s.cursor = { ...s.cursor, col };
    return true;
  }
  if (!stepRow(t, s, edge)) return false;
  s.cursor = { ...s.cursor, col: edge > 0 ? 0 : rowOf(t, s.cursor).length };
  return true;
}

// Move to the next or the previous markdown block. The step counts blocks, not offsets, because a
// block starts before the source under the cursor. A turn with no block steps over.
function blockStep(t, s, d) {
  const ids = idsOf(t);
  let i = ids.indexOf(s.cursor.id);
  if (i < 0) return false;

  let blocks = t.blocksOf(ids[i]);
  const here = t.sourceAt(s.cursor);
  let k = -1;
  for (let n = 0; n < blocks.length; n++) if (here >= blocks[n].at) k = n;
  k += d;

  while (k < 0 || k >= blocks.length) {
    i += d;
    if (i < 0 || i >= ids.length) return false;
    blocks = t.blocksOf(ids[i]);
    k = d > 0 ? 0 : blocks.length - 1;
  }

  const pos = t.posAtSource(ids[i], blocks[k].at);
  if (!pos) return false;
  s.cursor = pos;
  return true;
}

// The first or the last position of the transcript.
function toEnd(t, s, last) {
  const ids = idsOf(t);
  if (ids.length === 0) return false;
  const id = last ? ids[ids.length - 1] : ids[0];
  const rows = t.rowsOf(id);
  if (rows.length === 0) return false;
  // A message ends with a blank separator row, so `G` steps back onto the last real text.
  let r = last ? rows.length - 1 : 0;
  while (last && r > 0 && rowText(rows[r]) === "") r--;
  s.cursor = { id, row: r, col: 0 };
  return true;
}

// Apply one motion. Return false to leave the key for the keymap.
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
  }
  return false;
}

// Grow the selection to whole rows, which is what a linewise yank takes.
function expandLines(t, s) {
  const after = cmp(t, s.cursor, s.anchor) >= 0;
  const lo = after ? s.anchor : s.cursor;
  const hi = after ? s.cursor : s.anchor;
  t.selection = { anchor: { ...lo, col: 0 }, cursor: { ...hi, col: rowOf(t, hi).length } };
}

// Copy through the core command, so the mouse and the keyboard take one path to the clipboard.
// Without a selection the row under the cursor is the target, which is what `yy` means.
function yank(t, s, name, linewise) {
  if (!s.visual) {
    const body = rowOf(t, s.cursor);
    t.selection = { anchor: { ...s.cursor, col: 0 }, cursor: { ...s.cursor, col: body.length } };
  }
  register.set(name === "copy:source" ? t.selectedSource() : t.selectedText(), linewise !== false && !s.visual);
  command.perform(name);
  s.visual = false;
  s.anchor = null;
  t.clearSelection();
}

export const transcriptVim = {
  name: "transcript-vim",
  apply(ctx) {
    // Tab moves the focus into the transcript and back. It is the only way out, so a motion key
    // never types into the composer.
    const toggle = () => {
      const v = chatPane();
      if (!v) return;
      const s = stateOf(v);
      s.on = !s.on;
      if (s.on) seed(v, s);
      root.invalidate();
    };

    ctx.command(() => chatPane() != null, { focus: toggle });
    ctx.keymap({ tab: "transcript-vim:focus" });

    // The transcript owns every key while it holds the focus, so the composer takes none of them.
    // An unhandled key still reaches the keymap, which keeps ctrl+p and the window chords alive.
    ctx.advise(ChatView.prototype, "onKey", "around", function (inner, ev) {
      const s = panes.get(this);
      if (!s || !s.on) return inner(ev);

      const t = this.transcript;
      const k = modalKey(ev);
      // "g" opens a two-key motion: "gg" to the top, "gy" to copy the markdown source.
      if (s.gPending) {
        s.gPending = false;
        if (k === "g" && toEnd(t, s, false)) {
          syncSelection(t, s);
          t.ensureVisible(s.cursor);
          root.invalidate();
          return true;
        }
        if (k === "y") {
          yank(t, s, "copy:source");
          root.invalidate();
          return true;
        }
        if (k === "g") return true;
      }
      // "y" waits for a second "y", the way vim waits for a motion.
      if (s.yPending) {
        s.yPending = false;
        if (k === "y") {
          yank(t, s, "copy:selection");
          root.invalidate();
        }
        return true;
      }
      if (k === "g") {
        s.gPending = true;
        return true;
      }

      if (k === "esc") {
        s.visual = false;
        s.anchor = null;
        t.clearSelection();
        root.invalidate();
        return true;
      }
      if (k === "v") {
        s.visual = !s.visual;
        s.anchor = s.visual ? s.cursor : null;
        if (s.visual) syncSelection(t, s);
        else t.clearSelection();
        root.invalidate();
        return true;
      }
      // "o" puts the cursor on the other end, so a selection can grow from either side.
      if (k === "o" && s.visual) {
        const swap = s.anchor;
        s.anchor = s.cursor;
        s.cursor = swap;
        syncSelection(t, s);
        t.ensureVisible(s.cursor);
        root.invalidate();
        return true;
      }
      // "Y" takes whole rows, as vim's visual Y does.
      if (k === "Y") {
        if (s.visual) expandLines(t, s);
        yank(t, s, "copy:selection", true);
        root.invalidate();
        return true;
      }
      if (k === "y") {
        if (s.visual) yank(t, s, "copy:selection", false);
        else s.yPending = true;
        root.invalidate();
        return true;
      }

      if (k !== "j" && k !== "k" && k !== "up" && k !== "down") s.goal = null;
      if (!move(t, s, k)) return false;
      syncSelection(t, s);
      t.ensureVisible(s.cursor);
      root.invalidate();
      return true;
    });

    // The caret shows where the cursor is. A cursor scrolled off the pane hides it.
    ctx.advise(ChatView.prototype, "cursor", "around", function (inner) {
      const s = panes.get(this);
      if (!s || !s.on) return inner();
      const at = s.cursor && this.transcript.screenAt(s.cursor);
      return at ? { x: at.x, y: at.y, visible: true } : { x: 0, y: 0, visible: false };
    });

    // A press inside the transcript takes the focus and places the cursor, so the mouse and the
    // keyboard agree on one position.
    ctx.advise(ChatView.prototype, "onMouse", "around", function (inner, ev) {
      const taken = inner(ev);
      if (ev.event !== "press" || ev.button !== "left") return taken;
      const pos = this.transcript.posAt(ev.col, ev.row, false);
      if (!pos) return taken;
      const s = stateOf(this);
      s.on = true;
      s.cursor = pos;
      s.goal = null;
      return true;
    });

    // A pane keeps its cursor, but the focus must not survive an unload.
    return () => {
      const v = chatPane();
      if (v && panes.has(v)) panes.get(v).on = false;
      root.invalidate();
    };
  },
};
