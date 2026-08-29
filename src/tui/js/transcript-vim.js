// yuke:transcript-vim — opt-in cursor and yank keys for the transcript.
import { term } from "yuke:term";
import { root, copy, modalKey, caretAtCol, takePrefix, armPrefix, prevGrapheme, nextGrapheme, nextWordStart, prevWordStart, nextWordEnd } from "yuke:core";
import { ChatView } from "yuke:ui";
import { register, chatView } from "yuke:vim";

const panes = new WeakMap();

function stateOf(view) {
  let s = panes.get(view);
  if (!s) {
    s = { on: false, cursor: null, src: -1, anchor: null, visual: false, goal: null, pending: "" };
    panes.set(view, s);
  }
  return s;
}

function rowOf(t, pos) {
  return t.rowTextAt(pos.id, pos.row);
}

function holdCol(t, s) {
  const body = rowOf(t, s.cursor);
  if (body.length === 0) return;
  if (s.cursor.col >= body.length) s.cursor = { ...s.cursor, col: prevGrapheme(body, body.length) };
}

function idsOf(t) {
  return t.messages().map((m) => m.id);
}

function anchor(t, s) {
  if (s.cursor) s.src = t.sourceAt(s.cursor);
}

function place(view, s) {
  const t = view.transcript;
  t.caret = s.cursor;
  view.focus = s.on ? "transcript" : "composer";
  anchor(t, s);
  root.invalidate();
  return true;
}

function reanchor(t, s) {
  if (!s.cursor || s.src < 0 || t.sourceAt(s.cursor) === s.src) return;
  const pos = t.posAtSource(s.cursor.id, s.src);
  if (pos) s.cursor = pos;
}

function seed(view, s) {
  const t = view.transcript;
  if (s.cursor && t.screenAt(s.cursor)) {
    t.caret = s.cursor;
    return;
  }
  const r = t.pager.rect();
  for (let y = r ? r.y + r.h - 1 : -1; r && y >= r.y; y--) {
    const pos = t.posAt(r.x, y, false);
    if (pos && rowOf(t, pos) !== "") {
      s.cursor = pos;
      t.caret = pos;
      anchor(t, s);
      return;
    }
  }
  toEnd(t, s, true);
  t.caret = s.cursor;
  anchor(t, s);
}

function stepCol(t, s, d) {
  const body = rowOf(t, s.cursor);
  const col = d < 0 ? prevGrapheme(body, s.cursor.col) : nextGrapheme(body, s.cursor.col);
  if (col === s.cursor.col) return false;
  s.cursor = { id: s.cursor.id, row: s.cursor.row, col: Math.min(col, body.length) };
  return true;
}

function stepRow(t, s, d) {
  const ids = idsOf(t);
  let i = ids.indexOf(s.cursor.id);
  if (i < 0) return false;

  let r = s.cursor.row + d;
  while (r < 0 || r >= t.rowCountOf(ids[i])) {
    if (r < 0) {
      if (i === 0) return false;
      i--;
      r += t.rowCountOf(ids[i]);
    } else {
      if (i === ids.length - 1) return false;
      r -= t.rowCountOf(ids[i]);
      i++;
    }
  }

  const goal = s.goal == null ? term.measure(rowOf(t, s.cursor).slice(0, s.cursor.col)) : s.goal;
  const body = t.rowTextAt(ids[i], r);
  s.cursor = { id: ids[i], row: r, col: caretAtCol(body, { start: 0, end: body.length }, goal) };
  s.goal = goal;
  return true;
}

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

function blockStep(t, s, d) {
  const ids = idsOf(t);
  let i = ids.indexOf(s.cursor.id);
  if (i < 0) return false;

  let blocks = t.blocksOf(ids[i]);
  let here = t.sourceAt(s.cursor);
  for (let r = s.cursor.row - 1; here < 0 && r >= 0; r--) here = t.sourceAt({ ...s.cursor, row: r });
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

function toEnd(t, s, last) {
  const ids = idsOf(t);
  if (ids.length === 0) return false;
  const id = last ? ids[ids.length - 1] : ids[0];
  const count = t.rowCountOf(id);
  if (count === 0) return false;
  let r = last ? count - 1 : 0;
  while (last && r > 0 && t.rowTextAt(id, r) === "") r--;
  s.cursor = { id, row: r, col: 0 };
  return true;
}

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

function cmp(t, a, b) {
  if (a.id !== b.id) {
    const ids = idsOf(t);
    return ids.indexOf(a.id) - ids.indexOf(b.id);
  }
  return a.row !== b.row ? a.row - b.row : a.col - b.col;
}

function expandLines(t, s) {
  if (!s.cursor || !s.anchor) return;
  const after = cmp(t, s.cursor, s.anchor) >= 0;
  const lo = after ? s.anchor : s.cursor;
  const hi = after ? s.cursor : s.anchor;
  t.select({ ...lo, col: 0 }, { ...hi, col: rowOf(t, hi).length });
}

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

function syncSelection(t, s) {
  if (!s.visual || !s.cursor || !s.anchor) return;
  t.select(s.anchor, s.cursor, { inclusive: true });
}

export const transcriptVim = {
  name: "transcript-vim",
  apply(ctx) {
    const toggle = () => {
      const v = chatView();
      if (!v) return;
      const s = stateOf(v);
      s.on = !s.on;
      s.pending = "";
      if (s.on) seed(v, s);
      else v.transcript.caret = null;
      v.focus = s.on ? "transcript" : "composer";
      root.invalidate();
    };

    ctx.command(() => chatView() != null, { focus: toggle });
    ctx.keymap({ tab: "transcript-vim:focus" });

    ctx.advise(ChatView.prototype, "onKey", "around", function (inner, ev) {
      const s = panes.get(this);
      if (!s || !s.on) return inner(ev);

      const t = this.transcript;
      if (!s.cursor) seed(this, s);
      reanchor(t, s);
      const k = modalKey(ev);
      const first = takePrefix(s);
      if (first === "g") {
        if (k === "g" && toEnd(t, s, false)) {
          holdCol(t, s);
          syncSelection(t, s);
          t.ensureVisible(s.cursor);
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
        t.ensureVisible(s.cursor);
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
      t.ensureVisible(s.cursor);
      return place(this, s);
    });

    ctx.advise(ChatView.prototype, "cursor", "around", function (inner) {
      const s = panes.get(this);
      if (!s || !s.on) return inner();
      if (!s.cursor) seed(this, s);
      reanchor(this.transcript, s);
      this.transcript.caret = s.cursor;
      return inner();
    });

    ctx.advise(ChatView.prototype, "onMouse", "around", function (inner, ev) {
      const taken = inner(ev);
      if (ev.event !== "press" || ev.button !== "left") return taken;
      const s = stateOf(this);
      const pos = this.transcript.posAt(ev.col, ev.row, false);
      if (!pos) {
        s.visual = false;
        s.anchor = null;
        return taken;
      }
      s.on = true;
      s.cursor = pos;
      s.goal = null;
      s.visual = false;
      s.anchor = null;
      s.pending = "";
      this.transcript.clearSelection();
      return place(this, s);
    });

    return () => {
      const view = chatView();
      if (view) {
        panes.delete(view);
        view.focus = "composer";
        view.transcript.caret = null;
        view.transcript.clearSelection();
      }
      root.invalidate();
    };
  },
};
