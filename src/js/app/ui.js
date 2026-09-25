// yuke:ui — the widget kit over yuke:core: List and Window to subclass, plus the pickers on `ui`.
import { term } from "yuke:term";
import { text, fill, root, claimView, style, slot, isWheel, contains } from "yuke:core";
import { config, events } from "yuke:kernel";
import { clip, TextInput, caretCol, caretAtCol, caretRowCol, wrapPreview, nextGrapheme } from "yuke:text-input";
import { strokeOf } from "yuke:keys";
import { fuzzyRank } from "yuke:fzy";
import { Pager } from "yuke:pager";

/** @import { HostMouseEvent as MouseEvent, Rect, StyleGroup } from "./types/core.js" */
/** @import { BorderSet, ComposerOptions, ComposerSnapshot, ComposerSpan, Dimension, ItemKey, ListItem, ListKey, ListOptions, NavAction, PickerAction, PickOptions, Projection, PromptOptions, TextOptions, WindowContent, WindowOptions, WrapRow } from "./types/ui.js" */

// The kit adds only an absent highlight group, so a theme that set one first keeps it and a re-import does not re-seed.
const UI_GROUPS = /** @type {Record<string, StyleGroup>} */ ({
  // A panel fills with spaces over the terminal background, so it is opaque behind its border.
  UIPanel: { fg: "fg", bg: "bg" },
  // A float is a non-modal window over a pane, so a theme can tone it apart from a dialog.
  UIFloat: { fg: "fg", bg: "bg" },
  UIBorder: { fg: "fg", dim: true },
  UITitle: { fg: "fg", bold: true },
  UIItem: { fg: "fg" },
  UIItemSel: { reverse: true },
  UIPrompt: { fg: "fg", bold: true },
  UIQuery: { fg: "fg" },
  UIBody: { fg: "fg" },
  UIComposer: { fg: "fg" },
  UIDim: { fg: "fg", dim: true },
  UIDimSel: { reverse: true },
  TxUser: { reverse: true },
  TxUserMarker: { reverse: true, bold: true },
  TxError: { fg: "danger", bold: true },
  TxSelect: { reverse: true },
  TxToolName: { fg: "fg", bold: true },
  // One group per tool category. Each starts as the plain name group, so the default stays monochrome and a theme separates them.
  TxToolRead: { fg: "fg", bold: true },
  TxToolWrite: { fg: "fg", bold: true },
  TxToolRun: { fg: "fg", bold: true },
  TxToolAgent: { fg: "fg", bold: true },
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

// A scrolling overlay body: the nav keys and the wheel move it, and esc or q closes it.
export class ScrollView {
  /** @param {() => void} onClose */
  constructor(onClose) {
    this.onClose = onClose;
    this.pager = new Pager();
    /** @type {Rect} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** @param {Rect} rect */
  layout(rect) { this.rect = rect; }

  draw() { this.pager.draw(this.rect); }

  // A subclass may take a stroke before the nav keys; true means it used the stroke.
  /** @param {string} _stroke @returns {boolean} */
  onStroke(_stroke) { return false; }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type !== "key" || event.event === "release") return true;
    const stroke = strokeOf(event);
    if (stroke === "esc" || stroke === "q") this.onClose();
    else if (!this.onStroke(stroke)) NAV_KEYS[stroke]?.(this.pager);
    root.invalidate();
    return true;
  }

  /** @param {MouseEvent} event @returns {boolean} */
  onMouse(event) {
    const handled = this.pager.onMouse(event);
    if (handled) root.invalidate();
    return handled;
  }
}

// A row from `format` may be a bare string or a record; fold both into one shape.
/** @param {string | ListItem | null | undefined} cell @returns {ListItem} */
function normalizeCell(cell) {
  if (cell == null) return { text: "" };
  if (typeof cell === "string") return { text: cell };
  // A record with string text passes as is, so a drawn row allocates nothing.
  return typeof cell.text === "string" ? cell : { ...cell, text: cell.text != null ? String(cell.text) : "" };
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
    this.drawnRect = null; // the last drawn rect, for the click hit test
    /** @type {ListKey | null} */
    this.selectedKey = null;
    this.scroll = 0; // first visible item index
    this.page = PAGE_FALLBACK; // last visible item count, for page moves
    this.setItems(opts.items || []);
  }

  // Visible item count for a pixel height.
  /** @param {number} h @returns {number} */
  #visible(h) {
    return Math.max(1, Math.floor(h / this.itemHeight));
  }

  /** @param {T[]} items @returns {void} */
  setItems(items) {
    /** @type {T[]} */
    this.items = items || [];
    // A selection that left the list moves to the first selectable item, found without an index list.
    if (this.selectedIndex() < 0) {
      const first = this.#stepSelectable(-1, 1);
      this.selectedKey = first < 0 ? null : this.key(/** @type {T} */ (this.items[first]));
    }
    this.#clampScroll(this.page);
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

  /** @returns {number} */
  selectedIndex() {
    if (this.selectedKey == null) return -1;
    for (let i = 0; i < this.items.length; i++) {
      const item = /** @type {T} */ (this.items[i]);
      if (this.isSelectable(item) && this.key(item) === this.selectedKey) return i;
    }
    return -1;
  }

  /** @returns {T | null} */
  selected() {
    const i = this.selectedIndex();
    return i < 0 ? null : /** @type {T} */ (this.items[i]);
  }

  /** @param {number} h @returns {void} */
  ensureVisible(h) {
    const vis = this.#visible(h);
    this.page = vis;
    this.#scrollToVisible(vis);
  }

  /** @param {number} delta @returns {void} */
  navBy(delta) {
    const dir = delta < 0 ? -1 : 1;
    let index = this.selectedIndex();
    if (index < 0) index = this.#stepSelectable(-1, 1);
    if (index < 0) return;
    // Walk the items from the selection, so a move allocates no index list.
    for (let left = Math.abs(delta); left > 0; left--) {
      const next = this.#stepSelectable(index, dir);
      if (next < 0) break;
      index = next;
    }
    const item = /** @type {T} */ (this.items[index]);
    this.selectedKey = this.key(item);
    if (this.onMove) this.onMove(item, index);
  }

  /** @param {number} index @param {number} dir @returns {number} */
  #stepSelectable(index, dir) {
    for (let i = index + dir; i >= 0 && i < this.items.length; i += dir) {
      if (this.isSelectable(/** @type {T} */ (this.items[i]))) return i;
    }
    return -1;
  }

  /** @param {number} dir @returns {void} */
  navEdge(dir) {
    this.navBy(dir < 0 ? -this.items.length : this.items.length);
  }

  /** @param {number} vis @returns {void} */
  #scrollToVisible(vis) {
    const i = this.selectedIndex();
    if (i >= 0 && vis > 0) {
      if (i < this.scroll) this.scroll = i;
      else if (i >= this.scroll + vis) this.scroll = i - vis + 1;
    }
    this.#clampScroll(vis);
  }

  /** @param {number} vis @returns {void} */
  #clampScroll(vis) {
    const max = Math.max(0, this.items.length - Math.max(1, vis));
    this.scroll = Math.min(Math.max(this.scroll, 0), max);
  }

  /** @param {number} dir @returns {void} */
  navPage(dir) {
    this.navBy(dir * this.page);
  }

  // Forget the drawn rect when a container draws something else there, so a click cannot hit a row that left.
  /** @returns {void} */
  clearRect() {
    this.drawnRect = null;
  }

  // A wheel step moves the cursor, because `draw` always scrolls the selection back into view.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    const r = this.drawnRect;
    if (!r || ev.event !== "press") return false;
    if (isWheel(ev.button)) {
      // `scrollLines` counts screen lines, so a tall row moves fewer items per step.
      const step = Math.max(1, Math.round(config.mouse.scrollLines / this.itemHeight));
      const n = step * (ev.count || 1);
      if (ev.button === "wheel_up") this.navBy(-n);
      else if (ev.button === "wheel_down") this.navBy(n);
      else return false;
      return true;
    }
    if (ev.button !== "left") return false;
    if (!contains(r, ev.col, ev.row)) return false;
    // `draw` paints `_visible(h)` rows, so a short pane leaves the last row of the rect empty.
    const off = Math.floor((ev.row - r.y) / this.itemHeight);
    if (off >= this.#visible(r.h)) return false;
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
    this.drawnRect = rect;
    const vis = this.#visible(h);
    this.page = vis;
    this.#scrollToVisible(vis);

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
        const line = cell.lines ? normalizeCell(lines[ln]) : cell;
        this.#drawLine(x, sy + ln, w, line, isSel);
      }
    }
  }

  /** @param {number} x @param {number} sy @param {number} w @param {ListItem} spec @param {boolean} isSel @returns {void} */
  #drawLine(x, sy, w, spec, isSel) {
    let avail = w;
    if (spec.right) {
      const fullW = term.measure(spec.right);
      const r = fullW <= w ? spec.right : clip(spec.right, w, true, fullW);
      const rw = r === spec.right ? fullW : term.measure(r);
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
    const body = clip(/** @type {string} */ (spec.text), Math.max(0, avail - ind));
    text(x + ind, sy, body, g);
    // `detail` follows the text one cell later, dim, so a row reads as a name and its note.
    if (spec.detail) {
      const at = ind + term.measure(body) + 1;
      if (at < avail) {
        const dg = isSel ? spec.detailSelGroup || this.dimSelGroup : spec.detailGroup || this.dimGroup;
        text(x + at, sy, clip(spec.detail, avail - at), dg);
      }
    }
  }
}

