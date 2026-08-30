// yuke:ui — the widget kit over yuke:core. List/Pager/Window are classes to subclass or patch.
// `ui` exports the pickers. Editor policy lives in yuke:core; presentation lives here.
import { term } from "yuke:term";
import { text, fill, clip, root, strokeOf, modalKey, TextInput, caretCol, caretAtCol, caretRowCol, wrapOffsets, nextGrapheme, takePrefix, armPrefix, style, config, isWheel } from "yuke:core";
import { Document, isLinear } from "yuke:md";

/** @typedef {{ fg?: string, bg?: string, link?: string, bold?: boolean, dim?: boolean, italic?: boolean, reverse?: boolean, underline?: boolean }} StyleGroup */
/** @typedef {{ x: number, y: number, w: number, h: number }} Rect */
/** @typedef {string | number} ItemKey */
/** @typedef {string | number | object} ListKey */
/** @typedef {{ text?: string, group?: string, lines?: ListItem[], right?: string, rightGroup?: string, rightSelGroup?: string, marker?: string | null, markerGroup?: string, markerSelGroup?: string, indent?: number, selGroup?: string }} ListItem */
/** @typedef {{ type: "mouse", col: number, row: number, button: string, event: string, mods: number, count: number }} MouseEvent */
/** @typedef {{ text: string, group: string, src?: number, srcEnd?: number, mark?: boolean }} Segment */
/** @typedef {{ segments?: Segment[] | undefined, text?: string | undefined, group?: string | undefined, bg?: string | undefined, marker?: string | null | undefined, markerGroup?: string | undefined, indent?: number | undefined, key?: ItemKey | undefined, kind?: string | undefined, partId?: number | undefined, sel?: { from: number, to: number } | undefined, selGroup?: string | undefined }} TranscriptRow */
/** @typedef {{ rowCount: (width: number) => number, rows: (width: number, top: number, height: number) => TranscriptRow[] }} RowSource */
/** @typedef {{ id: number, type: "user" | "assistant" | "compaction", error?: { type: string, message: string } }} MessageDescriptor */
/** @typedef {{ id: number, row: number, col: number }} Position */
/** @typedef {{ anchor: Position, cursor: Position }} Selection */
/** @typedef {{ id: number, partId: number, kind: string }} PartHit */
/** @typedef {{ a: { id: number, off: number, was: string }, b: { id: number, off: number, was: string } }} SelectionAnchors */
/** @typedef {{ start: Position, end: Position, si: number, ei: number }} SelectionRange */
/** @typedef {{ w: number, rows: TranscriptRow[], source: string, blocks: { kind: string, at: number, end: number }[] | null }} RowCache */
/** @typedef {{ id: number, lang: string, text: string }} CodeBlock */
/** @typedef {{ textOf?: ((id: number) => string) | undefined, partsOf?: ((id: number) => readonly Wire.AssistantPart[]) | null | undefined, onSelect?: ((text: string) => void) | null | undefined, empty?: (() => readonly (string | { text?: unknown, group?: string })[] | null) | null | undefined }} TranscriptOptions */
/** @typedef {{ start: number, end: number, label: string }} PasteSpan */
/** @typedef {{ span: PasteSpan, start: number, end: number, delta: number }} ProjectionPart */
/** @typedef {{ text: string, parts: ProjectionPart[] }} Projection */
/** @typedef {{ start: number, end: number, soft: boolean }} WrapRow */
/** @typedef {{ prompt?: string | undefined, placeholder?: string | undefined, onSubmit?: ((text: string) => boolean | void) | null | undefined, maxRows?: number | undefined }} ComposerOptions */
/** @typedef {{ textOf?: ((id: number) => string) | undefined, partsOf?: ((id: number) => readonly Wire.AssistantPart[]) | null | undefined, onSelect?: ((text: string) => void) | null | undefined, onSubmit?: ((text: string) => boolean | void) | null | undefined, empty?: (() => readonly (string | { text?: unknown, group?: string })[] | null) | null | undefined }} ChatViewOptions */
/** @typedef {{ tl: string, t: string, tr: string, r: string, br: string, b: string, bl: string, l: string }} BorderSet */
/** @typedef {"none" | "single" | "rounded" | "double" | BorderSet} Border */
/** @typedef {number | ((max: number) => number)} Dimension */
/** @typedef {{ draw?: (win: Window) => void, cursor?: (win: Window) => { x: number, y: number, visible: boolean } | null, onKey?: (ev: HostEvent) => boolean, onMouse?: (ev: MouseEvent) => boolean, needsTick?: () => { periodMs: number } | null, tick?: () => void }} WindowContent */
/** @typedef {{ name?: string, modal?: boolean, border?: Border, content?: WindowContent | null, width?: Dimension, height?: Dimension, panelGroup?: string, borderGroup?: string, title?: string | (() => string), title_pos?: "left" | "center" | "right", titleGroup?: string, footer?: string | (() => string), footer_pos?: "left" | "center" | "right", footerGroup?: string }} WindowOptions */
/** @template T @typedef {{ items?: T[] | undefined, format?: ((item: T, index: number) => string | ListItem) | undefined, key?: ((item: T) => ListKey) | undefined, isSelectable?: ((item: T) => boolean) | undefined, onMove?: ((item: T, index: number) => void) | null | undefined, itemHeight?: number | undefined, group?: string | undefined, selGroup?: string | undefined, dimGroup?: string | undefined, dimSelGroup?: string | undefined, drawCursor?: boolean | undefined }} ListOptions */
/** @template T @typedef {{ items?: T[] | undefined, suggest?: (query: string) => T[] | undefined, filterText?: ((item: T) => string) | undefined, format?: ((item: T, index: number) => string | ListItem) | undefined, key?: ((item: T) => ListKey) | undefined, isSelectable?: ((item: T) => boolean) | undefined, onMove?: ((item: T, index: number) => void) | null | undefined, itemGroup?: string | undefined, selGroup?: string | undefined, itemHeight?: number | undefined, onAccept?: ((item: T, index?: number) => void) | null | undefined, onCancel?: (() => void) | null | undefined, validate?: ((item: T) => boolean) | null | undefined, keymap?: Record<string, string | false | ((ev: HostEvent, content: PickerContent<T>) => void)> | null | undefined, closeOnAccept?: boolean | undefined, needsTick?: { periodMs: number } | null | undefined } & WindowOptions} PickOptions */
/** @template T @typedef {{ format?: ((item: T, index: number) => string | ListItem) | undefined, key?: ((item: T) => ListKey) | undefined, isSelectable?: ((item: T) => boolean) | undefined, onMove?: ((item: T, index: number) => void) | null | undefined, itemGroup?: string | undefined, selGroup?: string | undefined, itemHeight?: number | undefined, onAccept?: ((item: T, index: number) => void) | null | undefined, onCancel?: (() => void) | null | undefined, validate?: ((item: T) => boolean) | null | undefined, keymap?: Record<string, string | false | ((ev: HostEvent, content: PickerContent<T>) => void)> | null | undefined, closeOnAccept?: boolean | undefined, needsTick?: { periodMs: number } | null | undefined } & WindowOptions} SelectOptions */
/** @typedef {{ pending: string }} Chord */

// The kit adds its highlight groups to the core palette. It adds only a group that is absent, so a
// theme that set one first keeps it, and a second import does not re-seed.
const UI_GROUPS = /** @type {Record<string, StyleGroup>} */ ({
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
  // Tool rows stay monochrome: weight and dim, danger only for a failed call.
  TxToolName: { fg: "fg", bold: true },
  TxToolMeta: { fg: "fg", dim: true },
  TxToolError: { fg: "danger", bold: true },
  TxToolBody: { fg: "fg", dim: true },
  TxToolAdd: { fg: "fg", bold: true },
  TxToolDel: { fg: "fg", dim: true },
  TxToolContext: { fg: "fg", dim: true },
  TxThought: { fg: "fg", dim: true, italic: true },
});
let seededGroups = false;
for (const name in UI_GROUPS) {
  if (!(name in style.groups)) {
    style.groups[name] = /** @type {StyleGroup} */ (UI_GROUPS[name]);
    seededGroups = true;
  }
}
if (seededGroups) style.invalidate();

// Default page jump before a draw sets the real page height.
const PAGE_FALLBACK = 10;

// Left gutter for a transcript row marker; the body indents past it.
const TX_GUTTER = 2;
// Keep a long tool body inside the pager. The replica still holds the full output.
const TOOL_BODY_CAP = 40;

/** @param {unknown} a @param {unknown} b @returns {boolean} */
function sameId(a, b) {
  return a != null && b != null && String(a) === String(b);
}

// The shared nav vocabulary: j/k move, ctrl+d/u page, gg/G top/bottom.
/** @param {string} k @returns {"down" | "up" | "page_down" | "page_up" | "top" | "bottom" | "pending_g" | ""} */
function navAction(k) {
  switch (k) {
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
    case "G":
      return "bottom";
    case "g":
      return "pending_g";
  }
  return "";
}

/** @param {Chord} chord @param {Extract<HostEvent, { type: "key" }>} ev @param {Record<string, () => void>} map @returns {boolean} */
function applyNav(chord, ev, map) {
  const k = modalKey(ev);
  const first = takePrefix(chord);
  const act = first === "g" && k === "g" ? "top" : navAction(k);
  if (act === "pending_g") {
    armPrefix(chord, "g");
    return true;
  }
  const fn = map[act];
  if (!fn) return false;
  fn();
  return true;
}

