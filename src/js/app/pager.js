// Scroll and paint rows with source-coordinate maps.
import { term } from "yuke:term";
import { text, fill, isWheel, config } from "yuke:core";
import { clip } from "yuke:text-input";
import { isLinear } from "yuke:md";
/** @typedef {import("yuke:core").Rect} Rect */
/** @typedef {Extract<HostEvent, { type: "mouse" }>} MouseEvent */

/** @typedef {{ segments?: Segment[] | undefined, text?: string | undefined, group?: string | undefined, bg?: string | undefined, marker?: string | null | undefined, markerGroup?: string | undefined, indent?: number | undefined, key?: ItemKey | undefined, kind?: string | undefined, partId?: number | undefined, sel?: { from: number, to: number } | undefined, selGroup?: string | undefined }} TranscriptRow */
/** @typedef {{ text: string, group: string, src?: number, srcEnd?: number, mark?: boolean }} Segment */
/** @typedef {string | number} ItemKey */
/** @typedef {{ rowCount: (width: number) => number, rows: (width: number, top: number, height: number) => TranscriptRow[] }} RowSource */
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
    const max = this._maxScroll();
    this.scroll = Math.min(Math.max(0, this.scroll + delta), max);
    this.stuck = this.scroll >= max;
  }

  // Scroll the least that puts row `index` on the screen, and refresh `stuck` so an unfold cannot jump to the tail.
  /** @param {number} index @returns {void} */
  scrollIntoView(index) {
    if (index < 0 || this._h <= 0) return;
    let next = this.scroll;
    if (index < next) next = index;
    else if (index >= next + this._h) next = index - this._h + 1;
    const max = this._maxScroll();
    this.scroll = Math.min(Math.max(0, next), max);
    this.stuck = this.scroll >= max;
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
    const max = this._maxScroll();
    this.scroll = this.stuck ? max : Math.min(Math.max(0, this.scroll), max);
    if (this.scroll >= max) this.stuck = true;
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

  /** @param {number} delta @returns {void} */
  navBy(delta) {
    this.scrollBy(delta);
  }

  /** @param {number} dir @returns {void} */
  navPage(dir) {
    this.scrollBy(dir * Math.max(1, this._h - 1));
  }

  /** @param {number} dir @returns {void} */
  navEdge(dir) {
    if (dir < 0) this.toTop();
    else this.toBottom();
  }

  // The wheel scrolls by `config.mouse.scrollLines` per step, and `ev.count` holds the steps the owner folded in.
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

// The source span under the rendered range [from, to), or null when the range maps to no source at all.
/** @param {TranscriptRow} row @param {number} from @param {number} to @param {number} [base] @returns {{ from: number, to: number } | null} */
export function rowSourceSpan(row, from, to, base = 0) {
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
      const s = base + (linear && b > a ? seg.src + (a - at) : seg.src);
      const e = base + (linear && b > a ? seg.src + (b - at) : /** @type {number} */ (seg.srcEnd));
      if (lo < 0 || s < lo) lo = s;
      if (e > hi) hi = e;
    }
    at = end;
  }
  return lo < 0 ? null : { from: lo, to: hi };
}

// The source offset at caret column `col`, where a gap takes the source end before it, or -1 when the row has none.
/** @param {TranscriptRow} row @param {number} col @param {number} [base] @returns {number} */
export function rowSourceAt(row, col, base = 0) {
  const segments = row.segments;
  if (!segments) return -1;
  let at = 0;
  let last = -1;
  for (const seg of segments) {
    const end = at + seg.text.length;
    if (seg.src != null) {
      if (col < at) return last < 0 ? base + seg.src : base + last;
      if (col < end) return base + (isLinear(seg) ? seg.src + (col - at) : seg.src);
      last = /** @type {number} */ (seg.srcEnd);
    }
    at = end;
  }
  return last < 0 ? last : base + last;
}

// Repaint the string range [from, to) of `segments` with `group`; `caretAtCol` puts the bounds on a grapheme edge.
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

// The synchronous row painter reuses numeric scratch space and retains no segment objects.
/** @type {number[]} */
const segmentWidths = [];

// Clip the row as one string, so a split run never repeats the ellipsis.
/** @param {number} x @param {number} sy @param {number} w @param {Segment[]} segments @returns {void} */
function drawSegments(x, sy, w, segments) {
  if (w <= 0) return;
  let total = 0;
  for (let i = 0; i < segments.length; i++) {
    const seg = /** @type {Segment} */ (segments[i]);
    const cells = seg.text ? term.measure(seg.text) : 0;
    segmentWidths[i] = cells;
    total += cells;
  }

  let cx = x;
  if (total <= w) {
    for (let i = 0; i < segments.length; i++) {
      const seg = /** @type {Segment} */ (segments[i]);
      if (seg.text) text(cx, sy, seg.text, seg.group);
      cx += /** @type {number} */ (segmentWidths[i]);
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
