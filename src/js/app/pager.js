// Scroll and paint rows with source-coordinate maps.
import { term } from "yuke:internal/native/term";
import { style, resolveStyleOn, overlayStyleGroup, isWheel } from "yuke:internal/core";
import { config } from "yuke:internal/kernel";
import { clip } from "yuke:internal/text-input";
import { isLinear } from "yuke:internal/md";
/** @import { HostMouseEvent as MouseEvent, Rect } from "./types/core.js" */
/** @import { RowSource, Segment, TranscriptRow } from "./types/pager.js" */
/**
 * The scroll state and the painter for the rows of a `RowSource`. It is a `NavTarget`, so the nav keys move it.
 * While `stuck` is true, the view follows the tail as rows arrive.
 */
export class Pager {
  constructor() {
    /** @type {RowSource} */
    this.source = staticRowSource([]);
    /** The index of the first row that shows. */
    this.scroll = 0;
    /** True while the view follows the tail. */
    this.stuck = true;
    this._h = 0;
    this._w = 0;
    /** @type {Rect | null} */
    this._rect = null; // the last drawn rect, for the mouse hit test
  }

  /**
   * The last drawn rect, or null before a draw or after `clearRect`.
   * @returns {Rect | null}
   */
  rect() {
    return this._rect;
  }

  /** Forget the drawn rect, so a click cannot hit a row that left. */
  clearRect() {
    this._rect = null;
  }

  /**
   * The source row index under screen row `y`. Return -1 outside the drawn rows.
   * @param {number} y
   * @returns {number}
   */
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

  /**
   * True when the last row shows.
   * @returns {boolean}
   */
  atBottom() {
    return this.scroll >= this._maxScroll();
  }

  /** Scroll to the tail and follow it. */
  toBottom() {
    this.scroll = this._maxScroll();
    this.stuck = true;
  }

  /** Scroll to the first row and stop following the tail. */
  toTop() {
    this.scroll = 0;
    this.stuck = false;
  }

  /**
   * Scroll by `delta` rows, inside the range. At the end, the view follows the tail again.
   * @param {number} delta
   */
  scrollBy(delta) {
    const max = this._maxScroll();
    this.scroll = Math.min(Math.max(0, this.scroll + delta), max);
    this.stuck = this.scroll >= max;
  }

  /**
   * Scroll the least that puts row `index` on the screen, and refresh `stuck` so an unfold cannot jump to the tail.
   * @param {number} index
   */
  scrollIntoView(index) {
    if (index < 0 || this._h <= 0) return;
    let next = this.scroll;
    if (index < next) next = index;
    else if (index >= next + this._h) next = index - this._h + 1;
    this.scrollBy(next - this.scroll);
  }

  /**
   * Read the rows from `source`. The next draw keeps the scroll in range.
   * @param {RowSource} source
   */
  setSource(source) {
    this.source = source || staticRowSource([]);
  }

  /**
   * Show a fixed array of rows.
   * @param {TranscriptRow[]} rows
   */
  setRows(rows) {
    this.setSource(staticRowSource(rows));
    this._clamp();
  }

  // Keep the scroll offset in range as the row count changes. A scroll to the tail re-sticks.
  _clamp() {
    const max = this._maxScroll();
    this.scroll = this.stuck ? max : Math.min(Math.max(0, this.scroll), max);
    if (this.scroll >= max) this.stuck = true;
  }

  /**
   * Paint the rows that show in `rect`, and keep this rect for the mouse and the page size.
   * @param {Rect} rect
   */
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
      if (r.bg) term.fill(x, sy, w, 1, style.resolve(r.bg));
      if (r.marker) {
        const group = /** @type {string} */ (r.markerGroup);
        if (r.bg) term.text(x, sy, r.marker, resolveStyleOn(group, r.bg));
        else term.text(x, sy, r.marker, style.resolve(group));
      }
      const ind = r.indent || 0;
      let segs = r.segments || (r.text ? segmentsOf(r) : undefined);
      if (segs && r.sel) segs = markSelection(segs, r.sel.from, r.sel.to, r.selGroup || "TxSelect");
      if (segs) drawSegments(x + ind, sy, Math.max(0, w - ind), segs, r.bg);
    }
  }

  /** @param {number} delta */
  navBy(delta) {
    this.scrollBy(delta);
  }

  /**
   * Scroll by `dir` pages. A page is one row less than the drawn height.
   * @param {number} dir
   */
  navPage(dir) {
    this.scrollBy(dir * Math.max(1, this._h - 1));
  }

  /**
   * Scroll to the top when `dir` is negative, else to the tail.
   * @param {number} dir
   */
  navEdge(dir) {
    if (dir < 0) this.toTop();
    else this.toBottom();
  }

  /**
   * Scroll on a wheel press. Answer false for any other event.
   * The wheel scrolls by `config.mouse.scrollLines` per step, and `ev.count` holds the steps the owner folded in.
   * @param {MouseEvent} ev
   * @returns {boolean}
   */
  onMouse(ev) {
    if (!isWheel(ev.button) || ev.event !== "press") return false;
    const n = config.mouse.scrollLines * (ev.count || 1);
    if (ev.button === "wheel_up") this.scrollBy(-n);
    else if (ev.button === "wheel_down") this.scrollBy(n);
    else return false;
    return true;
  }
}

