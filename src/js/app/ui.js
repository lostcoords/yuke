// yuke:ui — the widget kit over yuke:core: List and Window to subclass, plus the pickers on `ui`.
import { term } from "yuke:term";
import { text, fill, clip, root, strokeOf, TextInput, caretCol, caretAtCol, caretRowCol, wrapOffsets, style, config, slot, isWheel } from "yuke:core";
import { fuzzyRank } from "yuke:fzy";

/** @typedef {{ fg?: string, bg?: string, link?: string, bold?: boolean, dim?: boolean, italic?: boolean, reverse?: boolean, underline?: boolean }} StyleGroup */
/** @typedef {{ x: number, y: number, w: number, h: number }} Rect */
/** @typedef {string | number} ItemKey */
/** @typedef {"accept" | "cancel" | "close" | "next" | "prev" | "top" | "bottom"} PickerAction */
/** @typedef {string | number | object} ListKey */
/** @typedef {{ text?: string, group?: string, lines?: ListItem[], right?: string, rightGroup?: string, rightSelGroup?: string, marker?: string | null, markerGroup?: string, markerSelGroup?: string, indent?: number, selGroup?: string }} ListItem */
/** @typedef {{ type: "mouse", col: number, row: number, button: string, event: string, mods: number, count: number }} MouseEvent */
/** @typedef {{ start: number, end: number, label: string }} PasteSpan */
/** @typedef {{ span: PasteSpan, start: number, end: number, delta: number }} ProjectionPart */
/** @typedef {{ text: string, parts: ProjectionPart[] }} Projection */
/** @typedef {{ start: number, end: number, soft: boolean }} WrapRow */
/** @typedef {{ prompt?: string | undefined, placeholder?: string | undefined, onSubmit?: ((text: string) => boolean | void) | null | undefined, maxRows?: number | undefined }} ComposerOptions */
/** @typedef {{ tl: string, t: string, tr: string, r: string, br: string, b: string, bl: string, l: string }} BorderSet */
/** @typedef {"none" | "single" | "rounded" | "double" | BorderSet} Border */
/** @typedef {number | ((max: number) => number)} Dimension */
/** @typedef {{ draw?: (win: Window) => void, cursor?: (win: Window) => { x: number, y: number, visible: boolean } | null, onKey?: (ev: HostEvent) => boolean, onMouse?: (ev: MouseEvent) => boolean, needsTick?: () => { periodMs: number } | null, tick?: () => void }} WindowContent */
/** @typedef {{ name?: string, modal?: boolean, border?: Border, content?: WindowContent | null, width?: Dimension, height?: Dimension, panelGroup?: string, borderGroup?: string, title?: string | (() => string), title_pos?: "left" | "center" | "right", titleGroup?: string, footer?: string | (() => string), footer_pos?: "left" | "center" | "right", footerGroup?: string }} WindowOptions */
/** @template T @typedef {{ items?: T[] | undefined, format?: ((item: T, index: number) => string | ListItem) | undefined, key?: ((item: T) => ListKey) | undefined, isSelectable?: ((item: T) => boolean) | undefined, onMove?: ((item: T, index: number) => void) | null | undefined, itemHeight?: number | undefined, group?: string | undefined, selGroup?: string | undefined, dimGroup?: string | undefined, dimSelGroup?: string | undefined, drawCursor?: boolean | undefined }} ListOptions */
/** @template T @typedef {{ items?: T[] | undefined, suggest?: (query: string) => T[] | undefined, filterText?: ((item: T) => string) | undefined, format?: ((item: T, index: number) => string | ListItem) | undefined, key?: ((item: T) => ListKey) | undefined, isSelectable?: ((item: T) => boolean) | undefined, onMove?: ((item: T, index: number) => void) | null | undefined, itemGroup?: string | undefined, selGroup?: string | undefined, itemHeight?: number | undefined, onAccept?: ((item: T, index: number) => void) | null | undefined, onCancel?: (() => void) | null | undefined, validate?: ((item: T) => boolean) | null | undefined, keymap?: Record<string, string | false | ((ev: HostEvent, content: Picker<T>) => void)> | null | undefined, closeOnAccept?: boolean | undefined, needsTick?: { periodMs: number } | null | undefined, filter?: boolean | undefined } & WindowOptions} PickOptions */

