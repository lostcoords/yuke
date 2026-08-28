// yuke:ui — the widget kit over yuke:core. List/Pager/Window are classes to subclass or patch.
// `ui` exports the pickers. Editor policy lives in yuke:core; presentation lives here.
import { term } from "yuke:term";
import { text, fill, clip, wrap, root, strokeOf, TextInput, caretCol, style } from "yuke:core";
import { Document } from "yuke:md";

// The kit seeds its highlight groups over the core palette. It seeds each missing group only, so a
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

  // Paint into rect { x, y, w, h }. A selected item fills all its rows; each item draws up to
  // `itemHeight` lines. Every row repaints each frame, so `format` may be dynamic.
  draw(rect) {
    const { x, y, w, h } = rect;
    if (w <= 0 || h <= 0) return;
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
    this._gPending = false;
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
    this._clamp();

    const rows = this.source.rows(w, this.scroll, h);
    for (let row = 0; row < h && row < rows.length; row++) {
      const r = rows[row];
      if (!r) break;
      const sy = y + row;
      if (r.bg) fill(x, sy, w, 1, r.bg);
      if (r.marker) text(x, sy, r.marker, r.markerGroup);
      const ind = r.indent || 0;
      if (r.segments) drawSegments(x + ind, sy, Math.max(0, w - ind), r.segments);
      else if (r.text) text(x + ind, sy, clip(r.text, Math.max(0, w - ind)), r.group);
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
}

// Draw styled segments left to right, each clipped to the space that remains.
function drawSegments(x, sy, w, segments) {
  let cx = x;
  for (const seg of segments) {
    const avail = w - (cx - x);
    if (avail <= 0) break;
    const t = clip(seg.text, avail);
    if (t) text(cx, sy, t, seg.group);
    cx += term.measure(t);
  }
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
  }

  // Replace the outline. Rare (commit/resync/truncate); a re-commit can change content under a
  // stable id, so drop the caches.
  setOutline(messages, active) {
    this._messages = messages || [];
    this._active = active || null;
    this._rows.clear();
    this._docs.clear();
  }

  // A streaming delta on draft `id`: adopt it if new, and drop its cached rows so it re-renders.
  setActive(id) {
    if (!this._active || this._active.id !== id) this._active = { id, type: "assistant" };
    this._rows.delete(id);
  }

  _invalidate(width) {
    if (width === this._width) return;
    this._width = width;
    this._rows.clear();
  }

  _rowsOf(m, width) {
    const c = this._rows.get(m.id);
    if (c && c.w === width) return c.rows;

    const rows = m.type === "user" ? userRows(m.id, this.textOf(m.id), width) : this._assistantRows(m.id, width);
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
    const out = [];
    let base = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsOf(m, width);
      for (let k = 0; k < rows.length; k++) {
        const abs = base + k;
        if (abs >= top && abs < top + height) out.push(rows[k]);
      }
      base += rows.length;
      if (base >= top + height) break;
    }
    return out;
  }

  draw(rect) {
    this.pager.draw(rect);
  }

  onKey(ev) {
    return this.pager.onKey(ev);
  }
}

// A single-line message input. Enter submits. The shared TextInput does the edits. Normal mode
// disables input, so bare keys fall through to the keymap and the transcript.
export class Composer {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.input = new TextInput();
    this.prompt = opts.prompt != null ? opts.prompt : "› ";
    this.placeholder = opts.placeholder || "";
    this.onSubmit = opts.onSubmit || null;
    this.mode = "insert"; // the opt-in vim layer flips to "normal"
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

  submit() {
    const t = this.input.text.trim();
    if (t === "") return;
    // The owner may reject synchronously (returns false): keep the text rather than blank it.
    if (this.onSubmit && this.onSubmit(t) === false) return;
    this.input.setText("");
  }

  onKey(ev) {
    if (this.mode !== "insert") return false;
    if (strokeOf(ev) === "enter") {
      this.submit();
      return true;
    }
    return this.input.onKey(ev);
  }

  draw(_focused) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    fill(x, y, w, h, "UIComposer");
    if (this.mode !== "insert") {
      text(x, y, clip("-- " + this.mode.toUpperCase() + " --", w), "UIDim");
      return;
    }
    const empty = this.text === "";
    text(x, y, clip(this.prompt + (empty ? this.placeholder : this.text), w), empty ? "UIDim" : "UIComposer");
  }

  cursor() {
    if (this.mode !== "insert") return null;
    const { x, y, w } = this.rect;
    const col = caretCol(w, this.prompt, this.input.beforeCaret());
    return { x: x + Math.max(0, col), y, visible: true };
  }
}

// Border glyph sets, keyed by name. Extend by adding an entry.
export const borders = {
  single: { tl: "┌", t: "─", tr: "┐", r: "│", br: "┘", b: "─", bl: "└", l: "│" },
  rounded: { tl: "╭", t: "─", tr: "╮", r: "│", br: "╯", b: "─", bl: "╰", l: "│" },
  double: { tl: "╔", t: "═", tr: "╗", r: "║", br: "╝", b: "═", bl: "╚", l: "║" },
};

// A floating, bordered, titled window centered over the screen — an overlay-stack layer. The
// interior is winText/winFill (clipped); override drawContent(win) or set a `content`.
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
    this.inner = pad ? { x: x + 1, y: y + 1, w: w - 2, h: h - 2 } : { x, y, w, h };
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
    this.input.setText(s);
    this.refilter();
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
    if (w <= 0 || h <= 0) return;
    text(x, y, clip(PICKER_PROMPT, w), "UIPrompt");
    const pw = term.measure(PICKER_PROMPT);
    if (pw < w) text(x + pw, y, clip(this.query, w - pw), "UIQuery");
    if (h > 1) this.list.draw({ x, y: y + 1, w, h: h - 1 });
  }

  cursor(win) {
    const { x, y, w } = win.inner;
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
