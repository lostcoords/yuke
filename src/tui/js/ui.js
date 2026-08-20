// yuke:ui — the widget kit built on yuke:core. List/Pager/Window are classes you subclass or
// patch; `ui` exports the pickers. Editor policy stays in yuke:core; presentation lives here.
import { term } from "yuke:term";
import { text, fill, clip, wrap, root, strokeOf, TextInput, caretCol, style } from "yuke:core";

// The kit seeds its own highlight groups over the core palette — presentation lives with the
// widgets, not in core. A theme overrides these by mutating style.groups then invalidating.
Object.assign(style.groups, {
  UIPanel: { fg: "fg", bg: "bg" },
  UIBorder: { fg: "muted", bg: "bg" },
  UITitle: { fg: "accent", bold: true },
  UIItem: { fg: "fg" },
  UIItemSel: { fg: "fg", bg: "sel" },
  UIPrompt: { fg: "accent", bold: true },
  UIQuery: { fg: "fg" },
  UIComposer: { fg: "fg" },
  UIDim: { fg: "muted" },
  UIDimSel: { fg: "muted", bg: "sel" },
  // Transcript: assistant text is plain; a user turn gets a full-width tinted band so the two
  // read apart without role labels. The user marker is a thin gutter cue, not a label.
  TxText: { fg: "fg" },
  TxUser: { fg: "fg", bg: "userbg" },
  TxUserMarker: { fg: "accent", bg: "userbg" },
});
style.palette.userbg = 236;
style.invalidate();

// Default page jump for page_up/page_down before a draw establishes the real page height.
const PAGE_FALLBACK = 10;

// Left gutter reserved for a transcript row's marker; body text is indented past it.
const TX_GUTTER = 2;

// Shift bit in the host modifier mask (js.odin: Shift=1). strokeOf folds Shift into the base
// char, so a shifted letter (G, our "bottom") is recovered from the raw event instead.
const MOD_SHIFT = 1;

// The base letter of a shifted char event, or "" if not one — recovers G from g after strokeOf
// folds their case together, whether the terminal reports Shift or just uppercases the char.
function shiftedChar(ev) {
  if (ev.code !== "char" || !ev.char) return "";
  if (ev.char !== ev.char.toLowerCase()) return ev.char.toLowerCase();
  if ((ev.mods | 0) & MOD_SHIFT) return ev.char.toLowerCase();
  return "";
}

// Shared nav vocabulary for every scrollable widget: j/k move, ctrl+d/u page, gg/G top/bottom.
// Returns "pending_g" when a first g was swallowed; `gPending` is the caller's memory of it.
function navAction(ev, gPending) {
  const s = strokeOf(ev);
  const sc = shiftedChar(ev);
  if (gPending && s === "g" && !sc) return "top"; // second g of gg

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
      return sc === "g" ? "bottom" : "pending_g"; // G is bottom; g starts gg
  }

  return "";
}

// A scrollable, selectable list rendered into a caller-assigned rect. Items are opaque; `key(item)`
// gives a stable identity so the selection follows its item across a re-sorted `items`, not the index.
export class List {
  constructor(opts = {}) {
    this.format = opts.format || ((it) => ({ text: String(it) }));
    this.key = opts.key || ((it) => it);
    this.isSelectable = opts.isSelectable || (() => true);
    this.onMove = opts.onMove || null;

    // Highlight groups; row-level `format` fields override these per row.
    this.group = opts.group || "UIItem";
    this.selGroup = opts.selGroup || "UIItemSel";
    this.dimGroup = opts.dimGroup || "UIDim";
    this.dimSelGroup = opts.dimSelGroup || "UIDimSel";

    this.selectedKey = null;
    this.scroll = 0; // first visible row index
    this._page = PAGE_FALLBACK; // last drawn height, for page moves
    this._gPending = false; // a g awaiting its pair (gg = top)
    this.setItems(opts.items || []);
  }