// The one segment of a text row, with a source or without one. A draw and a source read fill it, so neither allocates for a text row.
/** @type {Segment} */
const PLAIN = { text: "", group: "" };
/** @type {Required<Pick<Segment, "text" | "group" | "src" | "srcEnd">>} */
const SOURCED = { text: "", group: "", src: 0, srcEnd: 0 };
const PLAIN_ROW = [PLAIN];
const SOURCED_ROW = [SOURCED];

/**
 * The segments of a row. A text row answers one held segment that the next call fills again, so use the answer at once and do not keep it.
 * A text row with `src` shows its source as it is, so its one segment is linear.
 * @param {TranscriptRow} r @returns {Segment[] | undefined}
 */
export function segmentsOf(r) {
  if (r.segments) return r.segments;
  if (r.text === undefined && r.src === undefined) return undefined;
  const text = r.text || "";
  const group = r.group || "";
  if (r.src === undefined) {
    PLAIN.text = text;
    PLAIN.group = group;
    return PLAIN_ROW;
  }
  SOURCED.text = text;
  SOURCED.group = group;
  SOURCED.src = r.src;
  SOURCED.srcEnd = r.src + text.length;
  return SOURCED_ROW;
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
  const segments = segmentsOf(row);
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
  const segments = segmentsOf(row);
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

// Repaint the string range [from, to) of `segments` with an overlay; `caretAtCol` puts the bounds on a grapheme edge.
/** @param {Segment[]} segments @param {number} from @param {number} to @param {string} group @returns {Segment[]} */
function markSelection(segments, from, to, group) {
  if (to <= from) return segments;
  const out = [];
  let at = 0;
  for (const seg of segments) {
    const end = at + seg.text.length;
    const a = from > at ? from : at;
    const b = to < end ? to : end;
    if (b <= a) {
      out.push(seg);
    } else {
      if (a > at) out.push({ ...seg, text: seg.text.slice(0, a - at) });
      out.push({ ...seg, text: seg.text.slice(a - at, b - at), group: overlayStyleGroup(seg.group, group) });
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
/** @param {number} x @param {number} sy @param {number} w @param {Segment[]} segments @param {string | undefined} background */
function drawSegments(x, sy, w, segments, background) {
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
      if (seg.text) {
        if (background) term.text(cx, sy, seg.text, resolveStyleOn(seg.group, background));
        else term.text(cx, sy, seg.text, style.resolve(seg.group));
      }
      cx += /** @type {number} */ (segmentWidths[i]);
    }
    return;
  }

  // The last cell holds the ellipsis, and it takes the group of the run it cuts.
  const room = w - 1;
  let cutGroup;
  for (let i = 0; i < segments.length; i++) {
    const seg = /** @type {Segment} */ (segments[i]);
    const avail = room - (cx - x);
    if (avail <= 0) break;
    const cells = /** @type {number} */ (segmentWidths[i]);
    // A run that fits keeps its measured width, so only the cut run measures again.
    if (cells <= avail) {
      if (seg.text) {
        if (background) term.text(cx, sy, seg.text, resolveStyleOn(seg.group, background));
        else term.text(cx, sy, seg.text, style.resolve(seg.group));
      }
      cx += cells;
    } else {
      const t = clip(seg.text, avail, false, cells);
      if (t) {
        if (background) term.text(cx, sy, t, resolveStyleOn(seg.group, background));
        else term.text(cx, sy, t, style.resolve(seg.group));
      }
      cx += term.measure(t);
    }
    cutGroup = seg.group;
  }
  const group = /** @type {string} */ (cutGroup);
  if (background) term.text(x + room, sy, "…", resolveStyleOn(group, background));
  else term.text(x + room, sy, "…", style.resolve(group));
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
