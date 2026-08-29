// yuke:ui — the widget kit over yuke:core. List/Pager/Window are classes to subclass or patch.
// `ui` exports the pickers. Editor policy lives in yuke:core; presentation lives here.
import { term } from "yuke:term";
import { text, fill, clip, wrap, root, strokeOf, TextInput, caretCol, caretAtCol, caretRowCol, wrapOffsets, style, config, isWheel } from "yuke:core";
import { Document, isLinear } from "yuke:md";

// The kit adds its highlight groups to the core palette. It adds only a group that is absent, so a
// theme that set one first keeps it, and a second import does not re-seed.
const UI_GROUPS = {
  // A panel fills with spaces over the terminal background, so it is opaque behind its border.
  UIPanel: { fg: "fg", bg: "bg" },
  UIBorder: { fg: "fg", dim: true },
  UITitle: { fg: "fg", bold: true },
  UIItem: { fg: "fg" },
  UIItemSel: { reverse: true },
  UIPrompt: { fg: "fg", bold: true },
  UIQuery: { fg: "fg" },
  UIComposer: { fg: "fg" },
  UIDim: { fg: "fg", dim: true },
  UIDimSel: { reverse: true },
  // A user turn gets a full-width inverted band; the assistant text is plain. The marker is a gutter cue.
  TxText: { fg: "fg" },
  TxUser: { reverse: true },
  TxUserMarker: { reverse: true, bold: true },
  // A failed turn shows its error in the danger color.
  TxError: { fg: "danger", bold: true },
  TxSelect: { reverse: true },
};
let seededGroups = false;
for (const name in UI_GROUPS) {
  if (!(name in style.groups)) {
    style.groups[name] = UI_GROUPS[name];
    seededGroups = true;
  }
}
if (seededGroups) style.invalidate();

// Default page jump before a draw sets the real page height.
const PAGE_FALLBACK = 10;

// Left gutter for a transcript row marker; the body indents past it.
const TX_GUTTER = 2;

// Shift bit in the host modifier mask.
const MOD_SHIFT = 1;

// The base letter of a shifted char event, or "". It recovers G from g after strokeOf folds the case.
function shiftedChar(ev) {
  if (ev.code !== "char" || !ev.char) return "";
  if (ev.char !== ev.char.toLowerCase()) return ev.char.toLowerCase();
  if ((ev.mods | 0) & MOD_SHIFT) return ev.char.toLowerCase();
  return "";
}

// The shared nav vocabulary: j/k move, ctrl+d/u page, gg/G top/bottom.
// Return "pending_g" when a first g was swallowed; `gPending` is the caller's memory of it.
function navAction(ev, gPending) {
  const s = strokeOf(ev);
  const sc = shiftedChar(ev);
  if (gPending && s === "g" && !sc) return "top";

  switch (s) {
    case "j":
    case "down":
      return "down";
    case "k":
    case "up":
      return "up";
    case "ctrl+d":
    case "page_down":
      return "page_down";
    case "ctrl+u":
    case "page_up":
      return "page_up";
    case "home":
      return "top";
    case "end":
      return "bottom";
    case "g":
      return sc === "g" ? "bottom" : "pending_g";
  }
  return "";
}

// A scrollable, selectable list. `key(item)` gives a stable identity, so the selection follows its
// item across a re-sorted `items`. `itemHeight` rows render per item; `format` may return `lines`.
export class List {
  constructor(opts = {}) {
    this.format = opts.format || ((it) => ({ text: String(it) }));
    this.key = opts.key || ((it) => it);
    this.isSelectable = opts.isSelectable || (() => true);
    this.onMove = opts.onMove || null;
    this.itemHeight = Math.max(1, opts.itemHeight || 1);

    this.group = opts.group || "UIItem";
    this.selGroup = opts.selGroup || "UIItemSel";
    this.dimGroup = opts.dimGroup || "UIDim";
    this.dimSelGroup = opts.dimSelGroup || "UIDimSel";

    this.drawCursor = opts.drawCursor !== false; // an unfocused list can hide its cursor
    this._rect = null; // the last drawn rect, for the click hit test
    this.selectedKey = null;
    this.scroll = 0; // first visible item index
    this._page = PAGE_FALLBACK; // last visible item count, for page moves
    this._gPending = false;
    this.setItems(opts.items || []);
  }

  // Visible item count for a pixel height.
  _visible(h) {
    return Math.max(1, Math.floor(h / this.itemHeight));
  }

  setItems(items) {
    this.items = items || [];
    this._ensureSelection();
    this._clampScroll(this._page);
  }

  _selectable() {
    const out = [];
    for (let i = 0; i < this.items.length; i++) if (this.isSelectable(this.items[i])) out.push(i);
    return out;
  }

  _selIndex() {
    if (this.selectedKey == null) return -1;
    for (let i = 0; i < this.items.length; i++) {
      if (this.isSelectable(this.items[i]) && this.key(this.items[i]) === this.selectedKey) return i;
    }
    return -1;
  }

  _ensureSelection() {
    if (this._selIndex() >= 0) return;
    const sel = this._selectable();
    this.selectedKey = sel.length ? this.key(this.items[sel[0]]) : null;
  }

  selected() {
    const i = this._selIndex();
    return i < 0 ? null : this.items[i];
  }

  selectedIndex() {
    return this._selIndex();
  }

  ensureVisible(h) {
    const vis = this._visible(h);
    this._page = vis;
    this._scrollToVisible(vis);
  }

  move(delta) {
    const sel = this._selectable();
    if (sel.length === 0) return;
    let pos = sel.indexOf(this._selIndex());
    pos = pos < 0 ? 0 : Math.min(Math.max(pos + delta, 0), sel.length - 1);
    this.selectedKey = this.key(this.items[sel[pos]]);
    if (this.onMove) this.onMove(this.items[sel[pos]], sel[pos]);
  }

  moveToEdge(dir) {
    this.move(dir < 0 ? -this.items.length : this.items.length);
  }

  _scrollToVisible(vis) {
    const i = this._selIndex();
    if (i >= 0 && vis > 0) {
      if (i < this.scroll) this.scroll = i;
      else if (i >= this.scroll + vis) this.scroll = i - vis + 1;
    }
    this._clampScroll(vis);
  }

  _clampScroll(vis) {
    const max = Math.max(0, this.items.length - Math.max(1, vis));
    this.scroll = Math.min(Math.max(this.scroll, 0), max);
  }

  onKey(ev) {
    const act = navAction(ev, this._gPending);
    this._gPending = act === "pending_g";
    switch (act) {
      case "down":
        this.move(1);
        return true;
      case "up":
        this.move(-1);
        return true;
      case "page_down":
        this.move(this._page);
        return true;
      case "page_up":
        this.move(-this._page);
        return true;
      case "top":
        this.moveToEdge(-1);
        return true;
      case "bottom":
        this.moveToEdge(1);
        return true;
      case "pending_g":
        return true;
    }
    return false;
  }

  // Forget the drawn rect. A container calls this when it draws something else in the same space,
  // so a click cannot hit a row that left the screen.
  clearRect() {
    this._rect = null;
  }

  // A wheel step moves the cursor, because `draw` always scrolls the selection back into view.
  // A left press selects the row under the pointer.
  onMouse(ev) {
    const r = this._rect;
    if (!r || ev.event !== "press") return false;
    if (isWheel(ev.button)) {
      // `scrollLines` counts screen lines, so a tall row moves fewer items per step.
      const step = Math.max(1, Math.round(config.mouse.scrollLines / this.itemHeight));
      const n = step * (ev.count || 1);
      if (ev.button === "wheel_up") this.move(-n);
      else if (ev.button === "wheel_down") this.move(n);
      else return false;
      return true;
    }
    if (ev.button !== "left") return false;
    if (ev.col < r.x || ev.col >= r.x + r.w || ev.row < r.y || ev.row >= r.y + r.h) return false;
    // `draw` paints `_visible(h)` rows, so a short pane leaves the last row of the rect empty.
    const off = Math.floor((ev.row - r.y) / this.itemHeight);
    if (off >= this._visible(r.h)) return false;
    const i = this.scroll + off;
    if (i < 0 || i >= this.items.length || !this.isSelectable(this.items[i])) return false;
    this.selectedKey = this.key(this.items[i]);
    if (this.onMove) this.onMove(this.items[i], i);
    return true;
  }