  // Replace the backing items, preserving the selected identity when it survives.
  setItems(items) {
    this.items = items || [];
    this._ensureSelection();
    this._clampScroll(this._page);
  }

  // Item indices that selection may land on (skips sections, blanks, dividers).
  _selectable() {
    const out = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.isSelectable(this.items[i])) out.push(i);
    }
    return out;
  }

  // Item index of the current selection, or -1 when its key is gone.
  _selIndex() {
    if (this.selectedKey == null) return -1;
    for (let i = 0; i < this.items.length; i++) {
      if (this.isSelectable(this.items[i]) && this.key(this.items[i]) === this.selectedKey) return i;
    }
    return -1;
  }

  // Fall back to the first selectable item when the selection has no home.
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

  // Scroll so the selection is visible within `h` rows, then clamp — for a view that renders
  // the rows itself (using `scroll`) rather than calling draw().
  ensureVisible(h) {
    this._page = h;
    this._scrollToVisible(h);
  }

  // Move the selection by `delta` selectable rows, clamped to the ends.
  move(delta) {
    const sel = this._selectable();
    if (sel.length === 0) return;

    let pos = sel.indexOf(this._selIndex());
    pos = pos < 0 ? 0 : Math.min(Math.max(pos + delta, 0), sel.length - 1);
    this.selectedKey = this.key(this.items[sel[pos]]);
    if (this.onMove) this.onMove(this.items[sel[pos]], sel[pos]);
  }

  // Jump to the first (dir < 0) or last (dir > 0) selectable row; move() clamps to the end.
  moveToEdge(dir) {
    this.move(dir < 0 ? -this.items.length : this.items.length);
  }

  // Bring the selected row into view, then clamp.
  _scrollToVisible(h) {
    const i = this._selIndex();
    if (i >= 0 && h > 0) {
      if (i < this.scroll) this.scroll = i;
      else if (i >= this.scroll + h) this.scroll = i - h + 1;
    }
    this._clampScroll(h);
  }

  _clampScroll(h) {
    const max = Math.max(0, this.items.length - Math.max(1, h));
    this.scroll = Math.min(Math.max(this.scroll, 0), max);
  }

  // A nav key the list consumes; Enter/Esc belong to the owner. Returns whether handled.
  // Shares navAction with the pager so both move by the same vocabulary (j/k, ctrl+d/u, gg, G).
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
        return true; // swallow the first g of gg
    }

    return false;
  }

  // Paint into rect { x, y, w, h }. Rows are clipped to the width; rows past `h` are not
  // drawn. Every row repaints each frame (immediate mode), so `format` may be dynamic.
  draw(rect) {
    const { x, y, w, h } = rect;
    if (w <= 0 || h <= 0) return;

    this._page = h;
    this._scrollToVisible(h);

    for (let row = 0; row < h; row++) {
      const i = this.scroll + row;
      if (i >= this.items.length) break;

      const it = this.items[i];
      const sy = y + row;
      const isSel = this.isSelectable(it) && this.key(it) === this.selectedKey;
      const cell = normalizeCell(this.format(it, i));

      if (isSel) fill(x, sy, w, 1, this.selGroup);

      let avail = w;
      if (cell.right) {
        const r = clip(cell.right, w);
        if (r.length > 0 && r.length + 1 < w) {
          const rg = isSel ? cell.rightSelGroup || this.dimSelGroup : cell.rightGroup || this.dimGroup;
          text(x + w - r.length, sy, r, rg);
          avail = w - r.length - 1;
        }
      }

      const g = isSel ? cell.selGroup || this.selGroup : cell.group || this.group;
      text(x, sy, clip(cell.text, avail), g);
    }
  }
}

// A row from `format` may be a bare string or a record; fold both into one shape.
function normalizeCell(cell) {
  if (cell == null) return { text: "" };
  if (typeof cell === "string") return { text: cell };
  return { text: cell.text != null ? String(cell.text) : "", ...cell };
}