// A message input grows with its text. Enter submits and the newline keys add a line.
export class Composer {
  /** @param {ComposerOptions} [opts] */
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.input = new TextInput({
      // A plugin follows the text through the bus, so the slash menu needs no hook on each pane.
      onChange: () => {
        this.#invalidate();
        events.emit("composer.changed", this);
      },
      onEdit: (from, to, ins) => this.#shiftSpans(from, to, ins),
    });
    this.prompt = opts.prompt != null ? opts.prompt : "› ";
    this.placeholder = opts.placeholder || "";
    this.onSubmit = opts.onSubmit || null;
    /** @type {((text: string, from: number) => boolean) | null} */
    this.onPaste = opts.onPaste || null;
    this.maxRows = opts.maxRows || COMPOSER_ROWS_MAX;
    this.scroll = 0;
    /** @type {number | null} */
    this.goalCol = null; // the column a vertical move holds across a short row
    // A collapsed span where the label replaces [start, end) on the screen only, so a submit still sends the buffer.
    /** @type {ComposerSpan[]} */
    this.spans = [];
    /** @type {WrapRow[] | null} */
    this.rows = null;
    this.rowsW = -1;
    /** @type {Projection | null} */
    this.proj = null;
  }

  // Drop the projection and the row cache after an edit, so both rebuild once per edit.
  /** @returns {void} */
  #invalidate() {
    this.rows = null;
    this.proj = null;
    this.goalCol = null;
  }

  // Move a span the edit did not touch. An edit inside a span drops the span and shows the paste.
  /** @param {number} from @param {number} to @param {number} ins @returns {void} */
  #shiftSpans(from, to, ins) {
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
    this.#invalidate();
  }

  // The text as the screen shows it: each collapsed span becomes its label.
  /** @returns {Projection} */
  projection() {
    if (this.proj) return this.proj;
    const s = this.input.text;
    if (this.spans.length === 0) {
      this.proj = { text: s, parts: [] };
      return this.proj;
    }
    const spans = this.spans.filter((sp) => sp.end > sp.start && sp.end <= s.length).sort((a, b) => a.start - b.start);
    if (spans.length !== this.spans.length) this.spans = spans;
    const parts = [];
    let out = "";
    let at = 0;
    // A label numbers by position within its kind, so a delete renumbers the spans after it.
    let image = 0;
    let paste = 0;
    for (const sp of spans) {
      if (sp.start < at) continue;
      out += s.slice(at, sp.start);
      const label = "blob" in sp ? imageLabel(sp.blob, ++image) : pasteLabel(++paste, s.slice(sp.start, sp.end));
      // `delta` is what the label adds to every offset after it.
      const start = out.length;
      parts.push({ span: sp, start, end: start + label.length, delta: label.length - (sp.end - sp.start) });
      out += label;
      at = sp.end;
    }
    this.proj = { text: out + s.slice(at), parts };
    return this.proj;
  }

  // The caret never rests inside a span, so the map adds the delta of every label before it.
  /** @param {number} caret @returns {number} */
  #toDisplay(caret) {
    let d = caret;
    for (const p of this.projection().parts) if (caret >= p.span.end) d += p.delta;
    return d;
  }

  // Map back, and push a caret that landed inside a label to its nearer edge.
  /** @param {number} disp @returns {number} */
  #toText(disp) {
    let t = disp;
    for (const p of this.projection().parts) {
      if (disp > p.start && disp < p.end) return disp - p.start < p.end - disp ? p.span.start : p.span.end;
      if (disp >= p.end) t -= p.delta;
    }
    return t;
  }

  /** @param {number} caret @returns {ComposerSpan | null} */
  #spanEndingAt(caret) {
    return this.spans.find((sp) => sp.end === caret) || null;
  }

  /** @param {number} caret @returns {ComposerSpan | null} */
  #spanStartingAt(caret) {
    return this.spans.find((sp) => sp.start === caret) || null;
  }

  /** @returns {string} */
  promptText() {
    const supplied = slot.get(this, "prompt");
    return typeof supplied === "string" ? supplied : this.prompt;
  }

  /** @param {number} w @returns {number} */
  #textWidth(w) {
    return Math.max(1, w - term.measure(this.promptText()));
  }

  /** @param {number} width @returns {{ start: number, end: number, soft: boolean }[]} */
  #rowsAt(width) {
    if (this.rows && this.rowsW === width) return this.rows;
    this.rowsW = width;
    this.rows = wrapPreview(this.projection().text, width, 0).rows;
    return this.rows;
  }

  // The rows the text needs. The caller caps this against the space it has.
  /** @param {number} w @returns {number} */
  height(w) {
    if (w <= 0) return 0;
    if (this.input.text === "") return 1;
    return Math.min(this.maxRows, this.#rowsAt(this.#textWidth(w)).length);
  }

  get name() {
    return "composer";
  }

  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }

  get text() {
    return this.input.text;
  }

  set text(s) {
    this.input.setText(s);
  }

  // The buffer as content parts: one text run between image spans, each image at its own position.
  /** @returns {Wire.ContentPart[]} */
  content() {
    const s = this.input.text;
    /** @type {Wire.ContentPart[]} */
    const out = [];
    let at = 0;
    // The projection already dropped a stale span and sorted the rest, so this walk reads the same order the screen does.
    for (const part of this.projection().parts) {
      const sp = part.span;
      if (!("blob" in sp)) continue;
      pushText(out, s.slice(at, sp.start));
      out.push({ type: "image", source: sp.blob });
      at = sp.end;
    }
    pushText(out, s.slice(at));
    // Only the edges of the whole input trim, so the space between a text run and an image stays.
    const first = out[0];
    if (first && first.type === "text") out[0] = { type: "text", text: first.text.trimStart() };
    const last = out[out.length - 1];
    if (last && last.type === "text") out[out.length - 1] = { type: "text", text: last.text.trimEnd() };
    return out;
  }

  // Whether the buffer holds an attachment, so an owner answers for the input it is about to send.
  /** @returns {boolean} */
  hasImages() {
    return this.spans.some((sp) => "blob" in sp);
  }

  // Save the buffer and its spans, so a failed send puts the images back with the text.
  /** @returns {ComposerSnapshot} */
  snapshot() {
    return { text: this.input.text, spans: this.spans.map((sp) => ({ ...sp })) };
  }

  // Put a snapshot back above the text the user typed since, and move every live span past the insert.
  /** @param {ComposerSnapshot} snap @returns {void} */
  restore(snap) {
    if (snap.text === "") return;
    this.input.replace(0, 0, this.input.text === "" ? snap.text : snap.text + "\n");
    this.spans.push(...snap.spans.map((sp) => ({ ...sp })));
    this.input.caret = this.input.text.length;
    this.#invalidate();
  }

  // Submit the content and not the projection, so a lost span can never send a label.
  /** @returns {void} */
  submit() {
    const content = this.content();
    if (content.length === 0) return;
    // The owner may reject synchronously (returns false): keep the buffer rather than blank it.
    if (this.onSubmit && this.onSubmit(content) === false) return;
    this.spans = [];
    this.input.setText("");
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    if (ev.type === "paste") return this.#paste(ev.text || "");
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
      const sp = s === "delete" ? this.#spanStartingAt(this.input.caret) : this.#spanEndingAt(this.input.caret);
      if (sp) {
        this.input.replace(sp.start, sp.end, "");
        return true;
      }
    }
    if (s === "left" || s === "right") {
      const sp = s === "left" ? this.#spanEndingAt(this.input.caret) : this.#spanStartingAt(this.input.caret);
      if (sp) {
        this.input.caret = s === "left" ? sp.start : sp.end;
        return true;
      }
    }
    return this.input.onKey(ev);
  }

  // Collapse a large paste to a label. The same paste beside its label expands it again.
  /** @param {string} t @returns {boolean} */
  #paste(t) {
    if (t === "") return true;
    const sides = [this.#spanEndingAt(this.input.caret), this.#spanStartingAt(this.input.caret)];
    const near = sides.find((sp) => sp && this.input.text.slice(sp.start, sp.end) === t);
    if (near) {
      this.spans = this.spans.filter((sp) => sp !== near);
      this.#invalidate();
      return true;
    }
    const from = this.input.caret;
    this.input.insert(t);
    // The owner may claim a paste, for example a path it attaches as an image. A claimed paste never collapses.
    if (this.onPaste && this.onPaste(t, from)) return true;
    if (t.length > COMPOSER_PASTE_CHARS || lineCount(t) >= COMPOSER_PASTE_LINES) {
      this.spans.push({ start: from, end: from + t.length });
      this.#invalidate();
    }
    return true;
  }

  // Turn the text at `from` into an attachment. An edit that moved or changed it cancels the attach.
  /** @param {number} from @param {string} text @param {Wire.MediaBlob} blob @returns {boolean} */
  attach(from, text, blob) {
    const end = from + text.length;
    if (text === "" || this.input.text.slice(from, end) !== text) return false;
    this.spans.push({ start: from, end, blob });
    this.#invalidate();
    return true;
  }

  // Move the caret one drawn row. The goal column survives a short row.
  /** @param {number} delta @returns {boolean} */
  moveRow(delta) {
    const rows = this.#rowsAt(this.#textWidth(this.rect.w));
    const proj = this.projection().text;
    const here = caretRowCol(proj, rows, this.#toDisplay(this.input.caret));
    const col = this.goalCol === null ? here.col : this.goalCol;
    const next = here.row + delta;
    if (next >= 0 && next < rows.length) {
      const row = /** @type {WrapRow} */ (rows[next]);
      this.input.caret = this.#toText(caretAtCol(proj, row, col));
      this.goalCol = col;
    }
    return true;
  }

  /** @param {boolean} _focused @returns {void} */
  draw(_focused) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    fill(x, y, w, h, "UIComposer");
    if (this.input.text === "") {
      this.scroll = 0;
      text(x, y, clip(this.promptText() + this.placeholder, w), "UIDim");
      return;
    }

    const tw = this.#textWidth(w);
    const rows = this.#rowsAt(tw);
    const proj = this.projection().text;
    // Scroll the smallest amount that keeps the caret row on the screen.
    const { row: caretRow } = caretRowCol(proj, rows, this.#toDisplay(this.input.caret));
    this.scroll = Math.min(this.scroll, Math.max(0, rows.length - h));
    if (caretRow < this.scroll) this.scroll = caretRow;
    else if (caretRow >= this.scroll + h) this.scroll = caretRow - h + 1;
    const pw = w - tw;
    // The prompt marks the first row only. A later row aligns under it.
    if (this.scroll === 0) text(x, y, this.promptText(), "UIComposer");
    for (let i = 0; i < h && this.scroll + i < rows.length; i++) {
      const r = /** @type {WrapRow} */ (rows[this.scroll + i]);
      text(x + pw, y + i, clip(proj.slice(r.start, r.end), tw, false), "UIComposer");
    }
  }

  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return null;
    const tw = this.#textWidth(w);
    const rows = this.#rowsAt(tw);
    const { row, col } = caretRowCol(this.projection().text, rows, this.#toDisplay(this.input.caret));
    const vy = row - this.scroll;
    if (vy < 0 || vy >= h) return { x, y, visible: false };
    // A space hangs past the right edge, so the caret column clamps to the last cell.
    return { x: x + (w - tw) + Math.min(col, tw - 1), y: y + vy, visible: true };
  }
}