  // Paint into rect { x, y, w, h }. A selected item fills all its rows; each item draws up to
  // `itemHeight` lines. Every row repaints each frame, so `format` may be dynamic.
  draw(rect) {
    const { x, y, w, h } = rect;
    if (w <= 0 || h <= 0) return this.clearRect();
    this._rect = rect;
    const vis = this._visible(h);
    this._page = vis;
    this._scrollToVisible(vis);

    for (let row = 0; row < vis; row++) {
      const i = this.scroll + row;
      if (i >= this.items.length) break;

      const it = this.items[i];
      const sy = y + row * this.itemHeight;
      // Clamp to the rect so a tall item in a short pane does not paint past it.
      const drawH = Math.min(this.itemHeight, y + h - sy);
      if (drawH <= 0) break;
      const isSel = this.drawCursor && this.isSelectable(it) && this.key(it) === this.selectedKey;
      const cell = normalizeCell(this.format(it, i));

      if (isSel) fill(x, sy, w, drawH, this.selGroup);

      const lines = cell.lines || [cell];
      for (let ln = 0; ln < drawH && ln < lines.length; ln++) {
        this._drawLine(x, sy + ln, w, lines[ln], isSel);
      }
    }
  }

  _drawLine(x, sy, w, spec, isSel) {
    spec = normalizeCell(spec);
    let avail = w;
    if (spec.right) {
      const r = clip(spec.right, w);
      const rw = term.measure(r);
      if (rw > 0 && rw + 1 < w) {
        const rg = isSel ? spec.rightSelGroup || this.dimSelGroup : spec.rightGroup || this.dimGroup;
        text(x + w - rw, sy, r, rg);
        avail = w - rw - 1;
      }
    }
    if (spec.marker) {
      const mg = isSel ? spec.markerSelGroup || spec.markerGroup : spec.markerGroup;
      text(x, sy, spec.marker, mg);
    }
    const ind = spec.indent || 0;
    const g = isSel ? spec.selGroup || this.selGroup : spec.group || this.group;
    text(x + ind, sy, clip(spec.text, Math.max(0, avail - ind)), g);
  }
}

// A row from `format` may be a bare string or a record; fold both into one shape.
function normalizeCell(cell) {
  if (cell == null) return { text: "" };
  if (typeof cell === "string") return { text: cell };
  return { text: cell.text != null ? String(cell.text) : "", ...cell };
}

// A vertical pager over a row source — { rowCount(width), rows(width, top, height) } — so the source
// can virtualize. `stuck` follows the tail. A row is { text | segments, bg, marker, indent, … }.
export class Pager {
  constructor() {
    this.source = staticRowSource([]);
    this.scroll = 0;
    this.stuck = true;
    this._h = 0;
    this._w = 0;
    this._rect = null; // the last drawn rect, for the mouse hit test
    this._gPending = false;
  }

  rect() {
    return this._rect;
  }

  clearRect() {
    this._rect = null;
  }

  // The source row index under screen row `y`. Return -1 outside the drawn rows.
  rowAtY(y) {
    const r = this._rect;
    if (!r || y < r.y || y >= r.y + r.h) return -1;
    const i = this.scroll + (y - r.y);
    return i < this._total() ? i : -1;
  }

  _total() {
    return this.source.rowCount(this._w);
  }

  _maxScroll() {
    return Math.max(0, this._total() - this._h);
  }

  atBottom() {
    return this.scroll >= this._maxScroll();
  }

  toBottom() {
    this.scroll = this._maxScroll();
    this.stuck = true;
  }

  toTop() {
    this.scroll = 0;
    this.stuck = false;
  }

  scrollBy(delta) {
    this.scroll = Math.min(Math.max(0, this.scroll + delta), this._maxScroll());
    this.stuck = this.atBottom();
  }

  // Scroll the least amount that puts row `index` on the screen.
  scrollIntoView(index) {
    if (index < 0 || this._h <= 0) return;
    let next = this.scroll;
    if (index < next) next = index;
    else if (index >= next + this._h) next = index - this._h + 1;
    if (next === this.scroll) return;
    this.scroll = Math.min(Math.max(0, next), this._maxScroll());
    this.stuck = this.atBottom();
  }

  setSource(source) {
    this.source = source || staticRowSource([]);
  }

  setRows(rows) {
    this.setSource(staticRowSource(rows));
    this._clamp();
  }

  // Keep the scroll offset in range as the row count changes. A scroll to the tail re-sticks.
  _clamp() {
    this.scroll = Math.min(Math.max(0, this.scroll), this._maxScroll());
    if (this.stuck) this.scroll = this._maxScroll();
    else if (this.atBottom()) this.stuck = true;
  }

  draw(rect) {
    const { x, y, w, h } = rect;
    this._h = h;
    this._w = w;
    this._rect = rect;
    this._clamp();

    const rows = this.source.rows(w, this.scroll, h);
    for (let row = 0; row < h && row < rows.length; row++) {
      const r = rows[row];
      if (!r) break;
      const sy = y + row;
      if (r.bg) fill(x, sy, w, 1, r.bg);
      if (r.marker) text(x, sy, r.marker, r.markerGroup);
      const ind = r.indent || 0;
      let segs = rowSegments(r);
      if (segs && r.sel) segs = markSelection(segs, r.sel.from, r.sel.to, r.selGroup || "TxSelect");
      if (segs) drawSegments(x + ind, sy, Math.max(0, w - ind), segs);
    }
  }

  onKey(ev) {
    const page = Math.max(1, this._h - 1);
    const act = navAction(ev, this._gPending);
    this._gPending = act === "pending_g";
    switch (act) {
      case "down":
        this.scrollBy(1);
        return true;
      case "up":
        this.scrollBy(-1);
        return true;
      case "page_down":
        this.scrollBy(page);
        return true;
      case "page_up":
        this.scrollBy(-page);
        return true;
      case "top":
        this.toTop();
        return true;
      case "bottom":
        this.toBottom();
        return true;
      case "pending_g":
        return true;
    }
    return false;
  }

  // The wheel scrolls by `config.mouse.scrollLines`. The protocol has no pixel wheel, so the step
  // is a line count. `ev.count` holds the steps the owner folded into this event.
  onMouse(ev) {
    if (!isWheel(ev.button) || ev.event !== "press") return false;
    const n = config.mouse.scrollLines * (ev.count || 1);
    if (ev.button === "wheel_up") this.scrollBy(-n);
    else if (ev.button === "wheel_down") this.scrollBy(n);
    else return false;
    return true;
  }
}

// A row holds either `segments` or a plain `text`. Fold both into one segment list.
function rowSegments(r) {
  if (r.segments) return r.segments;
  return r.text ? [{ text: r.text, group: r.group }] : null;
}

// The plain text of a row, without the indent. A selection indexes into this string.
export function rowText(r) {
  if (r.segments) {
    let out = "";
    for (const seg of r.segments) out += seg.text;
    return out;
  }
  return r.text || "";
}