// A vertical pager over a row source — { rowCount(width), rows(width, top, height) } — so the source
// can virtualize (only visible rows pulled per draw). `stuck` follows the tail; a row is { text, … }.
export class Pager {
  constructor() {
    this.source = staticRowSource([]);
    this.scroll = 0;
    this.stuck = true; // follow the bottom
    this._h = 0; // last drawn height
    this._w = 0; // last drawn width
    this._gPending = false; // a g awaiting its pair (gg = top)
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

  // Swap the row source. Following the tail snaps to bottom on the next draw; otherwise the row
  // offset is kept, so content above the viewport stays put across a re-layout below it.
  setSource(source) {
    this.source = source || staticRowSource([]);
  }

  // A fixed array of rows, for callers that already have them all (e.g. the fuzzy pickers).
  setRows(rows) {
    this.setSource(staticRowSource(rows));
    this._clamp();
  }

  // Keep the scroll offset in range as the row count changes (a draft discarded, a resize shrinking
  // the wrap). Landing on the tail re-sticks, so a shrink that reaches the bottom resumes following.
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
      if (r.text) text(x + ind, sy, clip(r.text, Math.max(0, w - ind)), r.group);
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
        return true; // swallow the first g of gg
    }

    return false;
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

// Wrap one message's text into transcript rows: a role band + gutter marker, wrapped body, and a
// trailing separator. `text` is the message body (text parts joined); "" renders one blank row.
function wrapMessage(m, text, width) {
  const user = m.type === "user";
  const contentW = Math.max(1, width - TX_GUTTER);
  const group = user ? "TxUser" : "TxText";
  const bg = user ? "TxUser" : null;
  const key = m.id;

  const body = text ? wrap(text, contentW) : [""];
  const rows = body.map((line, i) => ({ text: line, group, bg, indent: TX_GUTTER, marker: user && i === 0 ? "⟩" : null, markerGroup: "TxUserMarker", key }));
  rows.push({ text: "", key }); // separator, no band

  return rows;
}

// A virtualized transcript (the Pager's row source): holds only descriptors ({id, type}) + a
// wrapped-row cache, pulling text on demand via textOf(id). Only the draft re-wraps per delta.
export class Transcript {
  constructor(opts = {}) {
    this.textOf = opts.textOf || (() => "");
    this.pager = new Pager();
    this.pager.setSource(this);
    this._messages = []; // committed descriptors, oldest-first
    this._active = null; // the streaming draft descriptor, or null
    this._width = -1;
    this._rows = new Map(); // id -> { w, rows } wrapped-row cache
  }

  // Replace the outline. Rare (commit/resync/truncate); clears the wrap cache wholesale, since a
  // re-commit or seal can change a message's content under a stable id.
  setOutline(messages, active) {
    this._messages = messages || [];
    this._active = active || null;
    this._rows.clear();
  }

  // A streaming delta on draft `id`: adopt it as the active descriptor if new, and drop its cached
  // rows so only the growing draft re-wraps. The draft's role is always assistant.
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

    const rows = wrapMessage(m, this.textOf(m.id), width);
    this._rows.set(m.id, { w: width, rows });

    return rows;
  }

  // The message at visual position `i` in the committed window then the draft (no array alloc).
  _at(i) {
    return i < this._messages.length ? this._messages[i] : i === this._messages.length ? this._active : null;
  }

  // --- Pager row source ---
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

// A single-line message input. Enter submits; editing lives in the shared TextInput. Unhandled keys
// return false so the owner can route them, and normal mode disables input so bare keys fall through.
export class Composer {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.input = new TextInput();
    this.prompt = opts.prompt != null ? opts.prompt : "› ";
    this.placeholder = opts.placeholder || "";
    this.onSubmit = opts.onSubmit || null;
    this.mode = "insert"; // "insert" types; the opt-in vim layer flips to "normal"
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