// A scrollable, selectable list. `key(item)` gives a stable identity, so the selection follows its
// item across a re-sorted `items`. `itemHeight` rows render per item; `format` may return `lines`.
/** @template T */
export class List {
  /** @param {ListOptions<T>} [opts] */
  constructor(opts = {}) {
    this.format = opts.format || ((it) => ({ text: String(it) }));
    this.key = opts.key || /** @type {(item: T) => ListKey} */ ((it) => it);
    this.isSelectable = opts.isSelectable || (() => true);
    this.onMove = opts.onMove || null;
    this.itemHeight = Math.max(1, opts.itemHeight || 1);

    this.group = opts.group || "UIItem";
    this.selGroup = opts.selGroup || "UIItemSel";
    this.dimGroup = opts.dimGroup || "UIDim";
    this.dimSelGroup = opts.dimSelGroup || "UIDimSel";

    this.drawCursor = opts.drawCursor !== false; // an unfocused list can hide its cursor
    /** @type {Rect | null} */
    this._rect = null; // the last drawn rect, for the click hit test
    /** @type {ListKey | null} */
    this.selectedKey = null;
    this.scroll = 0; // first visible item index
    this._page = PAGE_FALLBACK; // last visible item count, for page moves
    /** @type {Chord} */
    this._chord = { pending: "" };
    this.setItems(opts.items || []);
  }

  // Visible item count for a pixel height.
  /** @param {number} h @returns {number} */
  _visible(h) {
    return Math.max(1, Math.floor(h / this.itemHeight));
  }

  /** @param {T[]} items @returns {void} */
  setItems(items) {
    /** @type {T[]} */
    this.items = items || [];
    this._ensureSelection();
    this._clampScroll(this._page);
  }

  // Put the cursor on the item that `k` names. Return false when the list holds no such item.
  /** @param {ListKey | null | undefined} k @returns {boolean} */
  selectKey(k) {
    if (k == null) return false;
    for (const it of this.items) {
      if (!this.isSelectable(it) || this.key(it) !== k) continue;
      this.selectedKey = k;
      return true;
    }
    return false;
  }

  /** @returns {number[]} */
  _selectable() {
    const out = [];
    for (let i = 0; i < this.items.length; i++) {
      const item = /** @type {T} */ (this.items[i]);
      if (this.isSelectable(item)) out.push(i);
    }
    return out;
  }

  /** @returns {number} */
  _selIndex() {
    if (this.selectedKey == null) return -1;
    for (let i = 0; i < this.items.length; i++) {
      const item = /** @type {T} */ (this.items[i]);
      if (this.isSelectable(item) && this.key(item) === this.selectedKey) return i;
    }
    return -1;
  }

  /** @returns {void} */
  _ensureSelection() {
    if (this._selIndex() >= 0) return;
    const sel = this._selectable();
    if (sel.length) {
      const index = /** @type {number} */ (sel[0]);
      this.selectedKey = this.key(/** @type {T} */ (this.items[index]));
    } else {
      this.selectedKey = null;
    }
  }

  /** @returns {T | null} */
  selected() {
    const i = this._selIndex();
    return i < 0 ? null : /** @type {T} */ (this.items[i]);
  }

  /** @returns {number} */
  selectedIndex() {
    return this._selIndex();
  }

  /** @param {number} h @returns {void} */
  ensureVisible(h) {
    const vis = this._visible(h);
    this._page = vis;
    this._scrollToVisible(vis);
  }

  /** @param {number} delta @returns {void} */
  move(delta) {
    const sel = this._selectable();
    if (sel.length === 0) return;
    let pos = sel.indexOf(this._selIndex());
    pos = pos < 0 ? 0 : Math.min(Math.max(pos + delta, 0), sel.length - 1);
    const index = /** @type {number} */ (sel[pos]);
    const item = /** @type {T} */ (this.items[index]);
    this.selectedKey = this.key(item);
    if (this.onMove) this.onMove(item, index);
  }

  /** @param {number} dir @returns {void} */
  moveToEdge(dir) {
    this.move(dir < 0 ? -this.items.length : this.items.length);
  }

  /** @param {number} vis @returns {void} */
  _scrollToVisible(vis) {
    const i = this._selIndex();
    if (i >= 0 && vis > 0) {
      if (i < this.scroll) this.scroll = i;
      else if (i >= this.scroll + vis) this.scroll = i - vis + 1;
    }
    this._clampScroll(vis);
  }

  /** @param {number} vis @returns {void} */
  _clampScroll(vis) {
    const max = Math.max(0, this.items.length - Math.max(1, vis));
    this.scroll = Math.min(Math.max(this.scroll, 0), max);
  }

  /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
  onKey(ev) {
    return applyNav(this._chord, ev, {
      down: () => this.move(1),
      up: () => this.move(-1),
      page_down: () => this.move(this._page),
      page_up: () => this.move(-this._page),
      top: () => this.moveToEdge(-1),
      bottom: () => this.moveToEdge(1),
    });
  }

  // Forget the drawn rect. A container calls this when it draws something else in the same space,
  // so a click cannot hit a row that left the screen.
  /** @returns {void} */
  clearRect() {
    this._rect = null;
  }

  // A wheel step moves the cursor, because `draw` always scrolls the selection back into view.
  // A left press selects the row under the pointer.
  /** @param {MouseEvent} ev @returns {boolean} */
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
    if (i < 0 || i >= this.items.length) return false;
    const item = /** @type {T} */ (this.items[i]);
    if (!this.isSelectable(item)) return false;
    this.selectedKey = this.key(item);
    if (this.onMove) this.onMove(item, i);
    return true;
  }

  // Paint into rect { x, y, w, h }. A selected item fills all its rows; each item draws up to
  // `itemHeight` lines. Every row repaints each frame, so `format` may be dynamic.
  /** @param {Rect} rect @returns {void} */
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

      const it = /** @type {T} */ (this.items[i]);
      const sy = y + row * this.itemHeight;
      // Clamp to the rect so a tall item in a short pane does not paint past it.
      const drawH = Math.min(this.itemHeight, y + h - sy);
      if (drawH <= 0) break;
      const isSel = this.drawCursor && this.isSelectable(it) && this.key(it) === this.selectedKey;
      const cell = normalizeCell(this.format(it, i));

      if (isSel) fill(x, sy, w, drawH, this.selGroup);

      const lines = cell.lines || [cell];
      for (let ln = 0; ln < drawH && ln < lines.length; ln++) {
        this._drawLine(x, sy + ln, w, /** @type {ListItem} */ (lines[ln]), isSel);
      }
    }
  }

  /** @param {number} x @param {number} sy @param {number} w @param {string | ListItem} spec @param {boolean} isSel @returns {void} */
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
      text(x, sy, spec.marker, /** @type {string} */ (mg));
    }
    const ind = spec.indent || 0;
    const g = isSel ? spec.selGroup || this.selGroup : spec.group || this.group;
    text(x + ind, sy, clip(/** @type {string} */ (spec.text), Math.max(0, avail - ind)), g);
  }
}

// A row from `format` may be a bare string or a record; fold both into one shape.
/** @param {string | ListItem | null | undefined} cell @returns {ListItem} */
function normalizeCell(cell) {
  if (cell == null) return { text: "" };
  if (typeof cell === "string") return { text: cell };
  return { text: cell.text != null ? String(cell.text) : "", ...cell };
}

// A vertical pager over a row source — { rowCount(width), rows(width, top, height) } — so the source
// can virtualize. `stuck` follows the tail. A row is { text | segments, bg, marker, indent, … }.
export class Pager {
  constructor() {
    /** @type {RowSource} */
    this.source = staticRowSource([]);
    this.scroll = 0;
    this.stuck = true;
    this._h = 0;
    this._w = 0;
    /** @type {Rect | null} */
    this._rect = null; // the last drawn rect, for the mouse hit test
    /** @type {Chord} */
    this._chord = { pending: "" };
  }

  /** @returns {Rect | null} */
  rect() {
    return this._rect;
  }

  /** @returns {void} */
  clearRect() {
    this._rect = null;
  }

  // The source row index under screen row `y`. Return -1 outside the drawn rows.
  /** @param {number} y @returns {number} */
  rowAtY(y) {
    const r = this._rect;
    if (!r || y < r.y || y >= r.y + r.h) return -1;
    const i = this.scroll + (y - r.y);
    return i < this._total() ? i : -1;
  }

  /** @returns {number} */
  _total() {
    return this.source.rowCount(this._w);
  }

  /** @returns {number} */
  _maxScroll() {
    return Math.max(0, this._total() - this._h);
  }

  /** @returns {boolean} */
  atBottom() {
    return this.scroll >= this._maxScroll();
  }

  /** @returns {void} */
  toBottom() {
    this.scroll = this._maxScroll();
    this.stuck = true;
  }

  /** @returns {void} */
  toTop() {
    this.scroll = 0;
    this.stuck = false;
  }

  /** @param {number} delta @returns {void} */
  scrollBy(delta) {
    this.scroll = Math.min(Math.max(0, this.scroll + delta), this._maxScroll());
    this.stuck = this.atBottom();
  }

  // Scroll the least amount that puts row `index` on the screen.
  // Refresh `stuck` even when the offset is unchanged, so an unfold cannot jump to the tail.
  /** @param {number} index @returns {void} */
  scrollIntoView(index) {
    if (index < 0 || this._h <= 0) return;
    let next = this.scroll;
    if (index < next) next = index;
    else if (index >= next + this._h) next = index - this._h + 1;
    this.scroll = Math.min(Math.max(0, next), this._maxScroll());
    this.stuck = this.atBottom();
  }

  /** @param {RowSource} source @returns {void} */
  setSource(source) {
    this.source = source || staticRowSource([]);
  }

  /** @param {TranscriptRow[]} rows @returns {void} */
  setRows(rows) {
    this.setSource(staticRowSource(rows));
    this._clamp();
  }

  // Keep the scroll offset in range as the row count changes. A scroll to the tail re-sticks.
  /** @returns {void} */
  _clamp() {
    this.scroll = Math.min(Math.max(0, this.scroll), this._maxScroll());
    if (this.stuck) this.scroll = this._maxScroll();
    else if (this.atBottom()) this.stuck = true;
  }