// The kit adds only an absent highlight group, so a theme that set one first keeps it and a re-import does not re-seed.
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
  TxUser: { reverse: true },
  TxUserMarker: { reverse: true, bold: true },
  TxError: { fg: "danger", bold: true },
  TxSelect: { reverse: true },
  TxToolName: { fg: "fg", bold: true },
  TxToolMeta: { fg: "fg", dim: true },
  TxToolError: { fg: "danger", bold: true },
  TxToolBody: { fg: "fg", dim: true },
  TxToolAdd: { fg: "fg", bold: true },
  TxToolDel: { fg: "fg", dim: true },
  TxToolContext: { fg: "fg", dim: true },
  TxThought: { fg: "fg", dim: true, italic: true },
});
style.add(UI_GROUPS);

// Default page jump before a draw sets the real page height.
const PAGE_FALLBACK = 10;



// The nav vocabulary, written once. The shell binds these strokes and a modal layer reads them.
/** @typedef {(t: import("yuke:core").NavTarget) => void} NavAction */
/** @type {Record<string, NavAction | undefined>} */
export const NAV_KEYS = Object.freeze(Object.assign(Object.create(null), /** @type {Record<string, NavAction>} */ ({
  j: (t) => t.navBy(1),
  down: (t) => t.navBy(1),
  k: (t) => t.navBy(-1),
  up: (t) => t.navBy(-1),
  "ctrl+d": (t) => t.navPage(1),
  page_down: (t) => t.navPage(1),
  "ctrl+u": (t) => t.navPage(-1),
  page_up: (t) => t.navPage(-1),
  home: (t) => t.navEdge(-1),
  end: (t) => t.navEdge(1),
  G: (t) => t.navEdge(1),
})));

// A row from `format` may be a bare string or a record; fold both into one shape.
/** @param {string | ListItem | null | undefined} cell @returns {ListItem} */
export function normalizeCell(cell) {
  if (cell == null) return { text: "" };
  if (typeof cell === "string") return { text: cell };
  return { text: cell.text != null ? String(cell.text) : "", ...cell };
}

// A scrollable list where `key(item)` gives a stable identity, so the selection follows its item across a re-sort.
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

  /** @param {number} delta @returns {void} */
  navBy(delta) {
    this.move(delta);
  }

  /** @param {number} dir @returns {void} */
  navPage(dir) {
    this.move(dir * this._page);
  }

  /** @param {number} dir @returns {void} */
  navEdge(dir) {
    this.moveToEdge(dir);
  }

  // Forget the drawn rect when a container draws something else there, so a click cannot hit a row that left.
  /** @returns {void} */
  clearRect() {
    this._rect = null;
  }

  // A wheel step moves the cursor, because `draw` always scrolls the selection back into view.
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

  // Paint into rect { x, y, w, h }, up to `itemHeight` lines per item; every row repaints, so `format` may be dynamic.
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
    // A collapsed paste where the label replaces [start, end) on the screen only, so a submit still sends the text.
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
    const supplied = slot.get(this, "prompt");
    return typeof supplied === "string" ? supplied : this.prompt;
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

// A paste over one of these collapses to a label.
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

// These strokes add a line instead of a submit; Alt+Enter and Ctrl+J cover a legacy terminal encoding.
const COMPOSER_NEWLINE = { "shift+enter": true, "alt+enter": true, "ctrl+j": true };

// Border glyph sets, keyed by name. Extend by adding an entry.
export const borders = {
  single: { tl: "┌", t: "─", tr: "┐", r: "│", br: "┘", b: "─", bl: "└", l: "│" },
  rounded: { tl: "╭", t: "─", tr: "╮", r: "│", br: "╯", b: "─", bl: "╰", l: "│" },
  double: { tl: "╔", t: "═", tr: "╗", r: "║", br: "╝", b: "═", bl: "╚", l: "║" },
};


// A floating, bordered, titled window as an overlay layer; override drawContent(win) or set a `content`.
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

// A picker window's content: a List with accept/cancel/validate, an optional keymap over the default actions, and an optional query line.
const PICKER_PROMPT = "\u203a ";