// A retained text leaf wraps during layout, so paint only copies its cached visible rows.
export class Text {
  /** @param {TextOptions} [opts] */
  constructor(opts = {}) {
    this.text = opts.text || "";
    this.group = opts.group || "Normal";
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.measurement = { text: "", width: 0, size: { w: 0, h: 0 }, rows: /** @type {WrapRow[]} */ ([]), widths: /** @type {number[]} */ ([]) };
    /** @type {{ text: string, width: number, height: number, rows: string[] }} */
    this.layoutCache = { text: "", width: 0, height: 0, rows: [] };
  }

  /** @param {string} value @returns {void} */
  setText(value) {
    const textValue = String(value);
    if (textValue === this.text) return;
    this.text = textValue;
    root.invalidate();
  }

  /** @param {number} width @returns {{ w: number, h: number }} */
  measure(width) {
    width = Math.max(0, Math.floor(width));
    const cache = this.measurement;
    if (cache.width === width && cache.text === this.text) return cache.size;
    const rows = width > 0 ? wrapPreview(this.text, width, 0).rows : [];
    const widths = rows.map((row) => term.measure(this.text.slice(row.start, row.end)));
    let w = 0;
    for (const rw of widths) w = Math.max(w, rw);
    const size = { w: Math.min(width, w), h: rows.length };
    this.measurement = { text: this.text, width, size, rows, widths };
    return size;
  }

  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
    const cache = this.layoutCache;
    if (cache.text === this.text && cache.width === rect.w && cache.height === rect.h) return;
    // Reuse the measured rows at the same width. Measure the rows again when the width changes.
    const m = this.measurement.text === this.text && this.measurement.width === rect.w ? this.measurement : null;
    const rows = rect.w > 0 && rect.h > 0 ? (m ? m.rows : wrapPreview(this.text, rect.w, 0).rows).slice(0, rect.h) : [];
    this.layoutCache = { text: this.text, width: rect.w, height: rect.h, rows: rows.map((row, i) => {
      const line = this.text.slice(row.start, row.end);
      const lw = m ? /** @type {number} */ (m.widths[i]) : term.measure(line);
      return lw <= rect.w ? line : clip(line, rect.w, false, lw);
    }) };
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    const rows = this.layoutCache.rows;
    for (let i = 0; i < rows.length; i++) text(x, y + i, /** @type {string} */ (rows[i]), this.group);
  }
}