  /** @param {Rect} rect @returns {void} */
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
      if (r.marker) text(x, sy, r.marker, /** @type {string} */ (r.markerGroup));
      const ind = r.indent || 0;
      let segs = rowSegments(r);
      if (segs && r.sel) segs = markSelection(segs, r.sel.from, r.sel.to, r.selGroup || "TxSelect");
      if (segs) drawSegments(x + ind, sy, Math.max(0, w - ind), segs);
    }
  }

  /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
  onKey(ev) {
    const page = Math.max(1, this._h - 1);
    return applyNav(this._chord, ev, {
      down: () => this.scrollBy(1),
      up: () => this.scrollBy(-1),
      page_down: () => this.scrollBy(page),
      page_up: () => this.scrollBy(-page),
      top: () => this.toTop(),
      bottom: () => this.toBottom(),
    });
  }

  // The wheel scrolls by `config.mouse.scrollLines`. The protocol has no pixel wheel, so the step
  // is a line count. `ev.count` holds the steps the owner folded into this event.
  /** @param {MouseEvent} ev @returns {boolean} */
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
/** @param {TranscriptRow} r @returns {Segment[] | null} */
function rowSegments(r) {
  if (r.segments) return r.segments;
  return r.text ? [{ text: r.text, group: /** @type {string} */ (r.group) }] : null;
}

// The plain text of a row, without the indent. A selection indexes into this string.
/** @param {TranscriptRow} r @returns {string} */
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
/** @param {TranscriptRow} row @param {number} from @param {number} to @returns {{ from: number, to: number } | null} */
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
    if (seg.src != null && (b > a || (seg.text.length === 0 && from <= at && at <= to))) {
      const linear = isLinear(seg);
      const s = linear && b > a ? seg.src + (a - at) : seg.src;
      const e = linear && b > a ? seg.src + (b - at) : /** @type {number} */ (seg.srcEnd);
      if (lo < 0 || s < lo) lo = s;
      if (e > hi) hi = e;
    }
    at = end;
  }
  return lo < 0 ? null : { from: lo, to: hi };
}

// The source offset at caret column `col`. A column in a gap, such as a wrap space, takes the end
// of the source before it. Return -1 when the row carries no source at all.
/** @param {TranscriptRow} row @param {number} col @returns {number} */
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
      last = /** @type {number} */ (seg.srcEnd);
    }
    at = end;
  }
  return last;
}

// Repaint the string range [from, to) of `segments` with `group`. The bounds come from
// `caretAtCol`, so they always land on a grapheme edge.
/** @param {Segment[]} segments @param {number} from @param {number} to @param {string} group @returns {Segment[]} */
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
/** @param {number} x @param {number} sy @param {number} w @param {Segment[]} segments @returns {void} */
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
  text(x + room, sy, "…", /** @type {string} */ (cutGroup));
}

// A fixed-array row source (width-independent), for the pickers and tests.
/** @param {TranscriptRow[]} list @returns {RowSource} */
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
/** @param {ItemKey} id @param {string} body @param {number} width @param {string} group @returns {TranscriptRow[]} */
function wrapPlain(id, body, width, group) {
  const src = body || "";
  const contentW = Math.max(1, width - TX_GUTTER);
  /** @type {TranscriptRow[]} */
  const rows = wrapOffsets(src, contentW).map((r) => ({
    segments: [{ text: src.slice(r.start, r.end), group, src: r.start, srcEnd: r.end }],
    indent: TX_GUTTER,
    key: id,
    kind: "compaction",
  }));
  rows.push({ text: "", key: id });
  return rows;
}

/** @param {ItemKey} id @param {string} body @param {number} width @returns {TranscriptRow[]} */
function userRows(id, body, width) {
  const src = body || "";
  const contentW = Math.max(1, width - TX_GUTTER);
  const lines = wrapOffsets(src, contentW);
  /** @type {TranscriptRow[]} */
  const rows = lines.map((r, i) => ({
    segments: [{ text: src.slice(r.start, r.end), group: "TxUser", src: r.start, srcEnd: r.end }],
    bg: "TxUser",
    indent: TX_GUTTER,
    marker: i === 0 ? "⟩" : null,
    markerGroup: "TxUserMarker",
    key: id,
  }));
  rows.push({ text: "", key: id });
  return rows;
}

/** @param {Segment[] | undefined} segments @param {number} base @returns {Segment[] | undefined} */
function shiftSrc(segments, base) {
  if (!segments || !base) return segments;
  return segments.map((seg) => (seg.src == null ? seg : { ...seg, src: seg.src + base, srcEnd: /** @type {number} */ (seg.srcEnd) + base }));
}

/** @param {string} src @param {number} width @param {string} group @returns {TranscriptRow[]} */
function wrapBody(src, width, group) {
  src = src || "";
  const contentW = Math.max(1, width);
  return wrapOffsets(src, contentW).map((r) => ({
    segments: [{ text: src.slice(r.start, r.end), group, src: r.start, srcEnd: r.end }],
    indent: TX_GUTTER,
  }));
}

/** @param {TranscriptRow[]} rows @param {number} cap @returns {TranscriptRow[]} */
function capRows(rows, cap) {
  if (rows.length <= cap) return rows;
  const head = Math.floor((cap - 1) / 2);
  const tail = cap - 1 - head;
  return rows.slice(0, head).concat([{ text: "…", group: "TxToolMeta", indent: TX_GUTTER }], rows.slice(rows.length - tail));
}

/** @param {string} args @returns {string} */
function toolSummary(args) {
  try {
    const o = JSON.parse(args);
    if (o && typeof o === "object") {
      if (typeof o.path === "string") return o.path;
      if (typeof o.command === "string") return o.command;
    }
  } catch (_) {}
  const s = String(args || "");
  return s.length > 48 ? s.slice(0, 47) + "…" : s;
}

/** @param {Wire.ToolState | null | undefined} state @returns {Wire.ToolState["type"]} */
function toolStateKind(state) {
  return state && state.type ? state.type : "pending";
}

/** @param {Wire.ToolState | null | undefined} state @returns {string} */
function toolStateLabel(state) {
  const t = toolStateKind(state);
  if (t === "completed") return "done";
  if (t === "waiting_permission") return "need permission";
  return t;
}