// The source span under the rendered range [from, to) of a row. A segment with no source, such as
// a wrapped list indent, adds nothing. Return null when the range maps to no source at all.
function rowSourceSpan(row, from, to) {
  const segments = row.segments;
  if (!segments) return null;
  let at = 0;
  let lo = -1;
  let hi = -1;
  for (const seg of segments) {
    const end = at + seg.text.length;
    const a = Math.max(from, at);
    const b = Math.min(to, end);
    if (b > a && seg.src != null) {
      const linear = isLinear(seg);
      const s = linear ? seg.src + (a - at) : seg.src;
      const e = linear ? seg.src + (b - at) : seg.srcEnd;
      if (lo < 0 || s < lo) lo = s;
      if (e > hi) hi = e;
    }
    at = end;
  }
  return lo < 0 ? null : { from: lo, to: hi };
}

// The source offset at caret column `col`. A column in a gap, such as a wrap space, takes the end
// of the source before it. Return -1 when the row carries no source at all.
function rowSourceAt(row, col) {
  const segments = row.segments;
  if (!segments) return -1;
  let at = 0;
  let last = -1;
  for (const seg of segments) {
    const end = at + seg.text.length;
    if (seg.src != null) {
      if (col < at) return last < 0 ? seg.src : last;
      if (col < end) return isLinear(seg) ? seg.src + (col - at) : seg.src;
      last = seg.srcEnd;
    }
    at = end;
  }
  return last;
}

// Repaint the string range [from, to) of `segments` with `group`. The bounds come from
// `caretAtCol`, so they always land on a grapheme edge.
function markSelection(segments, from, to, group) {
  if (to <= from) return segments;
  const out = [];
  let at = 0;
  for (const seg of segments) {
    const end = at + seg.text.length;
    const a = Math.max(from, at);
    const b = Math.min(to, end);
    if (b <= a) {
      out.push(seg);
    } else {
      if (a > at) out.push({ ...seg, text: seg.text.slice(0, a - at) });
      out.push({ ...seg, text: seg.text.slice(a - at, b - at), group });
      if (b < end) out.push({ ...seg, text: seg.text.slice(b - at) });
    }
    at = end;
  }
  return out;
}

// Draw styled segments left to right. The row clips as one string, so a split run never repeats
// the ellipsis and a selection does not move where the row cuts.
function drawSegments(x, sy, w, segments) {
  if (w <= 0) return;
  let total = 0;
  for (const seg of segments) total += term.measure(seg.text);

  let cx = x;
  if (total <= w) {
    for (const seg of segments) {
      if (seg.text) text(cx, sy, seg.text, seg.group);
      cx += term.measure(seg.text);
    }
    return;
  }

  // The last cell holds the ellipsis, and it takes the group of the run it cuts.
  const room = w - 1;
  let cutGroup;
  for (const seg of segments) {
    const avail = room - (cx - x);
    if (avail <= 0) break;
    const t = clip(seg.text, avail, false);
    if (t) text(cx, sy, t, seg.group);
    cx += term.measure(t);
    cutGroup = seg.group;
  }
  text(x + room, sy, "…", cutGroup);
}

// A fixed-array row source (width-independent), for the pickers and tests.
function staticRowSource(list) {
  return {
    rowCount() {
      return list.length;
    },
    rows(_w, top, height) {
      return list.slice(top, top + height);
    },
  };
}

// A user turn wraps to a plain tinted band with a gutter marker. Input is plain text, not markdown.
function userRows(id, body, width) {
  const contentW = Math.max(1, width - TX_GUTTER);
  const lines = body ? wrap(body, contentW) : [""];
  const rows = lines.map((line, i) => ({
    text: line,
    group: "TxUser",
    bg: "TxUser",
    indent: TX_GUTTER,
    marker: i === 0 ? "⟩" : null,
    markerGroup: "TxUserMarker",
    key: id,
  }));
  rows.push({ text: "", key: id });
  return rows;
}

// Show a failed turn's error in the gutter with a warning marker and the danger color.
function errorRows(id, error, width) {
  const label = "⚠ " + (error.message || error.type || "run failed");
  const contentW = Math.max(1, width - TX_GUTTER);
  const rows = wrap(label, contentW).map((line) => ({ text: line, group: "TxError", indent: TX_GUTTER, key: id }));
  rows.push({ text: "", key: id });
  return rows;
}

// A virtualized transcript (the Pager's row source). It holds descriptors ({id, type}) plus a
// wrapped-row cache. An assistant turn renders through yuke:md; only the streaming draft re-renders.
export class Transcript {
  constructor(opts = {}) {
    this.textOf = opts.textOf || (() => "");
    this.pager = new Pager();
    this.pager.setSource(this);
    this._messages = []; // committed descriptors, oldest first
    this._active = null; // the streaming draft descriptor, or null
    this._width = -1;
    this._rows = new Map(); // id -> { w, rows }
    this._docs = new Map(); // id -> md Document, for the assistant block cache
    // A selection holds two logical positions, `{ id, row, col }`. `row` counts the rendered rows
    // of that message and `col` is a string index into the row text.
    this.selection = null;
    this._dragging = false;
    this.onSelect = opts.onSelect || null;
  }

  clearSelection() {
    this.selection = null;
    this._dragging = false;
  }

  // The pane draws something else in this space, so a click must not hit a row that left it.
  hide() {
    this.pager.clearRect();
    this.clearSelection();
  }

  // Replace the outline. Rare (commit/resync/truncate); a re-commit can change content under a
  // stable id, so drop the caches.
  setOutline(messages, active) {
    this._messages = messages || [];
    this._active = active || null;
    this._rows.clear();
    this._docs.clear();
    this.clearSelection();
  }

  // A streaming delta on draft `id`: adopt it if new, and drop its cached rows so it re-renders.
  setActive(id) {
    // The draft rewraps as tokens arrive, but an append never moves the source before it.
    const sel = this.selection;
    const touches = !!sel && (sel.anchor.id === id || sel.cursor.id === id);
    const anchors = touches ? this._anchors() : null;
    if (!this._active || this._active.id !== id) this._active = { id, type: "assistant" };
    this._rows.delete(id);
    if (touches) this._reanchor(anchors);
  }

  // A width change rewraps every row, so a row index means other text. The selection moves back to
  // the same source instead.
  _invalidate(width) {
    if (width === this._width) return;
    const anchors = this._anchors();
    this._width = width;
    this._rows.clear();
    if (this.selection) this._reanchor(anchors);
  }

  // The selection as source offsets. Return null when either end carries no source.
  _anchors() {
    const sel = this.selection;
    if (!sel || this._width <= 0) return null;
    const a = this.sourceAt(sel.anchor);
    const b = this.sourceAt(sel.cursor);
    if (a < 0 || b < 0) return null;
    return { a: { id: sel.anchor.id, off: a }, b: { id: sel.cursor.id, off: b } };
  }

  // Put the selection back on the same source text. A missing end clears it, so a selection never
  // moves to text the user did not choose.
  _reanchor(anchors) {
    const anchor = anchors && this.posAtSource(anchors.a.id, anchors.a.off);
    const cursor = anchors && this.posAtSource(anchors.b.id, anchors.b.off);
    if (!anchor || !cursor) {
      this.clearSelection();
      return;
    }
    this.selection = { anchor, cursor };
  }

  // The markdown blocks of one message, oldest first. A plain turn has none.
  blocksOf(id) {
    this.rowsOf(id);
    const doc = this._docs.get(id);
    return doc ? doc.blocks() : [];
  }

  // The rendered rows of one message at the drawn width.
  rowsOf(id) {
    const i = this._indexOf(id);
    if (i < 0 || this._width <= 0) return [];
    return this._rowsOf(this._at(i), this._width);
  }