// The composer stops growing here, so the transcript keeps its room.
const COMPOSER_ROWS_MAX = 10;

// A paste over one of these collapses to a label.
const COMPOSER_PASTE_LINES = 3;
const COMPOSER_PASTE_CHARS = 150;

// A newline at the end closes the last line. It does not open an empty one.
/** @param {string} t @returns {number} */
function lineCount(t) {
  const end = t.length > 0 && t[t.length - 1] === "\n" ? t.length - 1 : t.length;
  let n = 1;
  for (let i = t.indexOf("\n"); i >= 0 && i < end; i = t.indexOf("\n", i + 1)) n++;
  return n;
}

// `[PNG #1]`: the type comes from the mime, because the wire carries no file name for an image.
/** @param {Wire.MediaBlob} blob @param {number} n @returns {string} */
function imageLabel(blob, n) {
  const slash = blob.mime.indexOf("/");
  return "[" + (slash < 0 ? blob.mime : blob.mime.slice(slash + 1)).toUpperCase() + " #" + n + "]";
}

// Add one text run as the user typed it. A run of whitespace alone carries nothing, so it never becomes a part.
/** @param {Wire.ContentPart[]} out @param {string} run @returns {void} */
function pushText(out, run) {
  if (run.trim() !== "") out.push({ type: "text", text: run });
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

// A floating, bordered, titled window as an overlay layer.
export class Window {
  /** @param {WindowOptions} [opts] */
  constructor(opts = {}) {
    this.opts = opts;
    this.modal = opts.modal !== false;
    this.border = opts.border === undefined ? "single" : opts.border;
    this.content = opts.content || null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.inner = { x: 0, y: 0, w: 0, h: 0 };
    if (this.content && (typeof this.content.layout !== "function" || typeof this.content.draw !== "function")) throw new TypeError("window content needs layout and draw methods");
    if (this.content) claimView(this.content, this);
  }

  /** @returns {string} */
  get name() {
    return this.opts.name || "window";
  }

  /** @returns {BorderSet | null} */
  #borderSet() {
    const b = this.border;
    if (b === "none" || b == null) return null;
    return typeof b === "object" ? b : borders[b] || borders.single;
  }

  /** @param {number} width @returns {number} */
  contentWidth(width) {
    return Math.max(0, width - (this.#borderSet() ? 6 : 0));
  }

  /** @param {number} rows @returns {number} */
  heightFor(rows) {
    return rows + (this.#borderSet() ? 4 : 0) + (this.opts.footer ? 1 : 0);
  }

  // Resolve a cell count or a callback against a maximum available size.
  /** @param {Dimension | null | undefined} v @param {number} max @param {number} fallback @returns {number} */
  #dim(v, max, fallback) {
    if (v == null) return fallback;
    const cells = typeof v === "function" ? v(max) : v;
    if (!Number.isSafeInteger(cells) || cells < 0) throw new TypeError("window dimension must be a non-negative integer");
    return cells;
  }

  /** @param {Rect} bounds @returns {void} */
  layout(bounds) {
    const X = bounds.x;
    const Y = bounds.y;
    const W = bounds.w;
    const H = bounds.h;
    const pad = this.#borderSet() ? 2 : 0;

    const anchor = this.opts.anchor ? this.opts.anchor() : null;
    const available = anchor ? Math.max(0, Math.min(H, anchor.y - Y)) : H;
    const w = Math.min(W, Math.max(pad + 1, this.#dim(this.opts.width, anchor ? anchor.w : W, anchor ? anchor.w : Math.round(W * 0.6))));
    const contentHeight = this.opts.contentHeight;
    const desired = this.opts.height != null ? this.#dim(this.opts.height, available, 0)
      : contentHeight != null ? this.heightFor(this.#dim(contentHeight, Math.max(0, available - this.heightFor(0)), 0))
      : Math.round(available * 0.6);
    const h = Math.min(available, Math.max(pad + 1, desired));
    const x = anchor ? Math.max(X, Math.min(anchor.x, X + W - w)) : X + Math.max(0, Math.floor((W - w) / 2));
    const y = anchor ? Y + available - h : Y + Math.max(0, Math.floor((H - h) / 2));
    this.rect = { x, y, w, h };
    // The content excludes the border, shared padding, and the footer row.
    this.inner = { x: x + (pad ? 3 : 0), y: y + pad, w: this.contentWidth(w), h: Math.max(0, h - this.heightFor(0)) };
    if (this.content) this.content.layout(this.inner);
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.rect;
    // A window with no room draws nothing, so a border never lands on the row above it.
    if (w <= 0 || h <= 0) return;
    fill(x, y, w, h, this.opts.panelGroup || "UIPanel");
    const bs = this.#borderSet();
    if (bs) this.#drawBorder(bs);
    if (this.content) this.content.draw(_focused);
    const footerY = y + h - (bs ? 2 : 1);
    if (footerY >= y + (bs ? 1 : 0)) this.#drawLabel(this.opts.footer, this.opts.footer_pos, footerY, this.opts.footerGroup || "UIDim", this.inner.x, this.inner.w);
  }

  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    return this.content && this.content.cursor ? this.content.cursor() : null;
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    return this.content && this.content.onKey ? this.content.onKey(ev) : false;
  }

  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    if (ev.event === "press" && !contains(this.inner, ev.col, ev.row)) return false;
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
  #drawBorder(bs) {
    const { x, y, w, h } = this.rect;
    const g = this.opts.borderGroup || "UIBorder";
    const span = Math.max(0, w - 2);
    text(x, y, bs.tl + bs.t.repeat(span) + bs.tr, g);
    text(x, y + h - 1, bs.bl + bs.b.repeat(span) + bs.br, g);
    for (let i = 1; i < h - 1; i++) {
      text(x, y + i, bs.l, g);
      text(x + w - 1, y + i, bs.r, g);
    }
    this.#drawLabel(this.opts.title, this.opts.title_pos, y, this.opts.titleGroup || "UITitle");
  }

  // The title uses the border edge; the footer uses the content columns.
  /** @param {string | (() => string) | undefined} label @param {"left" | "center" | "right" | undefined} pos @param {number} ry @param {string} group @param {number} [x] @param {number} [w] @returns {void} */
  #drawLabel(label, pos, ry, group, x = this.rect.x + 2, w = Math.max(0, this.rect.w - 4)) {
    if (!label) return;
    const s = typeof label === "function" ? label() : String(label);
    if (!s) return;
    if (w <= 0) return;
    const t = clip(s, w);
    if (pos === "center") x += Math.floor((w - term.measure(t)) / 2);
    else if (pos === "right") x += w - term.measure(t);
    text(x, ry, t, group);
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
    this.body = opts.body || "";
    /** @type {WrapRow[]} */
    this.bodyRows = [];
    this.bodyWidth = -1;
    this.bodyText = "";
    this.bodyScroll = 0;
    /** @type {Rect} */
    this.layoutRect = { x: 0, y: 0, w: 0, h: 0 };
    this.refilter();
  }

  /** @param {number} width @returns {number} */
  #bodyHeight(width) {
    width = Math.max(1, width);
    if (this.bodyWidth !== width || this.bodyText !== this.body) {
      this.bodyWidth = width;
      this.bodyText = this.body;
      this.bodyRows = this.body ? wrapPreview(this.body, width, 0).rows : [];
    }
    return this.bodyRows.length;
  }

  /** @param {Rect} r @returns {{ height: number, gap: number }} */
  bodyLayout(r) {
    const rows = this.#bodyHeight(r.w);
    const gap = rows > 0 && r.h >= 4 ? 1 : 0;
    return { height: Math.min(rows, Math.max(0, r.h - 2 - gap)), gap };
  }

  /** @param {number} width @returns {number} */
  preferredHeight(width) {
    const contentWidth = Math.max(1, this.win ? this.win.contentWidth(width) : width);
    const bodyRows = this.#bodyHeight(contentWidth);
    const gap = bodyRows > 0 ? 1 : 0;
    const rows = bodyRows + gap + (this.filter ? 1 : 0) + this.list.items.length * this.list.itemHeight;
    return this.win ? this.win.heightFor(rows) : rows;
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

  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    return this.opts.needsTick || null;
  }

  /** @returns {void} */
  close() {
    root.popOverlay(/** @type {Window} */ (this.win));
  }

  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.layoutRect = rect;
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.layoutRect;
    if (w <= 0 || h <= 0) {
      this.list.clearRect();
      return;
    }
    const layout = this.bodyLayout({ x, y, w, h });
    const { height: bodyHeight, gap } = layout;
    this.bodyScroll = Math.min(this.bodyScroll, Math.max(0, this.bodyRows.length - bodyHeight));
    for (let i = 0; i < bodyHeight; i++) {
      const row = this.bodyRows[this.bodyScroll + i];
      if (!row) break;
      text(x, y + i, this.body.slice(row.start, row.end), "UIBody");
    }
    const listY = y + bodyHeight + gap;
    const listH = Math.max(0, h - bodyHeight - gap);
    if (!this.filter) {
      this.list.draw({ x, y: listY, w, h: listH });
      return;
    }
    if (listH <= 0) return this.list.clearRect();
    text(x, listY, clip(PICKER_PROMPT, w), "UIPrompt");
    const pw = term.measure(PICKER_PROMPT);
    if (pw < w) text(x + pw, listY, clip(this.query, w - pw), "UIQuery");
    if (listH > 1) this.list.draw({ x, y: listY + 1, w, h: listH - 1 });
    else this.list.clearRect();
  }

  // A float takes only the mouse over its own rows, so a wheel over the pane still scrolls the pane.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    const win = this.win;
    if (win && win.modal === false && !contains(win.rect, ev.col, ev.row)) return false;
    if (this.body && ev.event === "press" && isWheel(ev.button) && win) {
      const r = this.layoutRect;
      const { height: bodyHeight } = this.bodyLayout(r);
      if (ev.row >= r.y && ev.row < r.y + bodyHeight) {
        const step = config.mouse.scrollLines * (ev.count || 1);
        const max = Math.max(0, this.bodyRows.length - bodyHeight);
        this.bodyScroll = Math.min(max, Math.max(0, this.bodyScroll + (ev.button === "wheel_down" ? step : -step)));
        root.invalidate();
        return true;
      }
    }
    return this.list.onMouse(ev);
  }

  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    if (!this.input) return null; // a menu edits no query, so it places no cursor
    const { x, y, w, h } = this.layoutRect;
    if (w <= 0 || h <= 0) return null; // an empty interior places no cursor
    const { height: bodyHeight, gap } = this.bodyLayout({ x, y, w, h });
    const rowY = y + bodyHeight + gap;
    const col = caretCol(w, PICKER_PROMPT, this.input.beforeCaret());
    return { x: Math.min(x + Math.max(0, col), x + Math.max(0, w - 1)), y: Math.min(rowY, y + Math.max(0, h - 1)), visible: true };
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
      case "accept": return this.accept();
      case "cancel": return this.cancel();
      case "close": return this.close();
      case "next": return this.list.navBy(1);
      case "prev": return this.list.navBy(-1);
      case "top": return this.list.navEdge(-1);
      case "bottom": return this.list.navEdge(1);
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
    // A float leaves every other key to the view under it, so the composer keeps typing.
    if (this.win && this.win.modal === false) return false;
    if (this.body && this.win && (s === "page_up" || s === "page_down")) {
      const { height } = this.bodyLayout(this.layoutRect);
      const max = Math.max(0, this.bodyRows.length - height);
      if (height > 0 && max > 0) {
        this.bodyScroll = Math.min(max, Math.max(0, this.bodyScroll + (s === "page_down" ? height : -height)));
        root.invalidate();
        return true;
      }
    }
    // A menu navigates with the shared table. A finder gives every other key to the query.
    if (!this.filter) {
      const nav = NAV_KEYS[s];
      if (nav) nav(this.list);
      return true;
    }
    if (s === "up" || s === "ctrl+p") {
      this.list.navBy(-1);
      return true;
    }
    if (s === "down" || s === "ctrl+n") {
      this.list.navBy(1);
      return true;
    }
    /** @type {TextInput} */ (this.input).onKey(ev); // the shared buffer takes the edit; its onChange refilters
    return true; // modal: consume every key
  }
}