/** @param {Wire.ToolState | null | undefined} state @returns {boolean} */
function defaultExpanded(state) {
  const t = toolStateKind(state);
  return t === "running" || t === "error" || t === "denied" || t === "canceled";
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @returns {string} */
function toolHeaderSource(part) {
  const name = String(part.name || "tool");
  const summary = toolSummary(part.arguments);
  return summary ? name + " " + summary : name;
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @param {boolean} expanded @param {number} width @returns {TranscriptRow} */
function toolHeaderRow(part, expanded, width) {
  const name = String(part.name || "tool");
  const summary = toolSummary(part.arguments);
  const state = part.state || {};
  const kind = toolStateKind(state);
  const duration = /** @type {{ duration_ms?: number }} */ (state);
  const right = toolStateLabel(state) + (duration.duration_ms != null ? " · " + duration.duration_ms + "ms" : "");
  const err = kind === "error" || kind === "denied";
  const contentW = Math.max(1, width);
  const rightW = term.measure(right);
  const leftW = Math.max(1, contentW - (rightW > 0 ? rightW + 1 : 0));
  const segs = /** @type {Segment[]} */ ([]);
  const nameT = clip(name, leftW);
  segs.push({ text: nameT, group: "TxToolName", src: 0, srcEnd: name.length });
  let used = term.measure(nameT);
  if (summary && used + 1 < leftW) {
    const t = clip(summary, leftW - used - 1);
    segs.push({ text: " " + t, group: "TxToolMeta", src: name.length, srcEnd: name.length + 1 + summary.length });
    used += 1 + term.measure(t);
  }
  if (rightW > 0 && used + 1 + rightW <= contentW) {
    segs.push({ text: " ".repeat(contentW - used - rightW), group: "TxToolMeta" });
    segs.push({ text: right, group: err ? "TxToolError" : "TxToolMeta" });
  }
  return {
    segments: segs,
    indent: TX_GUTTER,
    marker: expanded ? "▾" : "▸",
    markerGroup: "TxToolMeta",
    kind: "tool-header",
    partId: part.id,
  };
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @returns {string} */
function toolBodyText(part) {
  const s = part.state || {};
  if (s.type === "error") return s.error || "";
  if (s.type === "denied") return s.reason || "";
  const output = /** @type {{ output?: string }} */ (s);
  if (output.output) return output.output;
  return "";
}

/** @param {Extract<Wire.View, { type: "diff" }>} view @param {number} width @returns {{ rows: TranscriptRow[], source: string }} */
function diffRows(view, width) {
  const rows = /** @type {TranscriptRow[]} */ ([]);
  let source = "";
  for (const f of view.files || []) {
    if (f.path) {
      if (source) source += "\n";
      const base = source.length;
      source += f.path;
      rows.push({
        segments: [{ text: f.path, group: "TxToolName", src: base, srcEnd: base + f.path.length }],
        indent: TX_GUTTER,
      });
    }
    for (const h of f.hunks || []) {
      for (const line of h.lines || []) {
        if (source) source += "\n";
        const base = source.length;
        source += line;
        const mark = line[0];
        const group = mark === "+" ? "TxToolAdd" : mark === "-" ? "TxToolDel" : "TxToolContext";
        for (const r of wrapBody(line, width, group)) {
          rows.push({ ...r, segments: shiftSrc(r.segments, base) });
        }
      }
    }
  }
  return { rows, source };
}

/** @param {readonly Wire.View[]} views @param {number} width @returns {{ rows: TranscriptRow[], source: string }} */
function viewRows(views, width) {
  const rows = /** @type {TranscriptRow[]} */ ([]);
  let source = "";
  for (const v of views || []) {
    if (source) source += "\n";
    const base = source.length;
    const t = v && v.type;
    if (t === "diff") {
      const built = diffRows(/** @type {Extract<Wire.View, { type: "diff" }>} */ (v), width);
      source += built.source;
      for (const r of built.rows) rows.push({ ...r, segments: r.segments ? shiftSrc(r.segments, base) : r.segments });
    } else if (t === "markdown") {
      const doc = new Document();
      doc.setText(/** @type {Extract<Wire.View, { type: "markdown" }>} */ (v).text || "");
      const chunk = doc.sourceText();
      source += chunk;
      for (const r of doc.rows(Math.max(1, width))) {
        rows.push({ segments: shiftSrc(r.segments, base), indent: TX_GUTTER });
      }
    } else if (t === "image") {
      const label = "(image)";
      source += label;
      rows.push({ segments: [{ text: label, group: "TxToolMeta", src: base, srcEnd: base + label.length }], indent: TX_GUTTER });
    } else {
      const view = /** @type {{ text?: string }} */ (v);
      const body = v && view.text ? view.text : "";
      source += body;
      for (const r of wrapBody(body, width, "TxToolBody")) rows.push({ ...r, segments: shiftSrc(r.segments, base) });
    }
  }
  return { rows, source };
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @param {number} width @returns {{ rows: TranscriptRow[], source: string }} */
function toolBody(part, width) {
  const views = part.state && /** @type {{ view?: readonly Wire.View[] }} */ (part.state).view;
  if (views && views.length) return viewRows(views, width);
  const text = toolBodyText(part);
  const kind = toolStateKind(part.state);
  const group = kind === "error" || kind === "denied" ? "TxToolError" : "TxToolBody";
  return { rows: wrapBody(text, width, group), source: text };
}

/** @param {Extract<Wire.AssistantPart, { type: "reasoning" }>} part @param {number} width @param {boolean} expanded @param {boolean} live @param {Document | null} doc @returns {{ rows: TranscriptRow[], source: string }} */
function reasoningRows(part, width, expanded, live, doc) {
  const name = live ? "thinking" : "thought";
  const header = {
    segments: [{ text: name, group: "TxThought", src: 0, srcEnd: name.length }],
    indent: TX_GUTTER,
    marker: expanded ? "▾" : "▸",
    markerGroup: "TxThought",
    kind: "reasoning-header",
    partId: part.id,
  };
  const rows = /** @type {TranscriptRow[]} */ ([header]);
  let source = name;
  if (!expanded) return { rows, source };
  if (!doc) doc = new Document();
  doc.setText(part.text || "");
  const chunk = doc.sourceText();
  source += "\n" + chunk;
  const base = name.length + 1;
  const body = /** @type {TranscriptRow[]} */ ([]);
  for (const r of doc.rows(Math.max(1, width))) {
    body.push({
      segments: shiftSrc(r.segments, base),
      indent: TX_GUTTER,
      kind: "reasoning-body",
      partId: part.id,
    });
  }
  for (const r of capRows(body, TOOL_BODY_CAP)) rows.push(r);
  return { rows, source };
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @param {number} width @param {boolean} expanded @returns {{ rows: TranscriptRow[], source: string }} */
function toolRows(part, width, expanded) {
  const header = toolHeaderRow(part, expanded, width);
  const headerSrc = toolHeaderSource(part);
  const rows = /** @type {TranscriptRow[]} */ ([header]);
  let source = headerSrc;
  if (!expanded) return { rows, source };
  const body = toolBody(part, width);
  const capped = capRows(body.rows, TOOL_BODY_CAP);
  if (body.source) {
    source += "\n" + body.source;
    const base = headerSrc.length + 1;
    for (const r of capped) {
      rows.push({
        ...r,
        kind: "tool-body",
        partId: part.id,
        segments: r.segments ? shiftSrc(r.segments, base) : r.segments,
      });
    }
  } else {
    for (const r of capped) rows.push({ ...r, kind: "tool-body", partId: part.id });
  }
  return { rows, source };
}

/** @param {{ type?: string, message?: string } | null | undefined} error @returns {string} */
function errorLabel(error) {
  return "⚠ " + ((error && error.message) || (error && error.type) || "run failed");
}

// Show a failed turn's error in the gutter with a warning marker and the danger color.
/** @param {ItemKey} id @param {{ type?: string, message?: string } | null | undefined} error @param {number} width @param {number} srcBase @returns {{ rows: TranscriptRow[], source: string }} */
function errorRows(id, error, width, srcBase) {
  const label = errorLabel(error);
  const base = srcBase || 0;
  const contentW = Math.max(1, width - TX_GUTTER);
  /** @type {TranscriptRow[]} */
  const rows = wrapOffsets(label, contentW).map((r) => ({
    segments: [{ text: label.slice(r.start, r.end), group: "TxError", src: base + r.start, srcEnd: base + r.end }],
    indent: TX_GUTTER,
    key: id,
    kind: "error",
  }));
  rows.push({ text: "", key: id });
  return { rows, source: label };
}

// A virtualized transcript (the Pager's row source). It holds descriptors ({id, type}) plus a
// wrapped-row cache. An assistant turn renders through yuke:md; only the streaming draft re-renders.
export class Transcript {
  /** @param {TranscriptOptions} [opts] */
  constructor(opts = {}) {
    this.textOf = opts.textOf || (() => "");
    this.partsOf = opts.partsOf || null;
    this.pager = new Pager();
    this.pager.setSource(this);
    /** @type {MessageDescriptor[]} */
    this._messages = []; // committed descriptors, oldest first
    /** @type {MessageDescriptor | null} */
    this._active = null; // the streaming draft descriptor, or null
    this._width = -1;
    /** @type {Map<number, RowCache>} */
    this._rows = new Map(); // id -> { w, rows, source?, blocks? }
    /** @type {Map<number, string>} */
    this._sources = new Map(); // id -> display source, survives row-cache drops
    /** @type {Map<number, Document>} */
    this._docs = new Map(); // id -> md Document, for the textOf path
    /** @type {Map<string, Document>} */
    this._partDocs = new Map(); // id:partId -> md Document, for text and reasoning parts
    /** @type {Map<string, boolean>} */
    this._expand = new Map(); // id:partId -> user override
    // A selection holds two logical positions, `{ id, row, col }`. `row` counts the rendered rows
    // of that message and `col` is a string index into the row text.
    /** @type {Selection | null} */
    this.selection = null;
    this._dragging = false;
    this._didDrag = false;
    /** @type {Position | null} */
    this._press = null;
    this.onSelect = opts.onSelect || null;
    // Lines to show while the transcript holds no message, so an empty pane still says something.
    this.empty = opts.empty || null;
  }

  /** @returns {void} */
  clearSelection() {
    this.selection = null;
    this._dragging = false;
    this._didDrag = false;
    this._press = null;
  }

  // Set both ends. `{ inclusive: true }` grows the later end by one grapheme, as vim visual does.
  /** @param {Position | null} anchor @param {Position | null} cursor @param {{ inclusive?: boolean } | null | undefined} [opts] @returns {void} */
  select(anchor, cursor, opts) {
    if (!anchor || !cursor) {
      this.clearSelection();
      return;
    }
    let a = anchor;
    let b = cursor;
    if (opts && opts.inclusive) {
      /** @param {Position} p @returns {Position} */
      const grow = (p) => {
        const body = this.rowTextAt(p.id, p.row);
        return { id: p.id, row: p.row, col: Math.min(nextGrapheme(body, p.col), body.length) };
      };
      if (this._cmpPos(b, a) >= 0) b = grow(b);
      else a = grow(a);
    }
    this.selection = { anchor: a, cursor: b };
  }

  /** @param {Position} a @param {Position} b @returns {number} */
  _cmpPos(a, b) {
    if (a.id !== b.id) return this._indexOf(a.id) - this._indexOf(b.id);
    return a.row !== b.row ? a.row - b.row : a.col - b.col;
  }

  // The pane draws something else in this space, so a click must not hit a row that left it.
  /** @returns {void} */
  hide() {
    this.pager.clearRect();
    this.clearSelection();
  }

  // Replace the outline. Rare (commit/resync/truncate); a re-commit can change content under a
  // stable id, so drop the caches. A user fold override stays if its message is still live.
  /** @param {MessageDescriptor[]} messages @param {MessageDescriptor | null} active @returns {void} */
  setOutline(messages, active) {
    this._messages = messages || [];
    this._active = active || null;
    this._rows.clear();
    this._docs.clear();
    this._sources.clear();
    const live = this._liveIds();
    this._pruneKeyed(this._partDocs, live);
    this._pruneKeyed(this._expand, live);
    this.clearSelection();
  }

  /** @returns {Set<string>} */
  _liveIds() {
    const live = new Set();
    for (const m of this._messages) live.add(String(m.id));
    if (this._active) live.add(String(this._active.id));
    return live;
  }

  /** @param {Map<string, unknown>} map @param {Set<string>} live @returns {void} */
  _pruneKeyed(map, live) {
    for (const k of [...map.keys()]) {
      const cut = String(k).indexOf(":");
      const id = cut < 0 ? String(k) : String(k).slice(0, cut);
      if (!live.has(id)) map.delete(k);
    }
  }

  /** @param {number} id @returns {void} */
  _dropRows(id) {
    this._rows.delete(id);
    /** @type {Map<number | string, RowCache>} */ (this._rows).delete(String(id));
  }

  // A streaming delta on draft `id`: adopt it if new, and drop its cached rows so it re-renders.
  /** @param {number} id @returns {void} */
  setActive(id) {
    // The draft rewraps as tokens arrive, but an append never moves the source before it.
    const sel = this.selection;
    const touches = !!sel && (sameId(sel.anchor.id, id) || sameId(sel.cursor.id, id));
    const anchors = touches ? this._anchors() : null;
    if (!this._active || !sameId(this._active.id, id)) this._active = { id, type: "assistant" };
    this._dropRows(id);
    if (touches) this._reanchor(anchors);
  }

  // A width change rewraps every row, so a row index means other text. The selection moves back to
  // the same source instead.
  /** @param {number} width @returns {void} */
  _invalidate(width) {
    if (width === this._width) return;
    const anchors = this._anchors();
    this._width = width;
    this._rows.clear();
    if (this.selection) this._reanchor(anchors);
  }

  /** @param {number} id @returns {string} */
  _sourceOf(id) {
    if (this._sources.has(id)) return /** @type {string} */ (this._sources.get(id));
    const c = this._rows.get(id);
    if (c && c.source != null) return c.source;
    const doc = this._docs.get(id);
    return doc ? doc.sourceText() : this.textOf(id);
  }

  // The selection as source offsets. Return null when either end carries no source.
  /** @returns {SelectionAnchors | null} */
  _anchors() {
    const sel = this.selection;
    if (!sel || this._width <= 0) return null;
    const a = this.sourceAt(sel.anchor);
    const b = this.sourceAt(sel.cursor);
    if (a < 0 || b < 0) return null;
    return {
      a: { id: sel.anchor.id, off: a, was: this._sourceOf(sel.anchor.id) },
      b: { id: sel.cursor.id, off: b, was: this._sourceOf(sel.cursor.id) },
    };
  }

  // An edit before the anchor moves the text under it, so the offset no longer names it.
  /** @param {{ id: number, off: number, was: string }} a @returns {Position | null} */
  _posAtAnchor(a) {
    if (this._sourceOf(a.id).slice(0, a.off) !== a.was.slice(0, a.off)) return null;
    return this.posAtSource(a.id, a.off);
  }

  // Put the selection back on the same source text. A missing end clears it, so a selection never
  // moves to text the user did not choose.
  /** @param {SelectionAnchors | null} anchors @returns {void} */
  _reanchor(anchors) {
    const anchor = anchors && this._posAtAnchor(anchors.a);
    const cursor = anchors && this._posAtAnchor(anchors.b);
    if (!anchor || !cursor) {
      this.clearSelection();
      return;
    }
    this.selection = { anchor, cursor };
  }

  // The markdown blocks of one message, oldest first. A plain turn has none.
  /** @param {number} id @returns {{ kind: string, at: number, end: number }[]} */
  blocksOf(id) {
    this._rowsFor(id);
    const c = this._rows.get(id);
    if (c && c.blocks) return c.blocks;
    const doc = this._docs.get(id);
    return doc ? doc.blocks() : [];
  }

  // The rendered rows of one message at the drawn width. The array and its rows belong to the
  // render cache, so only this class may hold them.
  /** @param {number} id @returns {TranscriptRow[]} */
  _rowsFor(id) {
    const i = this._indexOf(id);
    if (i < 0 || this._width <= 0) return [];
    const message = /** @type {MessageDescriptor} */ (this._at(i));
    return this._rowsOf(message, this._width);
  }

  // The number of rendered rows in one message.
  /** @param {number} id @returns {number} */
  rowCountOf(id) {
    return this._rowsFor(id).length;
  }

  // The rendered text of one row, or "" when the row is gone.
  /** @param {number} id @param {number} row @returns {string} */
  rowTextAt(id, row) {
    const rows = this._rowsFor(id);
    if (row >= 0 && row < rows.length) {
      const line = /** @type {TranscriptRow} */ (rows[row]);
      return rowText(line);
    }
    return "";
  }

  // The row index of `pos` across every message, or -1 when the position is gone.
  /** @param {Position | null} pos @returns {number} */
  _globalRow(pos) {
    if (!pos || this._width <= 0) return -1;
    let base = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) return -1;
      const rows = this._rowsOf(m, this._width);
      if (sameId(m.id, pos.id)) return pos.row < rows.length ? base + pos.row : -1;
      base += rows.length;
    }
  }

  // The source offset under a logical position, or -1 without one.
  /** @param {Position | null} pos @returns {number} */
  sourceAt(pos) {
    if (!pos || pos.row < 0) return -1;
    const rows = this._rowsFor(pos.id);
    if (pos.row >= rows.length) return -1;
    const row = /** @type {TranscriptRow} */ (rows[pos.row]);
    return rowSourceAt(row, pos.col);
  }

  // The position that renders source `offset`, or the first one after it. The end of the source
  // takes the last position, so a selection that runs to the end survives a rewrap.
  /** @param {number} id @param {number} offset @returns {Position | null} */
  posAtSource(id, offset) {
    const rows = this._rowsFor(id);
    let tail = null;
    let tailOff = -1;
    for (let k = 0; k < rows.length; k++) {
      const row = /** @type {TranscriptRow} */ (rows[k]);
      const segments = row.segments;
      if (!segments) continue;
      let at = 0;
      for (const seg of segments) {
        const end = at + seg.text.length;
        if (seg.src != null) {
          if (/** @type {number} */ (seg.srcEnd) > offset) {
            // A caret at the end of the source before a gap belongs to that end, not past it.
            if (offset === tailOff) return tail;
            const col = offset > seg.src && isLinear(seg) ? at + (offset - seg.src) : at;
            const body = rowText(row);
            const wrapRow = { start: 0, end: body.length, soft: false };
            return { id, row: k, col: caretAtCol(body, wrapRow, term.measure(body.slice(0, Math.min(col, end)))) };
          }
          tail = { id, row: k, col: end };
          tailOff = /** @type {number} */ (seg.srcEnd);
        }
        at = end;
      }
    }
    return tail;
  }

  // The screen cell of a logical position, or null when it is off the drawn rows.
  /** @param {Position | null} pos @returns {{ x: number, y: number } | null} */
  screenAt(pos) {
    const rect = this.pager.rect();
    const g = this._globalRow(pos);
    if (!rect || rect.w <= 0 || rect.h <= 0 || g < 0) return null;
    const y = rect.y + (g - this.pager.scroll);
    if (y < rect.y || y >= rect.y + rect.h) return null;
    if (!pos) return null;
    const row = /** @type {TranscriptRow} */ (this._rowsFor(pos.id)[pos.row]);
    const body = rowText(row);
    const x = rect.x + (row.indent || 0) + term.measure(body.slice(0, pos.col));
    return x >= rect.x + rect.w ? null : { x, y };
  }

  // Scroll the least amount that brings `pos` onto the screen.
  /** @param {Position} pos @returns {void} */
  ensureVisible(pos) {
    this.pager.scrollIntoView(this._globalRow(pos));
  }

  /** @param {MessageDescriptor} m @param {number} width @returns {TranscriptRow[]} */
  _rowsOf(m, width) {
    const c = this._rows.get(m.id);
    if (c && c.w === width) return c.rows;

    let rows;
    let source = null;
    let blocks = null;
    if (m.type === "user") {
      rows = userRows(m.id, this.textOf(m.id), width);
      source = this.textOf(m.id) || "";
    } else if (m.type === "compaction") {
      rows = wrapPlain(m.id, this.textOf(m.id), width, "TxThought");
      source = this.textOf(m.id) || "";
    } else if (this.partsOf) {
      const built = this._partRows(m, width);
      rows = built.rows;
      source = built.source;
      blocks = built.blocks;
    } else {
      rows = this._assistantRows(m.id, width);
      const doc = this._docs.get(m.id);
      source = doc ? doc.sourceText() : this.textOf(m.id) || "";
    }
    if (m.error) {
      const base = source && source.length ? source.length + 1 : 0;
      const err = errorRows(m.id, m.error, width, base);
      source = source && source.length ? source + "\n" + err.source : err.source;
      rows = rows.concat(err.rows);
    }
    this._rows.set(m.id, { w: width, rows, source, blocks });
    this._sources.set(m.id, source == null ? "" : source);
    return rows;
  }

  /** @param {number} id @returns {readonly Wire.AssistantPart[]} */
  _partList(id) {
    try {
      const p = /** @type {(id: number) => readonly Wire.AssistantPart[]} */ (this.partsOf)(id);
      return Array.isArray(p) ? p : [];
    } catch (_) {
      return [];
    }
  }

  /** @param {ItemKey} id @param {ItemKey} partId @returns {string} */
  _expandKey(id, partId) {
    return String(id) + ":" + String(partId);
  }

  /** @param {number} id @param {number} partId @returns {boolean} */
  _reasoningLive(id, partId) {
    if (!this._active || !sameId(this._active.id, id)) return false;
    const parts = this._partList(id);
    const part = parts.find((p) => p && sameId(p.id, partId));
    return !!(part && part.type === "reasoning");
  }

  /** @param {number} id @param {number} partId @param {Wire.AssistantPart | null | undefined} part @returns {boolean} */
  _isExpanded(id, partId, part) {
    const k = this._expandKey(id, partId);
    if (this._expand.has(k)) return /** @type {boolean} */ (this._expand.get(k));
    if (part && part.type === "reasoning") return this._reasoningLive(id, partId);
    const state = part == null ? part : part.type === "tool" ? part.state : undefined;
    return defaultExpanded(state);
  }

  // Flip the user override for one foldable part. A missing part is a no-op.
  /** @param {number} id @param {number} partId @returns {void} */
  togglePart(id, partId) {
    if (id == null || partId == null) return;
    const k = this._expandKey(id, partId);
    let part = null;
    if (this.partsOf) {
      for (const p of this._partList(id)) if (p && sameId(p.id, partId)) part = p;
    }
    this._expand.set(k, !this._isExpanded(id, partId, part));
    this._dropRows(id);
    root.invalidate();
  }

  // The part under a logical position, or null on a gutter/separator row.
  /** @param {Position | null} pos @returns {PartHit | null} */
  partAt(pos) {
    if (!pos) return null;
    const rows = this._rowsFor(pos.id);
    const row = pos.row >= 0 && pos.row < rows.length ? rows[pos.row] : null;
    if (!row || row.partId == null || !row.kind) return null;
    return { id: pos.id, partId: row.partId, kind: row.kind };
  }

  // The header position of a foldable part, or null when it is gone.
  /** @param {number} id @param {number} partId @returns {Position | null} */
  partHeader(id, partId) {
    const rows = this._rowsFor(id);
    for (let row = 0; row < rows.length; row++) {
      const r = /** @type {TranscriptRow} */ (rows[row]);
      const kind = r.kind || "";
      if (r.partId === partId && kind.endsWith("-header")) return { id, row, col: 0 };
    }
    return null;
  }

  // Stops for J/K: user rows, text-part starts, tool and reasoning headers.
  /** @returns {Position[]} */
  partStops() {
    const out = [];
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsFor(m.id);
      if (m.type === "user" || m.type === "compaction" || !this.partsOf) {
        if (rows.length) out.push({ id: m.id, row: 0, col: 0 });
        continue;
      }
      let lastPart = null;
      for (let row = 0; row < rows.length; row++) {
        const r = /** @type {TranscriptRow} */ (rows[row]);
        const kind = r.kind;
        if (kind === "tool-header" || kind === "reasoning-header" || kind === "error") {
          out.push({ id: m.id, row, col: 0 });
          lastPart = r.partId;
        } else if (kind === "text" && r.partId !== lastPart) {
          out.push({ id: m.id, row, col: 0 });
          lastPart = r.partId;
        }
      }
    }
    return out;
  }

  // Next (dir > 0) or previous (dir < 0) part stop after `pos`.
  /** @param {Position | null} pos @param {number} dir @returns {Position | null} */
  partStep(pos, dir) {
    if (!pos) return null;
    const stops = this.partStops();
    if (stops.length === 0) return null;
    if (dir > 0) {
      for (const s of stops) if (this._cmpPos(s, pos) > 0) return s;
      return null;
    }
    for (let n = stops.length - 1; n >= 0; n--) {
      const stop = /** @type {Position} */ (stops[n]);
      if (this._cmpPos(stop, pos) < 0) return stop;
    }
    return null;
  }

  /** @param {MessageDescriptor} m @param {number} width @returns {{ rows: TranscriptRow[], source: string, blocks: { kind: string, at: number, end: number }[] }} */
  _partRows(m, width) {
    const parts = this._partList(m.id);
    const rows = /** @type {TranscriptRow[]} */ ([]);
    const blocks = /** @type {{ kind: string, at: number, end: number }[]} */ ([]);
    let source = "";
    const contentW = Math.max(1, width - TX_GUTTER);
    for (const part of parts) {
      const type = part && part.type;
      if (type === "text") {
        if (source) source += "\n";
        const base = source.length;
        const key = this._expandKey(m.id, part.id);
        let doc = this._partDocs.get(key);
        if (!doc) {
          doc = new Document();
          this._partDocs.set(key, doc);
        }
        doc.setText(/** @type {Extract<Wire.AssistantPart, { type: "text" }>} */ (part).text || "");
        source += doc.sourceText();
        for (const b of doc.blocks()) blocks.push({ kind: b.kind, at: b.at + base, end: b.end + base });
        for (const r of doc.rows(contentW)) {
          rows.push({ segments: shiftSrc(r.segments, base), indent: TX_GUTTER, key: m.id, partId: part.id, kind: "text" });
        }
      } else if (type === "tool") {
        if (source) source += "\n";
        const base = source.length;
        const expanded = this._isExpanded(m.id, part.id, part);
        const built = toolRows(/** @type {Extract<Wire.AssistantPart, { type: "tool" }>} */ (part), contentW, expanded);
        source += built.source;
        for (const r of built.rows) {
          rows.push({
            ...r,
            segments: r.segments ? shiftSrc(r.segments, base) : r.segments,
            indent: TX_GUTTER,
            key: m.id,
            partId: part.id,
          });
        }
      } else if (type === "reasoning") {
        if (source) source += "\n";
        const base = source.length;
        const live = this._reasoningLive(m.id, part.id);
        const expanded = this._isExpanded(m.id, part.id, part);
        const key = this._expandKey(m.id, part.id);
        let doc = this._partDocs.get(key);
        if (!doc) {
          doc = new Document();
          this._partDocs.set(key, doc);
        }
        const built = reasoningRows(/** @type {Extract<Wire.AssistantPart, { type: "reasoning" }>} */ (part), contentW, expanded, live, doc);
        source += built.source;
        for (const r of built.rows) {
          rows.push({
            ...r,
            segments: r.segments ? shiftSrc(r.segments, base) : r.segments,
            indent: TX_GUTTER,
            key: m.id,
            partId: part.id,
          });
        }
      }
    }
    rows.push({ text: "", key: m.id });
    return { rows, source, blocks };
  }

  // Assistant rows come from a per-message md Document, indented past the gutter, then a separator.
  /** @param {number} id @param {number} width @returns {TranscriptRow[]} */
  _assistantRows(id, width) {
    let doc = this._docs.get(id);
    if (!doc) {
      doc = new Document();
      this._docs.set(id, doc);
    }
    doc.setText(this.textOf(id));
    const contentW = Math.max(1, width - TX_GUTTER);
    const rows = /** @type {TranscriptRow[]} */ (doc.rows(contentW).map((r) => ({ segments: r.segments, indent: TX_GUTTER, key: id })));
    rows.push({ text: "", key: id });
    return rows;
  }

  /** @param {number} i @returns {MessageDescriptor | null} */
  _at(i) {
    return i < this._messages.length ? /** @type {MessageDescriptor} */ (this._messages[i]) : i === this._messages.length ? this._active : null;
  }

  // The message order index of `id`, or -1. A position outside the outline has no selection.
  /** @param {number} id @returns {number} */
  _indexOf(id) {
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) return -1;
      if (sameId(m.id, id)) return i;
    }
  }

  // Order the two ends and resolve them to message indexes. Return null without a live selection.
  /** @returns {SelectionRange | null} */
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
  /** @param {SelectionRange} range @param {number} i @param {number} k @param {number} len @returns {{ from: number, to: number } | null} */
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
  /** @returns {string} */
  selectedText() {
    const range = this._range();
    if (!range || this._width <= 0) return "";
    const out = [];
    for (let i = range.si; i <= range.ei; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsOf(m, this._width);
      for (let k = 0; k < rows.length; k++) {
        const row = /** @type {TranscriptRow} */ (rows[k]);
        const body = rowText(row);
        const r = this._rowRange(range, i, k, body.length);
        if (r) out.push(body.slice(r.from, r.to));
      }
    }
    return out.join("\n");
  }

  // The markdown under the selection. A mouse copy still takes `selectedText`, so the rendered
  // text and the source stay separate. A turn with no mapped row is plain text and is its own source.
  /** @returns {string} */
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
        const row = /** @type {TranscriptRow} */ (rows[k]);
        const r = this._rowRange(range, i, k, rowText(row).length);
        if (!r) continue;
        plain.push(rowText(row).slice(r.from, r.to));
        const span = rowSourceSpan(row, r.from, r.to);
        if (!span) continue;
        if (from < 0 || span.from < from) from = span.from;
        if (span.to > to) to = span.to;
      }
      if (from < 0) {
        if (plain.length) out.push(plain.join("\n"));
        continue;
      }
      out.push(this._sourceOf(m.id).slice(from, to));
    }
    return out.join("\n");
  }

  // The placeholder rows, or null when a message exists or no placeholder is set.
  /** @returns {TranscriptRow[] | null} */
  _emptyRows() {
    if (!this.empty || this._messages.length > 0 || this._active) return null;
    const lines = this.empty();
    return lines && lines.length ? lines.map((l) => {
      const line = /** @type {{ text?: unknown, group?: string }} */ (l);
      return { text: line.text == null ? String(l) : String(line.text), group: line.group || "YukeEmpty", indent: TX_GUTTER };
    }) : null;
  }

  /** @param {number} width @returns {number} */
  rowCount(width) {
    if (width <= 0) return 0;
    this._invalidate(width);
    const blank = this._emptyRows();
    if (blank) return blank.length;
    let n = 0;
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) break;
      n += this._rowsOf(m, width).length;
    }
    return n;
  }

  /** @param {number} width @param {number} top @param {number} height @returns {TranscriptRow[]} */
  rows(width, top, height) {
    if (width <= 0 || height <= 0) return [];
    this._invalidate(width);
    const blank = this._emptyRows();
    if (blank) return blank.slice(top, top + height);
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
        const row = /** @type {TranscriptRow} */ (rows[k]);
        // The row objects are cached, so a selection goes onto a copy.
        const r = range && this._rowRange(range, i, k, rowText(row).length);
        // An empty range paints nothing, so only a real span goes onto the row copy.
        out.push(r && r.to > r.from ? { ...row, sel: r } : row);
      }
      base += rows.length;
      if (base >= top + height) break;
    }
    return out;
  }

  // The committed messages, oldest first, then the streaming draft. Each one is a copy, so a
  // caller cannot change the transcript through it.
  /** @returns {MessageDescriptor[]} */
  messages() {
    const out = this._messages.map((m) => ({ ...m }));
    if (this._active) out.push({ ...this._active });
    return out;
  }

  // The newest message of `type`, or the newest of any type without one. Return null when empty.
  /** @param {MessageDescriptor["type"] | undefined} type @returns {MessageDescriptor | null} */
  last(type) {
    const all = this.messages();
    for (let i = all.length - 1; i >= 0; i--) {
      const message = /** @type {MessageDescriptor} */ (all[i]);
      if (!type || message.type === type) return message;
    }
    return null;
  }

  /** @param {MessageDescriptor | null} m @returns {string} */
  textFor(m) {
    return m ? this.textOf(m.id) : "";
  }

  // Return the fenced block bodies of every message, oldest first. A user turn can also hold a
  // fence, so no turn type is skipped.
  /** @returns {CodeBlock[]} */
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

  /** @param {Rect} rect @returns {void} */
  draw(rect) {
    this.pager.draw(rect);
  }

  /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
  onKey(ev) {
    return this.pager.onKey(ev);
  }

  // The logical position under a screen cell, or null off the drawn rows. `clamp` pulls a pointer
  // outside the pane back to the nearest row, so a drag keeps up with it.
  /** @param {number} col @param {number} row @param {boolean} clamp @returns {Position | null} */
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
        const line = /** @type {TranscriptRow} */ (rows[g - base]);
        const body = rowText(line);
        const x = Math.max(0, col - rect.x - (line.indent || 0));
        const wrapRow = { start: 0, end: body.length, soft: false };
        return { id: m.id, row: g - base, col: caretAtCol(body, wrapRow, x) };
      }
      base += rows.length;
    }
  }

  // A left drag selects text. The wheel still scrolls, and a bare click drops the old selection.
  // A press records the start; a drag opens the range, so a click never leaves a one-cell range.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    if (isWheel(ev.button)) return this.pager.onMouse(ev);
    if (ev.button !== "left") return false;
    if (ev.event === "press") {
      const r = this.pager.rect();
      if (!r || ev.col < r.x || ev.col >= r.x + r.w) return false;
      const pos = this.posAt(ev.col, ev.row, false);
      this.clearSelection();
      this._press = pos;
      this._dragging = pos != null;
      this._didDrag = false;
      return true;
    }
    if (!this._dragging) return false;
    if (ev.event === "drag") {
      this._didDrag = true;
      // A drag past the edge clamps, so the selection follows the pointer out of the pane.
      const pos = this.posAt(ev.col, ev.row, true);
      if (this._press && pos) this.select(this._press, pos);
      return true;
    }
    if (ev.event === "release") {
      const press = this._press;
      const dragged = this._didDrag;
      this._dragging = false;
      this._press = null;
      this._didDrag = false;
      if (!dragged && press) {
        const hit = this.partAt(press);
        if (hit && (hit.kind === "tool-header" || hit.kind === "reasoning-header")) {
          this.togglePart(hit.id, hit.partId);
          const header = this.partHeader(hit.id, hit.partId);
          if (header) this.ensureVisible(header);
          this.clearSelection();
          return true;
        }
      }
      const selected = this.selectedText();
      if (selected === "") this.clearSelection();
      else if (this.onSelect) this.onSelect(selected);
      return true;
    }
    return false;
  }
}