  // The row index of `pos` across every message, or -1 when the position is gone.
  _globalRow(pos) {
    if (!pos || this._width <= 0) return -1;
    let base = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) return -1;
      const rows = this._rowsOf(m, this._width);
      if (m.id === pos.id) return pos.row < rows.length ? base + pos.row : -1;
      base += rows.length;
    }
  }

  // The source offset under a logical position, or -1 without one.
  sourceAt(pos) {
    const rows = pos ? this.rowsOf(pos.id) : [];
    if (pos.row >= rows.length) return -1;
    return rowSourceAt(rows[pos.row], pos.col);
  }

  // The position that renders source `offset`, or the first one after it. The end of the source
  // takes the last position, so a selection that runs to the end survives a rewrap.
  posAtSource(id, offset) {
    const rows = this.rowsOf(id);
    let tail = null;
    let tailOff = -1;
    for (let k = 0; k < rows.length; k++) {
      const segments = rows[k].segments;
      if (!segments) continue;
      let at = 0;
      for (const seg of segments) {
        const end = at + seg.text.length;
        if (seg.src != null) {
          if (seg.srcEnd > offset) {
            // A caret at the end of the source before a gap belongs to that end, not past it.
            if (offset === tailOff) return tail;
            const col = offset > seg.src && isLinear(seg) ? at + (offset - seg.src) : at;
            return { id, row: k, col: Math.min(col, end) };
          }
          tail = { id, row: k, col: end };
          tailOff = seg.srcEnd;
        }
        at = end;
      }
    }
    return tail;
  }

  // The screen cell of a logical position, or null when it is off the drawn rows.
  screenAt(pos) {
    const rect = this.pager.rect();
    const g = this._globalRow(pos);
    if (!rect || g < 0) return null;
    const y = rect.y + (g - this.pager.scroll);
    if (y < rect.y || y >= rect.y + rect.h) return null;
    const row = this.rowsOf(pos.id)[pos.row];
    const body = rowText(row);
    return { x: rect.x + (row.indent || 0) + term.measure(body.slice(0, pos.col)), y };
  }

  // Scroll the least amount that brings `pos` onto the screen.
  ensureVisible(pos) {
    this.pager.scrollIntoView(this._globalRow(pos));
  }

  _rowsOf(m, width) {
    const c = this._rows.get(m.id);
    if (c && c.w === width) return c.rows;

    let rows = m.type === "user" ? userRows(m.id, this.textOf(m.id), width) : this._assistantRows(m.id, width);
    if (m.error) rows = rows.concat(errorRows(m.id, m.error, width));
    this._rows.set(m.id, { w: width, rows });
    return rows;
  }

  // Assistant rows come from a per-message md Document, indented past the gutter, then a separator.
  _assistantRows(id, width) {
    let doc = this._docs.get(id);
    if (!doc) {
      doc = new Document();
      this._docs.set(id, doc);
    }
    doc.setText(this.textOf(id));
    const contentW = Math.max(1, width - TX_GUTTER);
    const rows = doc.rows(contentW).map((r) => ({ segments: r.segments, indent: TX_GUTTER, key: id }));
    rows.push({ text: "", key: id });
    return rows;
  }

  _at(i) {
    return i < this._messages.length ? this._messages[i] : i === this._messages.length ? this._active : null;
  }

  // The message order index of `id`, or -1. A position outside the outline has no selection.
  _indexOf(id) {
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) return -1;
      if (m.id === id) return i;
    }
  }

  // Order the two ends and resolve them to message indexes. Return null without a live selection.
  _range() {
    const sel = this.selection;
    if (!sel || !sel.anchor || !sel.cursor) return null;
    const a = sel.anchor;
    const b = sel.cursor;
    const ia = this._indexOf(a.id);
    const ib = this._indexOf(b.id);
    if (ia < 0 || ib < 0) return null;
    const ordered = ia < ib || (ia === ib && (a.row < b.row || (a.row === b.row && a.col <= b.col)));
    return ordered ? { start: a, end: b, si: ia, ei: ib } : { start: b, end: a, si: ib, ei: ia };
  }

  // Return a row range for the rows inside the selection. Keep an empty row in the middle, so a
  // blank line survives the copy, but drop an empty end row.
  _rowRange(range, i, k, len) {
    if (i < range.si || i > range.ei) return null;
    if (i === range.si && k < range.start.row) return null;
    if (i === range.ei && k > range.end.row) return null;
    const last = i === range.ei && k === range.end.row;
    if (last && range.end.col === 0 && !(i === range.si && k === range.start.row)) return null;
    const from = i === range.si && k === range.start.row ? range.start.col : 0;
    const to = last ? range.end.col : len;
    return to < from ? null : { from, to };
  }

  // The selected text, with one line feed between rows. The indent stays out of the copy.
  selectedText() {
    const range = this._range();
    if (!range || this._width <= 0) return "";
    const out = [];
    for (let i = range.si; i <= range.ei; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsOf(m, this._width);
      for (let k = 0; k < rows.length; k++) {
        const body = rowText(rows[k]);
        const r = this._rowRange(range, i, k, body.length);
        if (r) out.push(body.slice(r.from, r.to));
      }
    }
    return out.join("\n");
  }

  // The markdown under the selection. A mouse copy still takes `selectedText`, so the rendered
  // text and the source stay separate. A turn with no mapped row is plain text and is its own source.
  selectedSource() {
    const range = this._range();
    if (!range || this._width <= 0) return "";
    const out = [];
    for (let i = range.si; i <= range.ei; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsOf(m, this._width);
      const plain = [];
      let from = -1;
      let to = -1;
      for (let k = 0; k < rows.length; k++) {
        const r = this._rowRange(range, i, k, rowText(rows[k]).length);
        if (!r) continue;
        plain.push(rowText(rows[k]).slice(r.from, r.to));
        const span = rowSourceSpan(rows[k], r.from, r.to);
        if (!span) continue;
        if (from < 0 || span.from < from) from = span.from;
        if (span.to > to) to = span.to;
      }
      if (from < 0) {
        if (plain.length) out.push(plain.join("\n"));
        continue;
      }
      const doc = this._docs.get(m.id);
      out.push((doc ? doc.sourceText() : this.textOf(m.id)).slice(from, to));
    }
    return out.join("\n");
  }

  rowCount(width) {
    if (width <= 0) return 0;
    this._invalidate(width);
    let n = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) break;
      n += this._rowsOf(m, width).length;
    }
    return n;
  }

  rows(width, top, height) {
    if (width <= 0 || height <= 0) return [];
    this._invalidate(width);
    const range = this._range();
    const out = [];
    let base = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsOf(m, width);
      for (let k = 0; k < rows.length; k++) {
        const abs = base + k;
        if (abs < top || abs >= top + height) continue;
        // The row objects are cached, so a selection goes onto a copy.
        const r = range && this._rowRange(range, i, k, rowText(rows[k]).length);
        // An empty range paints nothing, so only a real span goes onto the row copy.
        out.push(r && r.to > r.from ? { ...rows[k], sel: r } : rows[k]);
      }
      base += rows.length;
      if (base >= top + height) break;
    }
    return out;
  }

  // The committed messages, oldest first, then the streaming draft. Each one is a copy, so a
  // caller cannot change the transcript through it.
  messages() {
    const out = this._messages.map((m) => ({ ...m }));
    if (this._active) out.push({ ...this._active });
    return out;
  }

  // The newest message of `type`, or the newest of any type without one. Return null when empty.
  last(type) {
    const all = this.messages();
    for (let i = all.length - 1; i >= 0; i--) {
      if (!type || all[i].type === type) return all[i];
    }
    return null;
  }

  textFor(m) {
    return m ? this.textOf(m.id) : "";
  }

  // Return the fenced block bodies of every message, oldest first. A user turn can also hold a
  // fence, so no turn type is skipped.
  codeBlocks() {
    const out = [];
    for (const m of this.messages()) {
      let doc = this._docs.get(m.id);
      if (!doc) {
        doc = new Document();
        this._docs.set(m.id, doc);
      }
      // A changed source makes the cached rows stale, because this call is outside a draw.
      if (doc.setText(this.textOf(m.id))) this._rows.delete(m.id);
      for (const b of doc.codeBlocks()) out.push({ id: m.id, lang: b.lang, text: b.text });
    }
    return out;
  }

  draw(rect) {
    this.pager.draw(rect);
  }

  onKey(ev) {
    return this.pager.onKey(ev);
  }

  // The logical position under a screen cell, or null off the drawn rows. `clamp` pulls a pointer
  // outside the pane back to the nearest row, so a drag keeps up with it.
  posAt(col, row, clamp) {
    const rect = this.pager.rect();
    if (!rect) return null;
    const y = clamp ? Math.min(Math.max(row, rect.y), rect.y + rect.h - 1) : row;
    const g = this.pager.rowAtY(y);
    if (g < 0) return null;
    let base = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) return null;
      const rows = this._rowsOf(m, this._width);
      if (g < base + rows.length) {
        const line = rows[g - base];
        const body = rowText(line);
        const x = Math.max(0, col - rect.x - (line.indent || 0));
        return { id: m.id, row: g - base, col: caretAtCol(body, { start: 0, end: body.length }, x) };
      }
      base += rows.length;
    }
  }

  // A left drag selects text. The wheel still scrolls, and a bare click drops the old selection.
  // Only a press starts a gesture, so a stray drag or release never revives an old selection.
  onMouse(ev) {
    if (isWheel(ev.button)) return this.pager.onMouse(ev);
    if (ev.button !== "left") return false;
    if (ev.event === "press") {
      const pos = this.posAt(ev.col, ev.row, false);
      this.selection = pos ? { anchor: pos, cursor: pos } : null;
      this._dragging = pos != null;
      return true;
    }
    if (!this._dragging) return false;
    if (ev.event === "drag") {
      // A drag past the edge clamps, so the selection follows the pointer out of the pane.
      const pos = this.posAt(ev.col, ev.row, true);
      if (this.selection && pos) this.selection.cursor = pos;
      return true;
    }
    if (ev.event === "release") {
      this._dragging = false;
      const text = this.selectedText();
      if (text === "") this.clearSelection();
      else if (this.onSelect) this.onSelect(text);
      return true;
    }
    return false;
  }
}