    // The owner may reject synchronously (returns false, e.g. no open session) — keep the text
    // rather than blank it; any other return accepts and the line clears.
    if (this.onSubmit && this.onSubmit(t) === false) return;
    this.input.setText("");
  }

  onKey(ev) {
    // Normal mode disables text input: keys fall through to the keymap and the transcript, so
    // ctrl+w stays a window command there (it is word-erase only while typing).
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
    if (this.mode !== "insert") return null; // no caret while input is disabled

    const { x, y, w } = this.rect;
    const col = caretCol(w, this.prompt, this.input.beforeCaret());

    return { x: x + Math.max(0, col), y, visible: true };
  }
}

// Border glyph sets, keyed by name. Extend by adding an entry (each is 8 corner/edge glyphs).
export const borders = {
  single: { tl: "┌", t: "─", tr: "┐", r: "│", br: "┘", b: "─", bl: "└", l: "│" },
  rounded: { tl: "╭", t: "─", tr: "╮", r: "│", br: "╯", b: "─", bl: "╰", l: "│" },
  double: { tl: "╔", t: "═", tr: "╗", r: "║", br: "╝", b: "═", bl: "╚", l: "║" },
};

// A floating, bordered, titled window centered over the screen — an overlay-stack layer. It exposes
// the interior via winText/winFill (clipped); override drawContent(win) or set a `content`.
export class Window {
  constructor(opts = {}) {
    this.opts = opts;
    this.modal = opts.modal !== false;
    this.border = opts.border === undefined ? "single" : opts.border;
    this.content = opts.content || null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 }; // outer, includes the border
    this.inner = { x: 0, y: 0, w: 0, h: 0 }; // interior, excludes the border
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

  // Center on screen and derive the inner rect. Override for other placements.
  update() {
    const W = term.width;
    const H = term.height;
    const pad = this._borderSet() ? 2 : 0;

    let w = this._dim(this.opts.width, W, Math.round(W * 0.6));
    let h = this._dim(this.opts.height, H, Math.round(H * 0.6));
    w = Math.max(pad + 1, Math.min(w, W));
    h = Math.max(pad + 1, Math.min(h, H));

    const x = Math.max(0, Math.floor((W - w) / 2));
    const y = Math.max(0, Math.floor((H - h) / 2));
    this.rect = { x, y, w, h };
    this.inner = pad ? { x: x + 1, y: y + 1, w: w - 2, h: h - 2 } : { x, y, w, h };
  }

  // Interior text at inner-relative (lx, ly), clipped to the inner rect; off-rect is a no-op.
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

  // Interior fill of an inner-relative rect, clipped to the inner rect.
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

  // Override to paint the interior. Prefer winText/winFill so content stays clipped.
  drawContent(_win) {}

  // Forwarded to the content, so a picker's list/field can request the cursor.
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

  // A title/footer embedded in the border edge. `pos` is "left" (default), "center", "right".
  _drawLabel(label, pos, ry, group) {
    if (!label) return;

    const s = typeof label === "function" ? label() : String(label);
    if (!s) return;

    const { x, w } = this.rect;
    const room = w - 4; // a border cell plus a pad on each side
    if (room <= 0) return;

    const t = " " + clip(s, room) + " ";
    let tx = x + 2;
    if (pos === "center") tx = x + Math.floor((w - t.length) / 2);
    else if (pos === "right") tx = x + w - 2 - t.length;

    text(Math.max(x + 1, tx), ry, t, group);
  }
}

// The content of a picker window: a List plus accept/cancel/validate and an optional per-instance
// keymap over the default actions (accept/cancel/next/prev/top/bottom/close). onAccept gets the item.
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

  // Accept the selection, gated by `validate`, then close unless `closeOnAccept` is false (a
  // navigator like the explorer stays open to descend; a chooser dismisses).
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
    // Per-instance keymap wins: a function runs, a string names a default action, false
    // disables the stroke (consumed, no effect).
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

    return true; // modal: consume every key so nothing reaches the base
  }
}