// A message input grows with its text. Enter submits and the newline keys add a line.
export class Composer {
  /** @param {ComposerOptions} [opts] */
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.input = new TextInput({
      onChange: () => this._invalidate(),
      onEdit: (from, to, ins) => this._shiftSpans(from, to, ins),
    });
    this.prompt = opts.prompt != null ? opts.prompt : "› ";
    this.placeholder = opts.placeholder || "";
    this.onSubmit = opts.onSubmit || null;
    this.maxRows = opts.maxRows || COMPOSER_ROWS_MAX;
    this.scroll = 0;
    /** @type {number | null} */
    this.goalCol = null; // the column a vertical move holds across a short row
    // A collapsed paste. `start` and `end` index the text; the label replaces them on the screen
    // only. The text keeps the paste, so a submit sends it even when a span is lost.
    /** @type {PasteSpan[]} */
    this.spans = [];
    this.nextPaste = 1;
    /** @type {WrapRow[] | null} */
    this._rows = null;
    this._rowsW = -1;
    /** @type {Projection | null} */
    this._proj = null;
  }

  // Drop the projection and the row cache after an edit, so both rebuild once per edit.
  /** @returns {void} */
  _invalidate() {
    this._rows = null;
    this._proj = null;
    this.goalCol = null;
  }

  // Move a span the edit did not touch. An edit inside a span drops the span and shows the paste.
  /** @param {number} from @param {number} to @param {number} ins @returns {void} */
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
  /** @returns {Projection} */
  _projection() {
    if (this._proj) return this._proj;
    const s = this.input.text;
    if (this.spans.length === 0) {
      this._proj = { text: s, parts: [] };
      return this._proj;
    }
    const spans = this.spans.filter((sp) => sp.end > sp.start && sp.end <= s.length).sort((a, b) => a.start - b.start);
    if (spans.length !== this.spans.length) this.spans = spans;
    const parts = [];
    let out = "";
    let at = 0;
    for (const sp of spans) {
      if (sp.start < at) continue;
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
  /** @param {number} caret @returns {number} */
  _toDisplay(caret) {
    let d = caret;
    for (const p of this._projection().parts) if (caret >= p.span.end) d += p.delta;
    return d;
  }

  // Map back, and push a caret that landed inside a label to its nearer edge.
  /** @param {number} disp @returns {number} */
  _toText(disp) {
    let t = disp;
    for (const p of this._projection().parts) {
      if (disp > p.start && disp < p.end) return disp - p.start < p.end - disp ? p.span.start : p.span.end;
      if (disp >= p.end) t -= p.delta;
    }
    return t;
  }

  /** @param {number} caret @returns {PasteSpan | null} */
  _spanEndingAt(caret) {
    return this.spans.find((sp) => sp.end === caret) || null;
  }

  /** @param {number} caret @returns {PasteSpan | null} */
  _spanStartingAt(caret) {
    return this.spans.find((sp) => sp.start === caret) || null;
  }

  /** @returns {string} */
  _prompt() {
    return this.prompt;
  }

  /** @param {number} w @returns {number} */
  _textWidth(w) {
    return Math.max(1, w - term.measure(this._prompt()));
  }

  /** @param {number} width @returns {{ start: number, end: number, soft: boolean }[]} */
  _rowsAt(width) {
    if (this._rows && this._rowsW === width) return this._rows;
    this._rowsW = width;
    this._rows = wrapOffsets(this._projection().text, width);
    return this._rows;
  }

  // The rows the text needs. The caller caps this against the space it has.
  /** @param {number} w @returns {number} */
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
  /** @returns {void} */
  submit() {
    const t = this.input.text.trim();
    if (t === "") return;
    // The owner may reject synchronously (returns false): keep the text rather than blank it.
    if (this.onSubmit && this.onSubmit(t) === false) return;
    this.spans = [];
    this.nextPaste = 1;
    this.input.setText("");
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    if (ev.type === "paste") return this._paste(ev.text || "");
    const s = strokeOf(/** @type {Extract<HostEvent, { type: "key" }>} */ (ev));
    // The composer owns the vertical keys, so a wrapped line never scrolls the transcript.
    if (s === "up") return this.moveRow(-1);
    if (s === "down") return this.moveRow(1);

    // Every other key edits or moves the caret across, so the goal column is stale.
    this.goalCol = null;
    if (s === "enter") {
      this.submit();
      return true;
    }
    if (/** @type {Record<string, boolean>} */ (COMPOSER_NEWLINE)[s]) {
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
  /** @param {string} t @returns {boolean} */
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

  // Move the caret one drawn row. The goal column survives a short row.
  /** @param {number} delta @returns {boolean} */
  moveRow(delta) {
    const rows = this._rowsAt(this._textWidth(this.rect.w));
    const proj = this._projection().text;
    const here = caretRowCol(proj, rows, this._toDisplay(this.input.caret));
    const col = this.goalCol === null ? here.col : this.goalCol;
    const next = here.row + delta;
    if (next >= 0 && next < rows.length) {
      const row = /** @type {WrapRow} */ (rows[next]);
      this.input.caret = this._toText(caretAtCol(proj, row, col));
      this.goalCol = col;
    }
    return true;
  }

  // Scroll the smallest amount that keeps the caret row on the screen.
  /** @param {WrapRow[]} rows @param {number} h @returns {void} */
  _scrollTo(rows, h) {
    const { row } = caretRowCol(this._projection().text, rows, this._toDisplay(this.input.caret));
    this.scroll = Math.min(this.scroll, Math.max(0, rows.length - h));
    if (row < this.scroll) this.scroll = row;
    else if (row >= this.scroll + h) this.scroll = row - h + 1;
  }

  /** @param {boolean} _focused @returns {void} */
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
      const r = /** @type {WrapRow} */ (rows[this.scroll + i]);
      text(x + pw, y + i, clip(proj.slice(r.start, r.end), tw, false), "UIComposer");
    }
  }

  /** @returns {{ x: number, y: number, visible: boolean } | null} */
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

/** @param {string} t @returns {boolean} */
function pasteCollapses(t) {
  return t.length > COMPOSER_PASTE_CHARS || lineCount(t) >= COMPOSER_PASTE_LINES;
}

// A newline at the end closes the last line. It does not open an empty one.
/** @param {string} t @returns {number} */
function lineCount(t) {
  const end = t.length > 0 && t[t.length - 1] === "\n" ? t.length - 1 : t.length;
  let n = 1;
  for (let i = t.indexOf("\n"); i >= 0 && i < end; i = t.indexOf("\n", i + 1)) n++;
  return n;
}

// Count lines for a multiline paste. Count characters for a single-line paste.
/** @param {number} id @param {string} t @returns {string} */
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

// The chat pane: a transcript above a composer in one leaf. Draw, layout, and mouse routing.
export class ChatView {
  /** @param {ChatViewOptions} [opts] */
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.transcript = new Transcript({ textOf: opts.textOf, partsOf: opts.partsOf, onSelect: opts.onSelect, empty: opts.empty });
    this.composer = new Composer({ placeholder: "Message…", onSubmit: opts.onSubmit });
  }

  get name() {
    return "chat";
  }

  // The pane's default caret is the composer.
  /** @returns {void} */
  onFocus() {}

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    return this.composer.onKey(ev) || this.transcript.onKey(/** @type {Extract<HostEvent, { type: "key" }>} */ (ev));
  }

  // Route by sub-rect, so a click or a wheel step over the composer never moves the transcript.
  // A captured drag still reaches the transcript, because only a press hits this test.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    const r = this.transcript.pager.rect();
    const inside = r && ev.col >= r.x && ev.col < r.x + r.w && ev.row >= r.y && ev.row < r.y + r.h;
    if (inside || ev.event === "drag" || ev.event === "release") return this.transcript.onMouse(ev);
    return false;
  }

  /** @param {boolean} focused @returns {void} */
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
    const rule = y + h - rows - 1;
    if (rule > y) this.transcript.draw({ x, y, w, h: rule - y });
    else this.transcript.hide();
    if (rule >= y) text(x, rule, "─".repeat(w), "YukeRule");
    this.composer.draw(focused);
  }

  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    return this.composer.cursor();
  }
}