// A message input grows with its text. Enter submits and the newline keys add a line.
// Normal mode passes a bare key to the keymap and the transcript.
export class Composer {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.input = new TextInput({
      onChange: () => this._invalidate(),
      onEdit: (from, to, ins) => this._shiftSpans(from, to, ins),
    });
    this.prompt = opts.prompt != null ? opts.prompt : "› ";
    this.normalPrompt = opts.normalPrompt != null ? opts.normalPrompt : "▪ ";
    this.placeholder = opts.placeholder || "";
    this.onSubmit = opts.onSubmit || null;
    this.mode = "insert"; // the opt-in composer-vim layer flips to "normal"
    this.maxRows = opts.maxRows || COMPOSER_ROWS_MAX;
    this.scroll = 0;
    this.goalCol = null; // the column a vertical move holds across a short row
    // A collapsed paste. `start` and `end` index the text; the label replaces them on the screen
    // only. The text keeps the paste, so a submit sends it even when a span is lost.
    this.spans = [];
    this.nextPaste = 1;
    this._rows = null;
    this._rowsW = -1;
    this._proj = null;
  }

  // Drop the projection and the row cache after an edit, so both rebuild once per edit.
  _invalidate() {
    this._rows = null;
    this._proj = null;
    this.goalCol = null;
  }

  // Move a span the edit did not touch. An edit inside a span drops the span and shows the paste.
  _shiftSpans(from, to, ins) {
    if (this.spans.length === 0) return;
    const delta = ins - (to - from);
    this.spans = this.spans.filter((sp) => {
      if (sp.end <= from) return true;
      if (sp.start >= to) {
        sp.start += delta;
        sp.end += delta;
        return true;
      }
      return false;
    });
    this._invalidate();
  }

  // The text as the screen shows it: each collapsed span becomes its label.
  _projection() {
    if (this._proj) return this._proj;
    const s = this.input.text;
    if (this.spans.length === 0) {
      this._proj = { text: s, parts: [] };
      return this._proj;
    }
    const spans = this.spans.slice().sort((a, b) => a.start - b.start);
    const parts = [];
    let out = "";
    let at = 0;
    for (const sp of spans) {
      // A span is internal state. An overlap or a bad offset makes the caret map ambiguous.
      if (sp.start < at || sp.end <= sp.start || sp.end > s.length) throw new Error("bad composer span");
      out += s.slice(at, sp.start);
      // `delta` is what the label adds to every offset after it.
      const start = out.length;
      parts.push({ span: sp, start, end: start + sp.label.length, delta: sp.label.length - (sp.end - sp.start) });
      out += sp.label;
      at = sp.end;
    }
    this._proj = { text: out + s.slice(at), parts };
    return this._proj;
  }

  // The caret never rests inside a span, so the map adds the delta of every label before it.
  _toDisplay(caret) {
    let d = caret;
    for (const p of this._projection().parts) if (caret >= p.span.end) d += p.delta;
    return d;
  }

  // Map back, and push a caret that landed inside a label to its nearer edge.
  _toText(disp) {
    let t = disp;
    for (const p of this._projection().parts) {
      if (disp > p.start && disp < p.end) return disp - p.start < p.end - disp ? p.span.start : p.span.end;
      if (disp >= p.end) t -= p.delta;
    }
    return t;
  }

  _spanEndingAt(caret) {
    return this.spans.find((sp) => sp.end === caret) || null;
  }

  _spanStartingAt(caret) {
    return this.spans.find((sp) => sp.start === caret) || null;
  }

  // The prompt marks the mode, so a modal layer never has to hide the text to show its state.
  _prompt() {
    return this.mode === "insert" ? this.prompt : this.normalPrompt;
  }

  _textWidth(w) {
    return Math.max(1, w - term.measure(this._prompt()));
  }

  _rowsAt(width) {
    if (this._rows && this._rowsW === width) return this._rows;
    this._rowsW = width;
    this._rows = wrapOffsets(this._projection().text, width);
    return this._rows;
  }

  // The rows the text needs. The caller caps this against the space it has.
  height(w) {
    if (w <= 0) return 0;
    if (this.input.text === "") return 1;
    return Math.min(this.maxRows, this._rowsAt(this._textWidth(w)).length);
  }

  get name() {
    return "composer";
  }

  get text() {
    return this.input.text;
  }

  set text(s) {
    this.input.setText(s);
  }

  // Submit the text and not the projection, so a lost span can never send a label.
  submit() {
    const t = this.input.text.trim();
    if (t === "") return;
    // The owner may reject synchronously (returns false): keep the text rather than blank it.
    if (this.onSubmit && this.onSubmit(t) === false) return;
    this.spans = [];
    this.nextPaste = 1;
    this.input.setText("");
  }

  onKey(ev) {
    if (this.mode !== "insert") return false;
    const s = strokeOf(ev);
    // The composer owns the vertical keys, so a wrapped line never scrolls the transcript.
    if (s === "up") return this._moveRow(-1);
    if (s === "down") return this._moveRow(1);

    // Every other key edits or moves the caret across, so the goal column is stale.
    this.goalCol = null;
    if (s === "paste") return this._paste(ev.text || "");
    if (s === "enter") {
      this.submit();
      return true;
    }
    if (COMPOSER_NEWLINE[s]) {
      this.input.insert("\n");
      return true;
    }
    // A collapsed span deletes and steps as one unit. `ctrl+w` must not eat a word inside it.
    if (s === "backspace" || s === "ctrl+w" || s === "delete") {
      const sp = s === "delete" ? this._spanStartingAt(this.input.caret) : this._spanEndingAt(this.input.caret);
      if (sp) {
        this.input.replace(sp.start, sp.end, "");
        return true;
      }
    }
    if (s === "left" || s === "right") {
      const sp = s === "left" ? this._spanEndingAt(this.input.caret) : this._spanStartingAt(this.input.caret);
      if (sp) {
        this.input.caret = s === "left" ? sp.start : sp.end;
        return true;
      }
    }
    return this.input.onKey(ev);
  }

  // Collapse a large paste to a label. The same paste beside its label expands it again.
  _paste(t) {
    if (t === "") return true;
    const sides = [this._spanEndingAt(this.input.caret), this._spanStartingAt(this.input.caret)];
    const near = sides.find((sp) => sp && this.input.text.slice(sp.start, sp.end) === t);
    if (near) {
      this.spans = this.spans.filter((sp) => sp !== near);
      this._invalidate();
      return true;
    }
    const from = this.input.caret;
    this.input.insert(t);
    if (pasteCollapses(t)) {
      this.spans.push({ start: from, end: from + t.length, label: pasteLabel(this.nextPaste++, t) });
      this._invalidate();
    }
    return true;
  }

  // Move the caret one row. The goal column survives a short row, as vim and helix do.
  // The move stops at the first and the last row.
  _moveRow(delta) {
    const rows = this._rowsAt(this._textWidth(this.rect.w));
    const proj = this._projection().text;
    const here = caretRowCol(proj, rows, this._toDisplay(this.input.caret));
    const col = this.goalCol === null ? here.col : this.goalCol;
    const next = here.row + delta;
    if (next >= 0 && next < rows.length) {
      this.input.caret = this._toText(caretAtCol(proj, rows[next], col));
      this.goalCol = col;
    }
    return true;
  }

  // Scroll the smallest amount that keeps the caret row on the screen.
  _scrollTo(rows, h) {
    const { row } = caretRowCol(this._projection().text, rows, this._toDisplay(this.input.caret));
    this.scroll = Math.min(this.scroll, Math.max(0, rows.length - h));
    if (row < this.scroll) this.scroll = row;
    else if (row >= this.scroll + h) this.scroll = row - h + 1;
  }

  draw(_focused) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    fill(x, y, w, h, "UIComposer");
    if (this.input.text === "") {
      this.scroll = 0;
      text(x, y, clip(this._prompt() + this.placeholder, w), "UIDim");
      return;
    }

    const tw = this._textWidth(w);
    const rows = this._rowsAt(tw);
    const proj = this._projection().text;
    this._scrollTo(rows, h);
    const pw = w - tw;
    // The prompt marks the first row only. A later row aligns under it.
    if (this.scroll === 0) text(x, y, this._prompt(), "UIComposer");
    for (let i = 0; i < h && this.scroll + i < rows.length; i++) {
      const r = rows[this.scroll + i];
      text(x + pw, y + i, clip(proj.slice(r.start, r.end), tw, false), "UIComposer");
    }
  }

  cursor() {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return null;
    const tw = this._textWidth(w);
    const rows = this._rowsAt(tw);
    const { row, col } = caretRowCol(this._projection().text, rows, this._toDisplay(this.input.caret));
    const vy = row - this.scroll;
    if (vy < 0 || vy >= h) return { x, y, visible: false };
    // A space hangs past the right edge, so the caret column clamps to the last cell.
    return { x: x + (w - tw) + Math.min(col, tw - 1), y: y + vy, visible: true };
  }
}