/** @template T */
export class Picker {
  /** @param {PickOptions<T>} opts */
  constructor(opts) {
    this.opts = opts;
    /** @type {Window | null} */
    this.win = null;
    this.filter = opts.filter !== false;
    this.input = this.filter ? new TextInput({ onChange: () => this.refilter() }) : null;
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
    this.refilter();
  }

  /** @returns {string} */
  get query() {
    return this.input ? this.input.text : "";
  }

  /** @param {string} s */
  set query(s) {
    if (this.input) this.input.setText(s); // onChange refilters
  }

  /** @param {T[]} items @returns {void} */
  setSource(items) {
    this.source = items || [];
    this.refilter();
  }

  /** @param {T[]} items @returns {void} */
  setItems(items) {
    this.setSource(items);
  }

  /** @param {ItemKey | null | undefined} k @returns {boolean} */
  selectKey(k) {
    return this.list.selectKey(k);
  }

  // A menu shows its source as given. A finder takes the order `suggest` returns, or ranks the source and selects the first result.
  /** @returns {void} */
  refilter() {
    if (!this.filter) {
      this.list.setItems(this.source);
      return;
    }
    const items = this.suggest ? this.suggest(this.query) || [] : fuzzyRank(this.source, this.query, this.textOf);
    this.list.selectedKey = null;
    this.list.setItems(items);
  }

  /** @returns {T | null} */
  selected() {
    return this.list.selected();
  }

  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    return this.opts.needsTick || null;
  }

  /** @returns {void} */
  close() {
    root.popOverlay(/** @type {Window} */ (this.win));
  }

  /** @param {Window} win @returns {void} */
  draw(win) {
    const { x, y, w, h } = win.inner;
    if (w <= 0 || h <= 0) {
      this.list.clearRect();
      return;
    }
    if (!this.filter) {
      this.list.draw(win.inner);
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
    if (!this.input) return null; // a menu edits no query, so it places no cursor
    const { x, y, w, h } = win.inner;
    if (w <= 0 || h <= 0) return null; // an empty interior places no cursor
    const col = caretCol(w, PICKER_PROMPT, this.input.beforeCaret());
    return { x: x + Math.max(0, col), y, visible: true };
  }

  // Accept the selection, gated by `validate`. The close removes this window by identity, so a picker that `onAccept` opens survives it.
  /** @returns {void} */
  accept() {
    const it = this.list.selected();
    if (it == null) return;
    if (this.validate && !this.validate(it)) return;
    const at = this.list.selectedIndex();
    if (this.closeOnAccept) this.close();
    if (this.onAccept) this.onAccept(it, at);
  }

  // A cancel always closes. `onCancel` reports it; a picker that must survive Escape binds it to false.
  /** @returns {void} */
  cancel() {
    this.close();
    if (this.onCancel) this.onCancel();
  }

  /** @param {PickerAction} name @returns {void} */
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
    const s = strokeOf(ev);
    // A per-instance keymap wins, checked before text input so a bound arrow drives the list.
    if (this.keymap) {
      const bound = this.keymap[s];
      if (bound === false) return true;
      if (typeof bound === "function") {
        bound(ev, this);
        return true;
      }
      if (typeof bound === "string") {
        this.action(/** @type {PickerAction} */ (bound));
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
    // A menu navigates with the shared table. A finder gives every other key to the query.
    if (!this.filter) {
      const nav = NAV_KEYS[s];
      if (nav) nav(this.list);
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
    /** @type {TextInput} */ (this.input).onKey(ev); // the shared buffer takes the edit; its onChange refilters
    return true; // modal: consume every key
  }
}

// The kit's public surface. `select` navigates a set, `pick` adds the query line, and both return { win, content, close }.
export const ui = {
  /** @template T @param {T[]} items @param {PickOptions<T>} [opts] @returns {{ win: Window, content: Picker<T>, close: () => void }} */
  select(items, opts = {}) {
    return ui.pick({ ...opts, items: items || [], filter: false });
  },

  /** @template T @param {PickOptions<T>} [opts] @returns {{ win: Window, content: Picker<T>, close: () => void }} */
  pick(opts = {}) {
    const content = new Picker(opts);
    const win = new Window({ ...opts, content: /** @type {WindowContent} */ (content) });
    content.win = win;
    root.pushOverlay(win);
    return { win, content, close: () => root.popOverlay(win) };
  },
};