// A floating, bordered, titled window centers over the screen as an overlay-stack layer. The
// interior is winText/winFill (clipped); override drawContent(win) or set a `content`.
export class Window {
  /** @param {WindowOptions} [opts] */
  constructor(opts = {}) {
    this.opts = opts;
    this.modal = opts.modal !== false;
    this.border = opts.border === undefined ? "single" : opts.border;
    this.content = opts.content || null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.inner = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** @returns {string} */
  get name() {
    return this.opts.name || "window";
  }

  /** @returns {BorderSet | null} */
  _borderSet() {
    const b = this.border;
    if (b === "none" || b == null) return null;
    return typeof b === "object" ? b : borders[b] || borders.single;
  }

  // Resolve a cells | ratio(0..1] | function(max)=>cells dimension against a max.
  /** @param {Dimension | null | undefined} v @param {number} max @param {number} fallback @returns {number} */
  _dim(v, max, fallback) {
    if (v == null) return fallback;
    if (typeof v === "function") return Math.round(v(max));
    if (v > 0 && v <= 1) return Math.round(v * max);
    return Math.round(v);
  }

  /** @returns {void} */
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

  /** @param {number} lx @param {number} ly @param {string} s @param {string} group @returns {void} */
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

  /** @param {number} lx @param {number} ly @param {number} fw @param {number} fh @param {string} group @returns {void} */
  winFill(lx, ly, fw, fh, group) {
    const { x, y, w, h } = this.inner;
    const x0 = Math.max(0, lx);
    const y0 = Math.max(0, ly);
    const x1 = Math.min(w, lx + fw);
    const y1 = Math.min(h, ly + fh);
    if (x1 <= x0 || y1 <= y0) return;
    fill(x + x0, y + y0, x1 - x0, y1 - y0, group);
  }

  /** @returns {void} */
  draw() {
    const { x, y, w, h } = this.rect;
    fill(x, y, w, h, this.opts.panelGroup || "UIPanel");
    const bs = this._borderSet();
    if (bs) this._drawBorder(bs);
    if (this.content && this.content.draw) this.content.draw(this);
    this.drawContent(this);
  }

  /** @param {Window} _win @returns {void} */
  drawContent(_win) {}

  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    return this.content && this.content.cursor ? this.content.cursor(this) : null;
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    return this.content && this.content.onKey ? this.content.onKey(ev) : false;
  }

  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    return this.content && this.content.onMouse ? this.content.onMouse(ev) : false;
  }

  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    return this.content && this.content.needsTick ? this.content.needsTick() : null;
  }

  /** @returns {void} */
  tick() {
    if (this.content && this.content.tick) this.content.tick();
  }

  /** @param {BorderSet} bs @returns {void} */
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
  /** @param {string | (() => string) | undefined} label @param {"left" | "center" | "right" | undefined} pos @param {number} ry @param {string} group @returns {void} */
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
/** @template T */
export class PickerContent {
  /** @param {T[]} items @param {SelectOptions<T>} opts */
  constructor(items, opts) {
    this.opts = opts;
    /** @type {Window | null} */
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

  /** @param {T[]} items @returns {void} */
  setItems(items) {
    this.list.setItems(items);
  }

  /** @param {ItemKey | null | undefined} k @returns {boolean} */
  selectKey(k) {
    return this.list.selectKey(k);
  }

  /** @returns {T | null} */
  selected() {
    return this.list.selected();
  }

  /** @param {Window} win @returns {void} */
  draw(win) {
    this.list.draw(win.inner);
  }

  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    return this.list.onMouse(ev);
  }

  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    return this.opts.needsTick || null;
  }

  /** @returns {null} */
  cursor() {
    return null;
  }

  /** @returns {void} */
  close() {
    root.popOverlay(/** @type {Window} */ (this.win));
  }

  // Accept the selection, gated by `validate`, then close unless `closeOnAccept` is false.
  /** @returns {void} */
  accept() {
    const it = this.list.selected();
    if (it == null) return;
    if (this.validate && !this.validate(it)) return;
    if (this.onAccept) this.onAccept(it, this.list.selectedIndex());
    if (this.closeOnAccept) this.close();
  }

  /** @returns {void} */
  cancel() {
    if (this.onCancel) this.onCancel();
    else this.close();
  }

  /** @param {string} name @returns {void} */
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

  /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
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
        this.action(/** @type {"accept" | "cancel" | "close" | "next" | "prev" | "top" | "bottom"} */ (bound));
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