// The composer stops growing here, so the transcript keeps its room.
const COMPOSER_ROWS_MAX = 10;

// A paste over one of these collapses to a label, as OpenCode does.
const COMPOSER_PASTE_LINES = 3;
const COMPOSER_PASTE_CHARS = 150;

function pasteCollapses(t) {
  return t.length > COMPOSER_PASTE_CHARS || lineCount(t) >= COMPOSER_PASTE_LINES;
}

// A newline at the end closes the last line. It does not open an empty one.
function lineCount(t) {
  const end = t.length > 0 && t[t.length - 1] === "\n" ? t.length - 1 : t.length;
  let n = 1;
  for (let i = t.indexOf("\n"); i >= 0 && i < end; i = t.indexOf("\n", i + 1)) n++;
  return n;
}

// Count lines for a multiline paste. Count characters for a single-line paste.
function pasteLabel(id, t) {
  const lines = lineCount(t);
  const what = lines >= COMPOSER_PASTE_LINES ? lines + " lines" : t.length + " chars";
  return "[Pasted text #" + id + " +" + what + "]";
}

// These strokes add a line instead of a submit.
// Alt+Enter and Ctrl+J support a terminal with the legacy encoding.
const COMPOSER_NEWLINE = { "shift+enter": true, "alt+enter": true, "ctrl+j": true };

// Border glyph sets, keyed by name. Extend by adding an entry.
export const borders = {
  single: { tl: "┌", t: "─", tr: "┐", r: "│", br: "┘", b: "─", bl: "└", l: "│" },
  rounded: { tl: "╭", t: "─", tr: "╮", r: "│", br: "╯", b: "─", bl: "╰", l: "│" },
  double: { tl: "╔", t: "═", tr: "╗", r: "║", br: "╝", b: "═", bl: "╚", l: "║" },
};

// A floating, bordered, titled window centers over the screen as an overlay-stack layer. The
// interior is winText/winFill (clipped); override drawContent(win) or set a `content`.
// The chat pane: a transcript above a composer in one leaf. setOutline feeds the transcript (text
// via textOf); the composer calls onSubmit(text); an unconsumed key scrolls the transcript.
export class ChatView {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.transcript = new Transcript({ textOf: opts.textOf, onSelect: opts.onSelect });
    this.composer = new Composer({ placeholder: "Message…", onSubmit: opts.onSubmit });
    this.status = opts.status || (() => "");
  }

  get name() {
    return "chat";
  }

  setOutline(messages, active) {
    this.transcript.setOutline(messages, active);
  }

  setActive(id) {
    this.transcript.setActive(id);
  }

  onKey(ev) {
    return this.composer.onKey(ev) || this.transcript.onKey(ev);
  }

  // Route by sub-rect, so a click or a wheel step over the composer never moves the transcript.
  // A captured drag still reaches the transcript, because only a press hits this test.
  onMouse(ev) {
    const r = this.transcript.pager.rect();
    const inside = r && ev.col >= r.x && ev.col < r.x + r.w && ev.row >= r.y && ev.row < r.y + r.h;
    if (inside || ev.event === "drag" || ev.event === "release") return this.transcript.onMouse(ev);
    return false;
  }

  draw(focused) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) {
      this.composer.rect = { x, y, w: 0, h: 0 };
      this.transcript.hide();
      return;
    }

    // The composer grows with its text. It never takes more than half the pane.
    const rows = Math.min(this.composer.height(w), Math.max(1, Math.floor(h / 2)));
    this.composer.rect = { x, y: y + h - rows, w, h: rows };
    // A status takes its own row over the composer. The rule stays whole under the transcript.
    const status = this.status();
    const noteY = y + h - rows - 1;
    const note = status && noteY - 1 > y ? 1 : 0;
    const rule = noteY - note;
    if (rule > y) this.transcript.draw({ x, y, w, h: rule - y });
    else this.transcript.hide();
    if (rule >= y) text(x, rule, "─".repeat(w), "YukeRule");
    if (note) text(x, noteY, clip(status, w), "YukeStatus");
    this.composer.draw(focused);
  }

  cursor() {
    return this.composer.cursor();
  }
}

export class Window {
  constructor(opts = {}) {
    this.opts = opts;
    this.modal = opts.modal !== false;
    this.border = opts.border === undefined ? "single" : opts.border;
    this.content = opts.content || null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.inner = { x: 0, y: 0, w: 0, h: 0 };
  }

