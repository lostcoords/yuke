// yuke:ui — the widget kit built on yuke:core. Retained widgets in the lite-xl model:
// List and (later) Window are classes you subclass or patch; ui.select will be a swappable
// method on the exported `ui` object. Editor policy stays in yuke:core; presentation lives here.
import { term } from "yuke:term";
import { text, fill, clip, wrap, root, strokeOf, style } from "yuke:core";

// The kit seeds its own highlight groups over the core palette — presentation lives with the
// widgets, not in core. A theme overrides these by mutating style.groups then invalidating.
Object.assign(style.groups, {
  UIPanel: { fg: "fg", bg: "bg" },
  UIBorder: { fg: "muted", bg: "bg" },
  UITitle: { fg: "accent", bold: true },
  UIItem: { fg: "fg" },
  UIItemSel: { fg: "fg", bg: "sel" },
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

// The base letter of a shifted char event, or "" if not one. Kitty sets the Shift modifier;
// a legacy terminal just uppercases the char — either way, distinguishes G from g after strokeOf folds them together.
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

// A scrollable, selectable list rendered into a caller-assigned rect. Items are opaque
// values; `format(item, i)` maps each to a display row and `key(item)` gives a stable
// identity, so the selection follows its item across a re-sorted `items` rather than sliding
// onto whatever now sits at the old index (lite-xl selects by identity, not ordinal).
//
// opts: { items, format, key, isSelectable, onMove, group, selGroup, dimGroup, dimSelGroup }
// format returns a string, or { text, right?, group?, selGroup?, rightGroup?, rightSelGroup? }.
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

  // Bring the selected row into view, then clamp — lite-xl's scroll_to_make_visible.
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

// A vertical pager over pre-wrapped visual rows. Rows are a derived projection of some source at
// the current width; the owner rebuilds them and calls setRows. Scroll is a row offset; `stuck`
// follows the tail (chat behavior), and a re-wrap re-anchors on the top row's `key` so the view
// does not jump. A row is { text, group?, key?, bg?, marker?, markerGroup?, indent? }: bg fills
// the row, marker paints at the left edge, and text is drawn indented past it — all optional.
export class Pager {
  constructor() {
    this.rows = [];
    this.scroll = 0;
    this.stuck = true; // follow the bottom
    this._h = 0; // last drawn height
    this._gPending = false; // a g awaiting its pair (gg = top)
  }

  _maxScroll() {
    return Math.max(0, this.rows.length - this._h);
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

  // Replace the rows. Following the tail snaps to bottom; otherwise keep the top row's `key` in
  // place across the re-wrap, landing on the first row that carries it.
  setRows(rows) {
    const anchor = this.stuck || !this.rows[this.scroll] ? null : this.rows[this.scroll].key;
    this.rows = rows;

    if (this.stuck) {
      this.toBottom();
      return;
    }

    if (anchor != null) {
      const i = rows.findIndex((r) => r.key === anchor);
      if (i >= 0) this.scroll = i;
    }
    this.scroll = Math.min(Math.max(0, this.scroll), this._maxScroll());
  }

  draw(rect) {
    const { x, y, w, h } = rect;
    this._h = h;
    if (this.stuck) this.scroll = this._maxScroll();

    for (let row = 0; row < h; row++) {
      const r = this.rows[this.scroll + row];
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

// Renders an ordered message list into a Pager. Messages mirror a subset of the wire shapes:
// { type:"user"|"assistant", id, rev, content:[{ type:"text", text }] }. Text parts wrap to the
// content width; wrapped rows are cached per message keyed by (rev, width) so a streaming delta
// re-wraps only its own message. Non-text parts are not rendered yet.
export class Transcript {
  constructor() {
    this.messages = [];
    this.pager = new Pager();
    this._width = -1;
    this._cache = new WeakMap(); // msg -> { rev, width, rows }; keeps view cache off the data
  }

  setMessages(messages) {
    this.messages = messages || [];
    this._relayout();
  }

  // A streaming delta bumped a message's rev; rebuild on the next layout.
  touch() {
    this._relayout();
  }

  _relayout() {
    if (this._width > 0) this._layout(this._width);
  }

  // Wrapped rows for one message, cached by (rev, width). The key is baked in so _layout can
  // push the cached rows straight into the flat array with no per-row allocation.
  _messageRows(msg, width) {
    const hit = this._cache.get(msg);
    if (hit && hit.rev === msg.rev && hit.width === width) return hit.rows;

    const user = msg.type === "user";
    const contentW = Math.max(1, width - TX_GUTTER);
    const group = user ? "TxUser" : "TxText";
    const bg = user ? "TxUser" : null;
    const key = msg.id;

    const body = [];
    for (const part of msg.content || []) {
      if (part.type !== "text") continue;
      for (const line of wrap(part.text, contentW)) body.push(line);
    }
    if (body.length === 0) body.push("");

    const rows = body.map((line, i) => ({ text: line, group, bg, indent: TX_GUTTER, marker: user && i === 0 ? "⟩" : null, markerGroup: "TxUserMarker", key }));
    rows.push({ text: "", key }); // separator, no band

    this._cache.set(msg, { rev: msg.rev, width, rows });
    return rows;
  }

  _layout(width) {
    this._width = width;
    const rows = [];
    for (const msg of this.messages) {
      const mr = this._messageRows(msg, width);
      for (let i = 0; i < mr.length; i++) rows.push(mr[i]);
    }
    this.pager.setRows(rows);
  }

  draw(rect) {
    if (rect.w !== this._width) this._layout(rect.w);
    this.pager.draw(rect);
  }

  onKey(ev) {
    return this.pager.onKey(ev);
  }
}

// Border glyph sets, keyed by name. Extend by adding an entry (each is 8 corner/edge glyphs).
export const borders = {
  single: { tl: "┌", t: "─", tr: "┐", r: "│", br: "┘", b: "─", bl: "└", l: "│" },
  rounded: { tl: "╭", t: "─", tr: "╮", r: "│", br: "╯", b: "─", bl: "╰", l: "│" },
  double: { tl: "╔", t: "═", tr: "╗", r: "║", br: "╝", b: "═", bl: "╚", l: "║" },
};

// A floating, bordered, titled window centered over the screen — a layer for the overlay
// stack. It owns its rect, paints panel + border + title/footer, and exposes the interior
// through winText/winFill, which clip to the inner rect (the host clips only to the terminal).
// Subclass and override drawContent(win) to fill it, or set a `content` with its own draw(win).
//
// opts: { name, title, footer, title_pos, footer_pos, border, width, height, modal,
//         panelGroup, borderGroup, titleGroup, footerGroup }
// border is a name in `borders`, a custom 8-glyph set, or "none"/null for a borderless panel.
// width/height are cells, a ratio in (0,1], or a function(max) => cells; default 60%.
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

// The content of a picker window: a List plus accept/cancel/validate and an optional
// per-instance keymap. Named default actions (accept/cancel/next/prev/top/bottom/close) can
// be rebound or disabled through `keymap`. onAccept receives the original item, not a row.
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

// The widget kit's public surface. `select` is a swappable method (a plugin may replace
// ui.select wholesale, e.g. to add fuzzy matching) as long as it honors { format, onAccept,
// onCancel }. Items are opaque; `format(item)` is display-only; onAccept gets the item.
//
// opts: { title, footer, title_pos, footer_pos, border, width, height, format, key,
//         isSelectable, onMove, onAccept, onCancel, validate, keymap, needsTick, *Group }
// Returns { win, content, close }.
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
};