/** @param {string} c @returns {boolean} */
function isUpper(c) {
  return c !== c.toLowerCase() && c === c.toUpperCase();
}

/** @param {string} c @returns {boolean} */
function isLower(c) {
  return c !== c.toUpperCase() && c === c.toLowerCase();
}

/** @param {string} c @returns {boolean} */
function isWordChar(c) {
  return /[\p{L}\p{N}]/u.test(c);
}

// The bonus for a char given the char before it. fzy rewards a boundary only for a word char.
/** @param {string} prev @param {string} cur @returns {number} */
function charBonus(prev, cur) {
  if (isLower(prev) && isUpper(cur)) return MATCH_CAPITAL;
  if (!isWordChar(cur)) return 0;
  if (prev === "/") return MATCH_SLASH;
  if (prev === "-" || prev === "_" || prev === " ") return MATCH_WORD;
  if (prev === ".") return MATCH_DOT;
  return 0;
}

/** @param {string[]} chars @returns {number[]} */
function precomputeBonus(chars) {
  const bonus = new Array(chars.length);
  let last = "/";
  for (let i = 0; i < chars.length; i++) {
    const char = /** @type {string} */ (chars[i]);
    bonus[i] = charBonus(last, char);
    last = char;
  }
  return bonus;
}

// True when `query` is a subsequence of `text`, case-insensitive.
/** @param {string[]} textLower @param {string[]} queryLower @returns {boolean} */
function isSubsequence(textLower, queryLower) {
  let qi = 0;
  for (let i = 0; i < textLower.length && qi < queryLower.length; i++) {
    if (textLower[i] === queryLower[qi]) qi++;
  }
  return qi === queryLower.length;
}