  get name() {
    return this.opts.name || "window";
  }

  _borderSet() {
    const b = this.border;
    if (b === "none" || b == null) return null;
    return typeof b === "object" ? b : borders[b] || borders.single;
  }

  // Resolve a cells | ratio(0..1] | function(max)=>cells dimension against a max.
  _dim(v, max, fallback) {
    if (v == null) return fallback;
    if (typeof v === "function") return Math.round(v(max));
    if (v > 0 && v <= 1) return Math.round(v * max);
    return Math.round(v);
  }

  update() {
    const W = term.width;
    const H = term.height;
    const pad = this._borderSet() ? 2 : 0;

    let w = this._dim(this.opts.width, W, Math.round(W * 0.6));
    let h = this._dim(this.opts.height, H, Math.round(H * 0.6));
    w = Math.min(W, Math.max(pad + 1, w));
    h = Math.min(H, Math.max(pad + 1, h));

    const x = Math.max(0, Math.floor((W - w) / 2));
    const y = Math.max(0, Math.floor((H - h) / 2));
    this.rect = { x, y, w, h };
    // The inner rect never goes negative, so a window smaller than its border has an empty interior.
    this.inner = pad ? { x: x + 1, y: y + 1, w: Math.max(0, w - 2), h: Math.max(0, h - 2) } : { x, y, w, h };
  }

  winText(lx, ly, s, group) {
    const { x, y, w, h } = this.inner;
    if (ly < 0 || ly >= h || lx >= w) return;
    s = String(s);
    if (lx < 0) {
      s = s.slice(-lx);
      lx = 0;
    }
    const avail = w - lx;
    if (avail <= 0) return;
    text(x + lx, y + ly, clip(s, avail), group);
  }

  winFill(lx, ly, fw, fh, group) {
    const { x, y, w, h } = this.inner;
    const x0 = Math.max(0, lx);
    const y0 = Math.max(0, ly);
    const x1 = Math.min(w, lx + fw);
    const y1 = Math.min(h, ly + fh);
    if (x1 <= x0 || y1 <= y0) return;
    fill(x + x0, y + y0, x1 - x0, y1 - y0, group);
  }

  draw() {
    const { x, y, w, h } = this.rect;
    fill(x, y, w, h, this.opts.panelGroup || "UIPanel");
    const bs = this._borderSet();
    if (bs) this._drawBorder(bs);
    if (this.content && this.content.draw) this.content.draw(this);
    this.drawContent(this);
  }

  drawContent(_win) {}

  cursor() {
    return this.content && this.content.cursor ? this.content.cursor(this) : null;
  }

  onKey(ev) {
    return this.content && this.content.onKey ? this.content.onKey(ev) : false;
  }

  onMouse(ev) {
    return this.content && this.content.onMouse ? this.content.onMouse(ev) : false;
  }

  needsTick() {
    return this.content && this.content.needsTick ? this.content.needsTick() : null;
  }

  tick() {
    if (this.content && this.content.tick) this.content.tick();
  }

  _drawBorder(bs) {
    const { x, y, w, h } = this.rect;
    const g = this.opts.borderGroup || "UIBorder";
    const span = Math.max(0, w - 2);
    text(x, y, bs.tl + bs.t.repeat(span) + bs.tr, g);
    text(x, y + h - 1, bs.bl + bs.b.repeat(span) + bs.br, g);
    for (let i = 1; i < h - 1; i++) {
      text(x, y + i, bs.l, g);
      text(x + w - 1, y + i, bs.r, g);
    }
    this._drawLabel(this.opts.title, this.opts.title_pos, y, this.opts.titleGroup || "UITitle");
    this._drawLabel(this.opts.footer, this.opts.footer_pos, y + h - 1, this.opts.footerGroup || "UIBorder");
  }

  // A title/footer embedded in the border edge. `pos` is "left" (default), "center", or "right".
  _drawLabel(label, pos, ry, group) {
    if (!label) return;
    const s = typeof label === "function" ? label() : String(label);
    if (!s) return;
    const { x, w } = this.rect;
    const room = w - 4;
    if (room <= 0) return;
    const t = " " + clip(s, room) + " ";
    let tx = x + 2;
    if (pos === "center") tx = x + Math.floor((w - term.measure(t)) / 2);
    else if (pos === "right") tx = x + w - 2 - term.measure(t);
    text(Math.max(x + 1, tx), ry, t, group);
  }
}

// The content of a picker window: a List plus accept/cancel/validate and an optional per-instance
// keymap over the default actions (accept/cancel/next/prev/top/bottom/close).
export class PickerContent {
  constructor(items, opts) {
    this.opts = opts;
    this.win = null;
    this.list = new List({
      items,
      format: opts.format,
      key: opts.key,
      isSelectable: opts.isSelectable,
      onMove: opts.onMove,
      group: opts.itemGroup,
      selGroup: opts.selGroup,
      itemHeight: opts.itemHeight,
    });
    this.onAccept = opts.onAccept || null;
    this.onCancel = opts.onCancel || null;
    this.validate = opts.validate || null;
    this.keymap = opts.keymap || null;
    this.closeOnAccept = opts.closeOnAccept !== false;
  }

  setItems(items) {
    this.list.setItems(items);
  }

  selected() {
    return this.list.selected();
  }

  draw(win) {
    this.list.draw(win.inner);
  }

  onMouse(ev) {
    return this.list.onMouse(ev);
  }

  needsTick() {
    return this.opts.needsTick || null;
  }

  cursor() {
    return null;
  }

  close() {
    root.popOverlay(this.win);
  }

  // Accept the selection, gated by `validate`, then close unless `closeOnAccept` is false.
  accept() {
    const it = this.list.selected();
    if (it == null) return;
    if (this.validate && !this.validate(it)) return;
    if (this.onAccept) this.onAccept(it, this.list.selectedIndex());
    if (this.closeOnAccept) this.close();
  }

  cancel() {
    if (this.onCancel) this.onCancel();
    else this.close();
  }

  action(name) {
    switch (name) {
      case "accept":
        this.accept();
        break;
      case "cancel":
        this.cancel();
        break;
      case "close":
        this.close();
        break;
      case "next":
        this.list.move(1);
        break;
      case "prev":
        this.list.move(-1);
        break;
      case "top":
        this.list.moveToEdge(-1);
        break;
      case "bottom":
        this.list.moveToEdge(1);
        break;
    }
  }

  onKey(ev) {
    // A per-instance keymap wins: a function runs, a string names a default action, false disables.
    if (this.keymap) {
      const bound = this.keymap[strokeOf(ev)];
      if (bound === false) return true;
      if (typeof bound === "function") {
        bound(ev, this);
        return true;
      }
      if (typeof bound === "string") {
        this.action(bound);
        return true;
      }
    }
    if (this.list.onKey(ev)) return true;
    const stroke = strokeOf(ev);
    if (stroke === "enter") this.accept();
    else if (stroke === "esc") this.cancel();
    return true; // modal: consume every key
  }
}

// --- fuzzy matching -----------------------------------------------------------------------
// The fzy algorithm: an affine-gap alignment that rewards word boundaries and consecutive runs.
// The score runs over code points, so an astral char does not split. See github.com/jhawthorn/fzy.
const SCORE_MIN = -Infinity;
const SCORE_MAX = Infinity;
const GAP_LEADING = -0.005;
const GAP_TRAILING = -0.005;
const GAP_INNER = -0.01;
const MATCH_CONSECUTIVE = 1.0;
const MATCH_SLASH = 0.9;
const MATCH_WORD = 0.8;
const MATCH_CAPITAL = 0.7;
const MATCH_DOT = 0.6;
const FUZZY_MAX_LEN = 1024;

function isUpper(c) {
  return c !== c.toLowerCase() && c === c.toUpperCase();
}