// --- fuzzy matching -----------------------------------------------------------------------
// Score `query` against `text`, case-insensitive, requiring `query` as a subsequence; null when it
// does not match. Rewards consecutive runs and word-boundary matches, penalizes an unmatched prefix.
const FUZZY_SEP = "/\\_-. :";

export function fuzzyMatch(text, query) {
  if (query === "") return 0;

  let ti = 0;
  let qi = 0;
  let score = 0;
  let run = 0; // consecutive matches
  let first = -1; // index of the first matched char
  while (ti < text.length && qi < query.length) {
    const c = text[ti];
    const q = query[qi];
    if (c.toLowerCase() === q.toLowerCase()) {
      if (first < 0) first = ti;

      let bonus = run * 5;
      if (fuzzyBoundary(text, ti)) bonus += 10;
      if (c === q) bonus += 1;
      score += bonus;
      run += 1;
      qi += 1;
    } else {
      run = 0;
    }
    ti += 1;
  }

  if (qi < query.length) return null;

  return score - first;
}

// A word boundary in `text` at index i: the start, just after a separator, or a camelCase hump.
function fuzzyBoundary(text, i) {
  if (i === 0) return true;

  const prev = text[i - 1];
  if (FUZZY_SEP.indexOf(prev) >= 0) return true;

  const c = text[i];
  return c >= "A" && c <= "Z" && !(prev >= "A" && prev <= "Z");
}

// Rank `items` by fuzzy score of `query` against textOf(item), dropping non-matches. Ties break by
// shorter text then lexicographically. An empty query keeps the input order.
export function fuzzyRank(items, query, textOf) {
  if (query === "") return items.slice();

  const scored = [];
  for (const it of items) {
    const t = textOf(it);
    const s = fuzzyMatch(t, query);
    if (s != null) scored.push({ it, s, t });
  }

  scored.sort((x, y) => y.s - x.s || x.t.length - y.t.length || (x.t < y.t ? -1 : x.t > y.t ? 1 : 0));

  return scored.map((e) => e.it);
}

// --- fuzzy picker -------------------------------------------------------------------------
// A finder: a query line above a ranked results list. Static `items` are fuzzy-ranked by
// filterText(item); a `suggest(query)` source recomputes candidates itself. Window content.
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
    });

    this.onAccept = opts.onAccept || null;
    this.onCancel = opts.onCancel || null;
    // Stay open after accept (a navigator that descends) vs dismiss (a chooser); an optional
    // per-instance keymap binds non-text strokes (arrows) to actions the query would otherwise eat.
    this.closeOnAccept = opts.closeOnAccept !== false;
    this.keymap = opts.keymap || null;
    this.refilter();
  }

  get query() {
    return this.input.text;
  }

  set query(s) {
    this.input.setText(s);
  }

  // Replace the static item pool (a live source calls this as data arrives), keeping the query.
  setSource(items) {
    this.source = items || [];
    this.refilter();
  }

  // Recompute the visible list for the current query. Clearing the selection first lets setItems
  // land on the first selectable row — the best match, since fuzzyRank sorts best-first.
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

    // Per-instance keymap wins: a function runs, false disables the stroke (consumed, no effect).
    // Checked before text input so a bound arrow drives navigation without landing in the query.
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

    // Editing and caret movement go to the shared buffer; its onChange refilters. Left/right land
    // here as caret moves unless a per-instance keymap (e.g. the explorer) claimed them above.
    this.input.onKey(ev);

    return true; // modal: consume every key
  }
}

// The widget kit's public surface. `select` is the list picker (navigate a set); `pick` is the
// fuzzy finder (type to filter). Both return { win, content, close }.
export const ui = {
  select(items, opts = {}) {
    const content = new PickerContent(items || [], opts);
    // Window reads only the presentation keys it knows; the picker keys (format, onAccept, …)
    // ride along on opts harmlessly.
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