// Score `query` against `text`; null when `query` is not a subsequence. Higher is better.
/** @param {string} text @param {string} query @returns {number | null} */
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
        if (j === 0) s = i * GAP_LEADING + /** @type {number} */ (bonus[i]);
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
/** @template T @param {T[]} items @param {string} query @param {(item: T) => string} textOf @returns {T[]} */
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

/** @template T */
export class Picker {
  /** @param {PickOptions<T>} opts */
  constructor(opts) {
    this.opts = opts;
    /** @type {Window | null} */
    this.win = null;
    this.input = new TextInput({ onChange: () => this.refilter() });
    /** @type {T[]} */
    this.source = opts.items || [];
    this.suggest = opts.suggest || null;
    this.textOf = opts.filterText || String;

    /** @type {List<T>} */
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

  /** @returns {string} */
  get query() {
    return this.input.text;
  }

  /** @param {string} s */
  set query(s) {
    this.input.setText(s); // onChange refilters
  }

  /** @param {T[]} items @returns {void} */
  setSource(items) {
    this.source = items || [];
    this.refilter();
  }

  // Recompute the visible list for the current query. A cleared selection lets setItems land on the
  // first selectable row, the best match (fuzzyRank sorts best first).
  /** @returns {void} */
  refilter() {
    const items = this.suggest ? this.suggest(this.query) || [] : fuzzyRank(this.source, this.query, this.textOf);
    this.list.selectedKey = null;
    this.list.setItems(items);
  }

  /** @returns {T | null} */
  selected() {
    return this.list.selected();
  }

  /** @param {Window} win @returns {void} */
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

  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    return this.list.onMouse(ev);
  }

  /** @param {Window} win @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor(win) {
    const { x, y, w, h } = win.inner;
    if (w <= 0 || h <= 0) return null; // an empty interior places no cursor
    const col = caretCol(w, PICKER_PROMPT, this.input.beforeCaret());
    return { x: x + Math.max(0, col), y, visible: true };
  }

  /** @returns {void} */
  accept() {
    const it = this.list.selected();
    if (it == null) return;
    if (this.opts.validate && !this.opts.validate(it)) return;
    if (this.closeOnAccept) root.popOverlay(/** @type {Window} */ (this.win));
    if (this.onAccept) this.onAccept(it);
  }

  /** @returns {void} */
  cancel() {
    root.popOverlay(/** @type {Window} */ (this.win));
    if (this.onCancel) this.onCancel();
  }

  /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
  onKey(ev) {
    const s = strokeOf(ev);
    // A per-instance keymap wins, checked before text input so a bound arrow drives the list.
    if (this.keymap) {
      const bound = this.keymap[s];
      if (bound === false) return true;
      if (typeof bound === "function") {
        /** @type {(ev: HostEvent, content: Picker<T>) => void} */ (/** @type {unknown} */ (bound))(ev, this);
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
  /** @template T @param {T[]} items @param {SelectOptions<T>} [opts] @returns {{ win: Window, content: PickerContent<T>, close: () => void }} */
  select(items, opts = {}) {
    const content = new PickerContent(items || [], opts);
    const win = new Window({ ...opts, content: /** @type {WindowContent} */ (content) });
    content.win = win;
    root.pushOverlay(win);
    return { win, content, close: () => root.popOverlay(win) };
  },

  /** @template T @param {PickOptions<T>} [opts] @returns {{ win: Window, content: PickerContent<T>, close: () => void }} */
  pick(opts = {}) {
    const content = new Picker(opts);
    const win = new Window({ ...opts, content: /** @type {WindowContent} */ (content) });
    content.win = win;
    root.pushOverlay(win);
    return { win, content: /** @type {PickerContent<T>} */ (/** @type {unknown} */ (content)), close: () => root.popOverlay(win) };
  },
};