// A one-line prompt as window content. The prompt answers its text on Enter and no value on Escape.
export class Prompt {
  /** @param {PromptOptions} opts */
  constructor(opts) {
    this.placeholder = opts.placeholder || "";
    this.mask = !!opts.mask;
    this.settle = opts.settle;
    this.input = new TextInput({ onChange: () => root.invalidate() });
    /** @type {Rect} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  // The text as the screen shows it. A masked prompt paints one dot for each grapheme, so a key never shows.
  /** @param {string} s @returns {string} */
  shown(s) {
    if (!this.mask) return s;
    let n = 0;
    for (let at = 0; at < s.length; at = nextGrapheme(s, at)) n++;
    return "•".repeat(n);
  }

  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const empty = this.input.text === "";
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    text(x, y, clip(PICKER_PROMPT, w), "UIPrompt");
    if (w > 2) text(x + 2, y, clip(empty ? this.placeholder : this.shown(this.input.text), w - 2), empty ? "UIDim" : "UIQuery");
  }

  /** @returns {{ x: number, y: number, visible: boolean }} */
  cursor() {
    const col = caretCol(this.rect.w, PICKER_PROMPT, this.shown(this.input.beforeCaret()));
    return { x: this.rect.x + col, y: this.rect.y, visible: this.rect.w > 0 && this.rect.h > 0 };
  }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    // One line holds the value, so a pasted line ending never becomes part of it.
    if (event.type === "paste") {
      this.input.insert((event.text || "").replace(/[\r\n]+/g, ""));
      return true;
    }
    if (event.type !== "key") return false;
    const stroke = strokeOf(event);
    if (stroke === "enter") this.settle(this.input.text);
    else if (stroke === "esc") this.settle(undefined);
    else this.input.onKey(event);
    root.invalidate();
    return true;
  }
}

// The kit's public surface. `select` navigates a set, `pick` adds the query line, and both build { win, content }.
// A builder shows nothing; `ctx.tui.overlay(win)` shows the window, so a plugin owns every overlay it opens.
export const ui = {
  /** @template T @param {T[]} items @param {PickOptions<T>} [opts] @returns {{ win: Window, content: Picker<T> }} */
  select(items, opts = {}) {
    return ui.pick({ ...opts, items: items || [], filter: false });
  },

  /** @template T @param {PickOptions<T>} [opts] @returns {{ win: Window, content: Picker<T> }} */
  pick(opts = {}) {
    const content = new Picker(opts);
    const rows = opts.maxRows;
    const fit = rows ? { contentHeight: () => (content.filter ? 1 : 0) + Math.min(rows, content.list.items.length) } : {};
    const win = new Window({ ...fit, ...opts, content: /** @type {WindowContent} */ (content) });
    content.win = win;
    return { win, content };
  },
};