function isLower(c) {
  return c !== c.toUpperCase() && c === c.toLowerCase();
}

function isWordChar(c) {
  return /[\p{L}\p{N}]/u.test(c);
}

// The bonus for a char given the char before it. fzy rewards a boundary only for a word char.
function charBonus(prev, cur) {
  if (isLower(prev) && isUpper(cur)) return MATCH_CAPITAL;
  if (!isWordChar(cur)) return 0;
  if (prev === "/") return MATCH_SLASH;
  if (prev === "-" || prev === "_" || prev === " ") return MATCH_WORD;
  if (prev === ".") return MATCH_DOT;
  return 0;
}

function precomputeBonus(chars) {
  const bonus = new Array(chars.length);
  let last = "/";
  for (let i = 0; i < chars.length; i++) {
    bonus[i] = charBonus(last, chars[i]);
    last = chars[i];
  }
  return bonus;
}

// True when `query` is a subsequence of `text`, case-insensitive.
function isSubsequence(textLower, queryLower) {
  let qi = 0;
  for (let i = 0; i < textLower.length && qi < queryLower.length; i++) {
    if (textLower[i] === queryLower[qi]) qi++;
  }
  return qi === queryLower.length;
}

// Score `query` against `text`; null when `query` is not a subsequence. Higher is better.
export function fuzzyMatch(text, query) {
  if (query === "") return 0;
  const T = Array.from(text);
  const Q = Array.from(query);
  if (Q.length > T.length) return null;

  const TL = T.map((c) => c.toLowerCase());
  const QL = Q.map((c) => c.toLowerCase());
  if (!isSubsequence(TL, QL)) return null;
  if (T.length > FUZZY_MAX_LEN) return SCORE_MIN; // too long to align; it matches but ranks last
  if (T.length === Q.length) return SCORE_MAX; // a same-length subsequence is an exact match

  const n = T.length;
  const m = Q.length;
  const bonus = precomputeBonus(T);
  let D = new Array(n).fill(SCORE_MIN); // best score that ends in a match at text i
  let M = new Array(n).fill(SCORE_MIN); // best score for query[0..j] over text[0..i]

  for (let j = 0; j < m; j++) {
    const gap = j === m - 1 ? GAP_TRAILING : GAP_INNER;
    const Dprev = D;
    const Mprev = M;
    D = new Array(n);
    M = new Array(n);
    let prevM = SCORE_MIN;
    for (let i = 0; i < n; i++) {
      if (QL[j] === TL[i]) {
        let s = SCORE_MIN;
        if (j === 0) s = i * GAP_LEADING + bonus[i];
        else if (i > 0) s = Math.max(Mprev[i - 1] + bonus[i], Dprev[i - 1] + MATCH_CONSECUTIVE);
        D[i] = s;
        M[i] = prevM = Math.max(s, prevM + gap);
      } else {
        D[i] = SCORE_MIN;
        M[i] = prevM = prevM + gap;
      }
    }
  }
  return M[n - 1];
}

// Rank `items` by fuzzy score of `query` against textOf(item), dropping non-matches. Ties break by
// shorter text, then lexicographically. An empty query keeps the input order.
export function fuzzyRank(items, query, textOf) {
  if (query === "") return items.slice();
  const scored = [];
  for (const it of items) {
    const t = textOf(it);
    const s = fuzzyMatch(t, query);
    if (s != null) scored.push({ it, s, t });
  }
  scored.sort((a, b) => b.s - a.s || a.t.length - b.t.length || (a.t < b.t ? -1 : a.t > b.t ? 1 : 0));
  return scored.map((e) => e.it);
}

// --- fuzzy picker -------------------------------------------------------------------------
// A finder: a query line above a ranked results list. Static `items` are fuzzy-ranked by
// filterText(item); a `suggest(query)` source recomputes candidates itself.
const PICKER_PROMPT = "› ";

export class Picker {
  constructor(opts) {
    this.opts = opts;
    this.win = null;
    this.input = new TextInput({ onChange: () => this.refilter() });
    this.source = opts.items || [];
    this.suggest = opts.suggest || null;
    this.textOf = opts.filterText || String;

    this.list = new List({
      items: [],
      format: opts.format,
      key: opts.key,
      isSelectable: opts.isSelectable,
      group: opts.itemGroup,
      selGroup: opts.selGroup,
      itemHeight: opts.itemHeight,
    });

    this.onAccept = opts.onAccept || null;
    this.onCancel = opts.onCancel || null;
    this.closeOnAccept = opts.closeOnAccept !== false;
    this.keymap = opts.keymap || null;
    this.refilter();
  }

  get query() {
    return this.input.text;
  }

  set query(s) {
    this.input.setText(s); // onChange refilters
  }

  setSource(items) {
    this.source = items || [];
    this.refilter();
  }

  // Recompute the visible list for the current query. A cleared selection lets setItems land on the
  // first selectable row, the best match (fuzzyRank sorts best first).
  refilter() {
    const items = this.suggest ? this.suggest(this.query) || [] : fuzzyRank(this.source, this.query, this.textOf);
    this.list.selectedKey = null;
    this.list.setItems(items);
  }

  selected() {
    return this.list.selected();
  }

  draw(win) {
    const { x, y, w, h } = win.inner;
    if (w <= 0 || h <= 0) {
      this.list.clearRect();
      return;
    }
    text(x, y, clip(PICKER_PROMPT, w), "UIPrompt");
    const pw = term.measure(PICKER_PROMPT);
    if (pw < w) text(x + pw, y, clip(this.query, w - pw), "UIQuery");
    if (h > 1) this.list.draw({ x, y: y + 1, w, h: h - 1 });
    else this.list.clearRect();
  }

  onMouse(ev) {
    return this.list.onMouse(ev);
  }

  cursor(win) {
    const { x, y, w, h } = win.inner;
    if (w <= 0 || h <= 0) return null; // an empty interior places no cursor
    const col = caretCol(w, PICKER_PROMPT, this.input.beforeCaret());
    return { x: x + Math.max(0, col), y, visible: true };
  }

  accept() {
    const it = this.list.selected();
    if (it == null) return;
    if (this.opts.validate && !this.opts.validate(it)) return;
    if (this.closeOnAccept) root.popOverlay(this.win);
    if (this.onAccept) this.onAccept(it);
  }

  cancel() {
    root.popOverlay(this.win);
    if (this.onCancel) this.onCancel();
  }

  onKey(ev) {
    const s = strokeOf(ev);
    // A per-instance keymap wins, checked before text input so a bound arrow drives the list.
    if (this.keymap) {
      const bound = this.keymap[s];
      if (bound === false) return true;
      if (typeof bound === "function") {
        bound(ev, this);
        return true;
      }
    }
    if (s === "enter") {
      this.accept();
      return true;
    }
    if (s === "esc") {
      this.cancel();
      return true;
    }
    if (s === "up" || s === "ctrl+p") {
      this.list.move(-1);
      return true;
    }
    if (s === "down" || s === "ctrl+n") {
      this.list.move(1);
      return true;
    }
    this.input.onKey(ev); // the shared buffer takes the edit; its onChange refilters
    return true; // modal: consume every key
  }
}

// The kit's public surface. `select` navigates a set; `pick` is the fuzzy finder. Both return
// { win, content, close }.
export const ui = {
  select(items, opts = {}) {
    const content = new PickerContent(items || [], opts);
    const win = new Window({ ...opts, content });
    content.win = win;
    root.pushOverlay(win);
    return { win, content, close: () => root.popOverlay(win) };
  },

  pick(opts = {}) {
    const content = new Picker(opts);
    const win = new Window({ ...opts, content });
    content.win = win;
    root.pushOverlay(win);
    return { win, content, close: () => root.popOverlay(win) };
  },
};
