// yuke:transcript — the chat transcript, its row rendering, and the pane that holds it.
import { term } from "yuke:term";
import { text, clip, root, caretAtCol, wrapOffsets, nextGrapheme, events, slot, isWheel, fill, config } from "yuke:core";
import { Document, isLinear } from "yuke:md";
import { Composer } from "yuke:ui";

/** @typedef {{ rowCount: (width: number) => number, rows: (width: number, top: number, height: number) => TranscriptRow[] }} RowSource */
/** @typedef {{ id: number, type: "user" | "assistant" | "compaction", source?: Wire.InputSource, error?: { type: string, message: string } }} MessageDescriptor */
/** @typedef {{ anchor: Position, cursor: Position }} Selection */
/** @typedef {{ id: number, partId: number, kind: string }} PartHit */
/** @typedef {{ a: { id: number, off: number, was: string }, b: { id: number, off: number, was: string } }} SelectionAnchors */
/** @typedef {{ start: Position, end: Position, si: number, ei: number }} SelectionRange */
/** @typedef {{ w: number, rows: TranscriptRow[], source: string, blocks: { kind: string, at: number, end: number }[] | null }} RowCache */
/** @typedef {{ w: number, expanded: boolean, live: boolean, base: number, rows: TranscriptRow[], source: string, blocks: { kind: string, at: number, end: number }[], doc: Document | null }} PartCache */
/** @typedef {{ list: Wire.AssistantPart[] | null, rows: Map<string, PartCache> }} PartState */
/** @typedef {(id: number) => readonly Wire.AssistantPart[]} PartsOf */
/** @typedef {(id: number, partId: number) => Wire.AssistantPart | null} PartOf */
/** @typedef {{ id: number, lang: string, text: string }} CodeBlock */
/** @typedef {{ textOf?: ((id: number) => string) | undefined, partsOf?: PartsOf | null | undefined, partOf?: PartOf | null | undefined, onSelect?: ((text: string) => void) | null | undefined, empty?: (() => readonly (string | { text?: unknown, group?: string })[] | null) | null | undefined }} TranscriptOptions */
/** @typedef {"composer" | "transcript"} ChatRegion */
/** @typedef {{ text: string, group?: string }} StripRow */
/** @typedef {{ textOf?: ((id: number) => string) | undefined, partsOf?: PartsOf | null | undefined, partOf?: PartOf | null | undefined, onSelect?: ((text: string) => void) | null | undefined, onSubmit?: ((text: string) => boolean | void) | null | undefined, empty?: (() => readonly (string | { text?: unknown, group?: string })[] | null) | null | undefined }} ChatViewOptions */
/** @typedef {{ x: number, y: number, w: number, h: number }} Rect */
/** @typedef {string | number} ItemKey */
/** @typedef {{ type: "mouse", col: number, row: number, button: string, event: string, mods: number, count: number }} MouseEvent */
/** @typedef {{ text: string, group: string, src?: number, srcEnd?: number, mark?: boolean }} Segment */
/** @typedef {{ segments?: Segment[] | undefined, text?: string | undefined, group?: string | undefined, bg?: string | undefined, marker?: string | null | undefined, markerGroup?: string | undefined, indent?: number | undefined, key?: ItemKey | undefined, kind?: string | undefined, partId?: number | undefined, sel?: { from: number, to: number } | undefined, selGroup?: string | undefined }} TranscriptRow */
/** @typedef {{ id: number, row: number, col: number }} Position */

// Left gutter for a transcript row marker; the body indents past it.
const TX_GUTTER = 2;

// Keep a long tool body inside the pager. The replica still holds the full output.
const TOOL_BODY_CAP = 40;
const REPORT_PREVIEW_LINES = 8;

/** @param {Wire.InputSource | undefined | null} source @returns {string} */
export function inputSourceLabel(source) {
  if (!source || source.type === "parent_instruction") return "";
  if (source.type === "child_report") return "Message from " + source.name + " · " + (source.outcome.type === "turn" ? "completed" : source.outcome.type) + (source.partial ? " · partial" : "") + (source.truncated ? " · model report truncated" : "");
  if (source.type === "child_input_canceled") return "Message from " + source.name + " · queued work canceled";
  return "Engine notice · run " + source.run_id + " interrupted";
}


// Rendered messages beyond this count leave the cache oldest first; the viewport and live anchors never leave.
const CACHE_MESSAGES = 16;

/** @param {unknown} a @param {unknown} b @returns {boolean} */
function sameId(a, b) {
  return a != null && b != null && String(a) === String(b);
}

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

// The source offset at caret column `col`, where a gap takes the source end before it, or -1 when the row has none.
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

// Draw styled segments left to right, clipping the row as one string, so a split run never repeats the ellipsis.
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

// A compaction message is plain thought text, not markdown.
/** @param {ItemKey} id @param {string} body @param {number} width @returns {TranscriptRow[]} */
function wrapPlain(id, body, width) {
  /** @type {TranscriptRow[]} */
  const rows = wrapBody(body, Math.max(1, width - TX_GUTTER), "TxThought").map((r) => ({
    ...r,
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

// A stale render keeps its parts and documents, so the next build reparses only what changed.
/** @param {{ w: number }} c @returns {void} */
function stale(c) {
  c.w = -1;
}

// Move a rendered part to a new source base. The rows are shared with the message cache, so they are replaced, never edited.
/** @param {PartCache} c @param {number} base @returns {void} */
function rebasePart(c, base) {
  const delta = base - c.base;
  c.rows = c.rows.map((r) => (r.segments ? { ...r, segments: shiftSrc(r.segments, delta) } : r));
  c.blocks = c.blocks.map((b) => ({ kind: b.kind, at: b.at + delta, end: b.end + delta }));
  c.base = base;
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
  if (state?.type === "canceled" && state.reason === "setup_declined") return "setup declined";
  if (state?.type === "canceled" && state.reason === "setup_dismissed") return "setup incomplete";
  return t;
}

/** @param {Wire.ToolState | null | undefined} state @returns {boolean} */
function defaultExpanded(state) {
  const t = toolStateKind(state);
  return t === "running" || t === "error" || t === "canceled";
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @param {string} summary @returns {string} */
function toolHeaderSource(part, summary) {
  const name = String(part.name || "tool");
  return summary ? name + " " + summary : name;
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @param {boolean} expanded @param {number} width @param {string} summary @returns {TranscriptRow} */
function toolHeaderRow(part, expanded, width, summary) {
  const name = String(part.name || "tool");
  const state = part.state || {};
  const kind = toolStateKind(state);
  const duration = /** @type {{ duration_ms?: number }} */ (state);
  const right = toolStateLabel(state) + (duration.duration_ms != null ? " · " + duration.duration_ms + "ms" : "");
  const err = kind === "error";
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
  if (s.type === "canceled" && s.reason === "setup_declined") return "Setup declined · No agent created";
  if (s.type === "canceled" && s.reason === "setup_dismissed") return "Setup incomplete · No agent created";
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
  const group = kind === "error" ? "TxToolError" : "TxToolBody";
  return { rows: wrapBody(text, width, group), source: text };
}

/** @param {Extract<Wire.AssistantPart, { type: "reasoning" }>} part @param {number} width @param {boolean} expanded @param {boolean} live @returns {{ rows: TranscriptRow[], source: string }} */
function reasoningRows(part, width, expanded, live) {
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
  const text = part.text || "";
  source += "\n" + text;
  const base = name.length + 1;
  const body = wrapBody(text, width, "TxThought").map((r) => ({
    ...r,
    kind: "reasoning-body",
    partId: part.id,
    segments: shiftSrc(r.segments, base),
  }));
  for (const r of capRows(body, TOOL_BODY_CAP)) rows.push(r);
  return { rows, source };
}

/** @param {Extract<Wire.AssistantPart, { type: "tool" }>} part @param {number} width @param {boolean} expanded @returns {{ rows: TranscriptRow[], source: string }} */
function toolRows(part, width, expanded) {
  // `toolSummary` parses the arguments, so the row and the source share one result.
  const summary = toolSummary(part.arguments);
  const header = toolHeaderRow(part, expanded, width, summary);
  const headerSrc = toolHeaderSource(part, summary);
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

// The chat transcript: message descriptors, exact row counts, and a bounded cache of rendered rows.
export class Transcript {
  /** @param {TranscriptOptions} [opts] */
  constructor(opts = {}) {
    this.textOf = opts.textOf || (() => "");
    this.partsOf = opts.partsOf || null;
    this.partOf = opts.partOf || null;
    this.pager = new Pager();
    this.pager.setSource(this);
    /** @type {MessageDescriptor[]} */
    this._messages = []; // committed descriptors, oldest first
    /** @type {MessageDescriptor | null} */
    this._active = null; // the streaming draft descriptor, or null
    this._width = -1;
    /** @type {Map<string, number>} */
    this._positions = new Map();
    /** @type {Map<string, number>} */
    this._counts = new Map();
    this._prefix = [0];
    /** @type {Set<string>} */
    this._viewport = new Set();
    /** @type {Map<string, RowCache>} */
    this._rows = new Map(); // id -> { w, rows, source, blocks }, oldest render first
    /** @type {Map<string, Document>} */
    this._docs = new Map(); // id -> md Document, for the textOf path
    /** @type {Map<string, PartState>} */
    this._parts = new Map(); // id -> the part list and one render per part, for the partsOf path
    /** @type {Map<string, boolean>} */
    this._expand = new Map(); // id:partId -> user override
    // A selection holds two `{ id, row, col }` positions, where `row` counts rendered rows and `col` indexes the row text.
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

  // Set both ends. `{ inclusive: true }` grows the later end by one grapheme.
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

  // A committed message never changes under its id, so its render survives; the draft goes because a commit folds its reasoning.
  /** @param {MessageDescriptor[]} messages @param {MessageDescriptor | null} active @returns {void} */
  setOutline(messages, active) {
    const keep = new Set();
    for (const m of messages || []) if (!sameId(m.id, this._active?.id)) keep.add(String(m.id));
    for (const key of new Set([...this._rows.keys(), ...this._docs.keys(), ...this._parts.keys()])) if (!keep.has(key)) this._evict(key);
    for (const key of this._counts.keys()) if (!keep.has(key)) this._counts.delete(key);
    this._messages = messages || [];
    this._active = active || null;
    this._resetOrder();
    this._pruneKeyed(this._expand, this._liveIds());
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

  /** @returns {void} */
  _resetOrder() {
    this._positions.clear();
    for (let i = 0; ; i++) {
      const m = this._at(i);
      if (!m) break;
      const key = String(m.id);
      if (!this._positions.has(key)) this._positions.set(key, i);
    }
    this._prefix = [0];
  }

  // Eviction discards render data, but exact counts and fold overrides remain valid.
  /** @param {string} key @returns {void} */
  _evict(key) {
    this._rows.delete(key);
    this._docs.delete(key);
    this._parts.delete(key);
  }

  // The oldest renders leave first, but a message on the screen or under a live position never leaves.
  /** @returns {void} */
  _trimCaches() {
    if (this._rows.size <= CACHE_MESSAGES) return;
    const pinned = new Set(this._viewport);
    for (const id of [this._active?.id, this._press?.id, this.selection?.anchor.id, this.selection?.cursor.id]) if (id != null) pinned.add(String(id));
    for (const key of this._rows.keys()) {
      if (this._rows.size <= CACHE_MESSAGES) break;
      if (!pinned.has(key)) this._evict(key);
    }
  }

  // The render and the count of one message are stale, and the prefix sums from it onward with them.
  /** @param {number} id @returns {void} */
  _markStale(id) {
    const key = String(id);
    const c = this._rows.get(key);
    if (c) stale(c);
    this._counts.delete(key);
    const i = this._indexOf(id);
    if (i >= 0) this._prefix.length = Math.min(this._prefix.length, i + 1);
  }

  // A missing count renders its message once and lets the cache drop the rows; later reads use the counts alone.
  /** @returns {void} */
  _indexRows() {
    for (let i = this._prefix.length - 1; ; i++) {
      const m = this._at(i);
      if (!m) break;
      const key = String(m.id);
      let count = this._counts.get(key);
      if (count == null) count = this._rowsOf(m, this._width).length;
      this._prefix.push(this._offset(i) + count);
    }
  }

  /** @param {number} i @returns {number} */
  _offset(i) {
    const offset = this._prefix[i];
    if (offset == null) throw new Error("invalid transcript row index");
    return offset;
  }

  /** @param {number} row @returns {number} */
  _messageAtRow(row) {
    let lo = 0;
    let hi = this._prefix.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (this._offset(mid + 1) <= row) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  // A streaming delta on draft `id`: adopt it if new, then re-read one part `partId`, or every part without one.
  /** @param {number} id @param {number} [partId] @returns {void} */
  setActive(id, partId) {
    // The draft rewraps as tokens arrive, but an append never moves the source before it.
    const sel = this.selection;
    const touches = !!sel && (sameId(sel.anchor.id, id) || sameId(sel.cursor.id, id));
    const anchors = touches ? this._anchors() : null;
    if (!this._active || !sameId(this._active.id, id)) {
      if (this._active) this._markStale(this._active.id);
      this._active = { id, type: "assistant" };
      this._resetOrder();
    }
    this._refreshParts(id, partId);
    this._markStale(id);
    if (touches) this._reanchor(anchors);
  }

  // Replace one part in the held list, or drop the list so the next render reads every part again.
  /** @param {number} id @param {number} [partId] @returns {void} */
  _refreshParts(id, partId) {
    const state = this._parts.get(String(id));
    if (!state || !state.list) return;
    const at = partId == null ? -1 : state.list.findIndex((p) => p && sameId(p.id, partId));
    const fresh = at < 0 || !this.partOf ? null : this._partOne(id, /** @type {number} */ (partId));
    if (fresh) {
      state.list[at] = fresh;
      const c = state.rows.get(String(partId));
      if (c) stale(c);
      return;
    }
    state.list = null;
    for (const c of state.rows.values()) stale(c);
  }

  // A width change rewraps every row but keeps every parse; the selection moves back to the same source offsets.
  /** @param {number} width @returns {void} */
  _invalidate(width) {
    if (width === this._width) return;
    const anchors = this._anchors();
    this._width = width;
    for (const c of this._rows.values()) stale(c);
    this._counts.clear();
    this._prefix = [0];
    if (this.selection) this._reanchor(anchors);
  }

  /** @param {number} id @returns {string} */
  _sourceOf(id) {
    this._rowsFor(id);
    const c = this._rows.get(String(id));
    return c ? c.source : this.textOf(id);
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

  // Put the selection back on the same source text, and clear it on a missing end rather than move it.
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
    const c = this._rows.get(String(id));
    if (c && c.blocks) return c.blocks;
    const doc = this._docs.get(String(id));
    return doc ? doc.blocks() : [];
  }

  // The rendered rows of one message at the drawn width, owned by the render cache, so only this class holds them.
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
    if (this._width <= 0 || this._indexOf(id) < 0) return 0;
    return this._counts.get(String(id)) ?? this._rowsFor(id).length;
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
    if (!pos || this._width <= 0 || pos.row < 0) return -1;
    const i = this._indexOf(pos.id);
    if (i < 0) return -1;
    this._indexRows();
    return pos.row < this._offset(i + 1) - this._offset(i) ? this._offset(i) + pos.row : -1;
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

  // The position that renders source `offset`, or the first after it, so a selection to the end survives a rewrap.
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
    const key = String(m.id);
    const c = this._rows.get(key);
    if (c && c.w === width) {
      this._rows.delete(key);
      this._rows.set(key, c);
      return c.rows;
    }
    // Trim before the build, so the entry this call adds cannot leave in the same call.
    this._trimCaches();

    let rows;
    let source = null;
    let blocks = null;
    if (m.type === "user") {
      source = this.textOf(m.id) || "";
      if (m.source && m.source.type !== "parent_instruction") {
        const expanded = this._expand.get(this._expandKey(m.id, -1)) === true;
        const body = wrapBody(source, Math.max(1, width - TX_GUTTER), "TxToolBody");
        const shown = expanded ? body : body.slice(0, REPORT_PREVIEW_LINES);
        rows = [{ text: inputSourceLabel(m.source), group: "TxToolMeta", marker: expanded ? "▾" : "▸", markerGroup: "TxToolMeta", indent: TX_GUTTER, kind: "report-header", partId: -1 },
          ...shown.map((row) => ({ ...row, kind: "report-body", partId: -1 })),
          ...(!expanded && body.length > shown.length ? [{ text: "… click the header to expand", group: "TxToolMeta", indent: TX_GUTTER, kind: "report-header", partId: -1 }] : []), { text: "" }];
      } else rows = userRows(m.id, source, width);
    } else if (m.type === "compaction") {
      source = this.textOf(m.id) || "";
      rows = wrapPlain(m.id, source, width);
    } else if (this.partsOf) {
      const built = this._partRows(m, width);
      rows = built.rows;
      source = built.source;
      blocks = built.blocks;
    } else {
      rows = this._assistantRows(m.id, width);
      const doc = this._docs.get(String(m.id));
      source = doc ? doc.sourceText() : this.textOf(m.id) || "";
    }
    if (m.error) {
      const base = source && source.length ? source.length + 1 : 0;
      const err = errorRows(m.id, m.error, width, base);
      source = source && source.length ? source + "\n" + err.source : err.source;
      rows = rows.concat(err.rows);
    }
    this._rows.delete(key);
    this._rows.set(key, { w: width, rows, source: source == null ? "" : source, blocks });
    this._counts.set(key, rows.length);
    return rows;
  }

  // The parts of one message and their renders, read once and held until a delta or an eviction drops them.
  /** @param {number} id @returns {PartState} */
  _partState(id) {
    const key = String(id);
    let state = this._parts.get(key);
    if (!state) {
      state = { list: null, rows: new Map() };
      this._parts.set(key, state);
    }
    if (!state.list) {
      let list = /** @type {readonly Wire.AssistantPart[]} */ ([]);
      try {
        const p = /** @type {PartsOf} */ (this.partsOf)(id);
        if (Array.isArray(p)) list = p;
      } catch (_) {}
      state.list = list.filter((p) => p && (p.type === "text" || p.type === "tool" || p.type === "reasoning"));
    }
    return state;
  }

  /** @param {number} id @param {number} partId @returns {Wire.AssistantPart | null} */
  _partOne(id, partId) {
    try {
      return /** @type {PartOf} */ (this.partOf)(id, partId);
    } catch (_) {
      return null;
    }
  }

  /** @param {ItemKey} id @param {ItemKey} partId @returns {string} */
  _expandKey(id, partId) {
    return String(id) + ":" + String(partId);
  }

  /** @param {number} id @param {number} partId @param {Wire.AssistantPart | null | undefined} part @returns {boolean} */
  _isExpanded(id, partId, part) {
    const k = this._expandKey(id, partId);
    if (this._expand.has(k)) return /** @type {boolean} */ (this._expand.get(k));
    if (part && part.type === "reasoning") return sameId(this._active?.id, id);
    const state = part == null ? part : part.type === "tool" ? part.state : undefined;
    return defaultExpanded(state);
  }

  // Flip the user override for one foldable part. A missing part is a no-op.
  /** @param {number} id @param {number} partId @returns {void} */
  togglePart(id, partId) {
    if (id == null || partId == null) return;
    const k = this._expandKey(id, partId);
    let part = null;
    if (partId !== -1 && this.partsOf) {
      for (const p of this._partState(id).list || []) if (sameId(p.id, partId)) part = p;
    }
    this._expand.set(k, !(partId === -1 ? this._expand.get(k) === true : this._isExpanded(id, partId, part)));
    this._markStale(id);
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

  /** @param {MessageDescriptor} m @returns {Position[]} */
  _partStopsOf(m) {
    const rows = this._rowsFor(m.id);
    if (m.type === "user" || m.type === "compaction" || !this.partsOf) {
      return rows.length ? [{ id: m.id, row: 0, col: 0 }] : [];
    }
    const out = [];
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
    return out;
  }

  // A part motion reads only the messages between the cursor and its next stop.
  /** @param {Position | null} pos @param {number} dir @returns {Position | null} */
  partStep(pos, dir) {
    if (!pos) return null;
    const step = dir > 0 ? 1 : -1;
    for (let i = this._indexOf(pos.id); i >= 0; i += step) {
      const m = this._at(i);
      if (!m) break;
      const stops = this._partStopsOf(m);
      for (let n = step > 0 ? 0 : stops.length - 1; n >= 0 && n < stops.length; n += step) {
        const stop = /** @type {Position} */ (stops[n]);
        if (this._cmpPos(stop, pos) * step > 0) return stop;
      }
    }
    return null;
  }

  // Each part renders once per width, fold, and live state, so a delta rebuilds one part and re-bases the rest.
  /** @param {MessageDescriptor} m @param {number} width @returns {{ rows: TranscriptRow[], source: string, blocks: { kind: string, at: number, end: number }[] }} */
  _partRows(m, width) {
    const state = this._partState(m.id);
    const seen = new Set();
    const rows = /** @type {TranscriptRow[]} */ ([]);
    const blocks = /** @type {{ kind: string, at: number, end: number }[]} */ ([]);
    let source = "";
    for (const part of state.list || []) {
      if (source) source += "\n";
      const base = source.length;
      const key = String(part.id);
      seen.add(key);
      const expanded = part.type === "text" || this._isExpanded(m.id, part.id, part);
      const live = part.type === "reasoning" && sameId(this._active?.id, m.id);
      let c = state.rows.get(key);
      if (!c || c.w !== width || c.expanded !== expanded || c.live !== live) {
        c = this._buildPart(m.id, part, width, expanded, live, c ? c.doc : null);
        state.rows.set(key, c);
      }
      if (c.base !== base) rebasePart(c, base);
      source += c.source;
      for (const b of c.blocks) blocks.push(b);
      for (const r of c.rows) rows.push(r);
    }
    for (const key of state.rows.keys()) if (!seen.has(key)) state.rows.delete(key);
    rows.push({ text: "", key: m.id });
    return { rows, source, blocks };
  }

  // Render one part at source base 0. A text part keeps its document, so a delta re-wraps only the open block.
  /** @param {number} id @param {Wire.AssistantPart} part @param {number} width @param {boolean} expanded @param {boolean} live @param {Document | null} doc @returns {PartCache} */
  _buildPart(id, part, width, expanded, live, doc) {
    const contentW = Math.max(1, width - TX_GUTTER);
    const tag = { indent: TX_GUTTER, key: id, partId: part.id };
    if (part.type === "text") {
      if (!doc) doc = new Document();
      doc.setText(part.text || "");
      const rows = doc.rows(contentW).map((r) => ({ segments: r.segments, ...tag, kind: "text" }));
      return { w: width, expanded, live, base: 0, rows, source: doc.sourceText(), blocks: doc.blocks(), doc };
    }
    const built = part.type === "tool"
      ? toolRows(part, contentW, expanded)
      : reasoningRows(/** @type {Extract<Wire.AssistantPart, { type: "reasoning" }>} */ (part), contentW, expanded, live);
    const rows = built.rows.map((r) => ({ ...r, ...tag }));
    return { w: width, expanded, live, base: 0, rows, source: built.source, blocks: [], doc: null };
  }

  // Assistant rows come from a per-message md Document, indented past the gutter, then a separator.
  /** @param {number} id @param {number} width @returns {TranscriptRow[]} */
  _assistantRows(id, width) {
    let doc = this._docs.get(String(id));
    if (!doc) {
      doc = new Document();
      this._docs.set(String(id), doc);
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
    return this._positions.get(String(id)) ?? -1;
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

  // Return the row range inside the selection, keeping a middle empty row so a blank line survives the copy.
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

  // The markdown under the selection, kept separate from `selectedText`; an unmapped turn is its own source.
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
    this._indexRows();
    return this._offset(this._prefix.length - 1);
  }

  /** @param {number} width @param {number} top @param {number} height @returns {TranscriptRow[]} */
  rows(width, top, height) {
    if (width <= 0 || height <= 0) return [];
    this._invalidate(width);
    const blank = this._emptyRows();
    if (blank) return blank.slice(top, top + height);
    this._indexRows();
    const first = this._messageAtRow(top);
    this._viewport.clear();
    for (let i = first; i + 1 < this._prefix.length && this._offset(i) < top + height; i++) {
      const m = /** @type {MessageDescriptor} */ (this._at(i));
      this._viewport.add(String(m.id));
    }
    const range = this._range();
    const out = [];
    for (let i = first; i + 1 < this._prefix.length && this._offset(i) < top + height; i++) {
      const m = /** @type {MessageDescriptor} */ (this._at(i));
      const rows = this._rowsOf(m, width);
      const base = this._offset(i);
      for (let k = Math.max(0, top - base); k < rows.length && base + k < top + height; k++) {
        const row = /** @type {TranscriptRow} */ (rows[k]);
        const r = range && this._rowRange(range, i, k, rowText(row).length);
        out.push(r && r.to > r.from ? { ...row, sel: r } : row);
      }
    }
    this._trimCaches();
    return out;
  }

  // The committed messages oldest first, then the streaming draft, each a copy the caller cannot write through.
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

  // Return the fenced block bodies of every message oldest first, because a user turn can also hold a fence.
  /** @returns {CodeBlock[]} */
  codeBlocks() {
    const out = [];
    for (const m of this.messages()) {
      const held = this._docs.get(String(m.id));
      const doc = held || new Document();
      // A changed source makes the held render stale, because this call is outside a draw.
      if (doc.setText(this.textOf(m.id)) && held) this._markStale(m.id);
      for (const b of doc.codeBlocks()) out.push({ id: m.id, lang: b.lang, text: b.text });
    }
    return out;
  }

  /** @param {Rect} rect @returns {void} */
  draw(rect) {
    this.pager.draw(rect);
  }

  // The logical position under a screen cell, or null off the drawn rows; `clamp` pulls a drag back to the nearest row.
  /** @param {number} col @param {number} row @param {boolean} clamp @returns {Position | null} */
  posAt(col, row, clamp) {
    const rect = this.pager.rect();
    if (!rect) return null;
    const y = clamp ? Math.min(Math.max(row, rect.y), rect.y + rect.h - 1) : row;
    const g = this.pager.rowAtY(y);
    if (g < 0) return null;
    this._indexRows();
    const i = this._messageAtRow(g);
    const m = this._at(i);
    if (!m) return null;
    const rows = this._rowsOf(m, this._width);
    const k = g - this._offset(i);
    const line = /** @type {TranscriptRow} */ (rows[k]);
    const body = rowText(line);
    const x = Math.max(0, col - rect.x - (line.indent || 0));
    const wrapRow = { start: 0, end: body.length, soft: false };
    return { id: m.id, row: k, col: caretAtCol(body, wrapRow, x) };
  }

  // A left drag selects text: a press records the start and a drag opens the range, so a click leaves no one-cell range.
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
        if (hit && (hit.kind === "tool-header" || hit.kind === "reasoning-header" || hit.kind === "report-header")) {
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

// The chat pane: a transcript above a composer in one leaf. Draw, layout, and mouse routing.
export class ChatView {
  /** @param {ChatViewOptions} [opts] */
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.transcript = new Transcript({ textOf: opts.textOf, partsOf: opts.partsOf, partOf: opts.partOf, onSelect: opts.onSelect, empty: opts.empty });
    this.composer = new Composer({ placeholder: "Message…", onSubmit: opts.onSubmit });
    // This field names the region that reads the keyboard. The mouse routes by rect instead.
    /** @type {ChatRegion} */
    this.focus = "composer";
  }

  get name() {
    return "chat";
  }

  // The focused region names the deeper atom, so a binding can own one region alone.
  /** @returns {string[]} */
  contexts() {
    return ["chat", this.focus];
  }

  // A pane focus returns the keyboard to the composer.
  /** @returns {void} */
  onFocus() {
    this.focusRegion("composer");
  }

  /** @param {ChatRegion} name @returns {void} */
  focusRegion(name) {
    if (name !== "composer" && name !== "transcript") throw new TypeError("focusRegion: unknown region " + name);
    if (this.focus === name) return;
    this.focus = name;
    events.emit("region.focused", this, name);
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    // A focused transcript reads nothing here, because a nav binding scrolls it through the keymap.
    if (this.focus === "transcript") return false;
    return this.composer.onKey(ev);
  }

  // The widget a nav binding drives here. The transcript scrolls even while the composer types.
  /** @returns {import("yuke:core").NavTarget} */
  navTarget() {
    return this.transcript.pager;
  }

  // Route by sub-rect, so a wheel step over the composer never moves the transcript; only a press hits this test.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    const r = this.transcript.pager.rect();
    const inside = r && ev.col >= r.x && ev.col < r.x + r.w && ev.row >= r.y && ev.row < r.y + r.h;
    const taken = inside || ev.event === "drag" || ev.event === "release" ? this.transcript.onMouse(ev) : false;
    // A provider may claim a left press to place its own caret, after the transcript reads it.
    if (ev.event !== "press" || ev.button !== "left") return taken;
    return slot.get(this, "press", ev) === true || taken;
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
    // A plugin puts rows between the transcript and the rule, such as the queued inputs. The transcript keeps one row.
    const strip = /** @type {StripRow[]} */ (slot.get(this, "strip") || []);
    const shown = Math.min(strip.length, Math.max(0, rule - y - 1));
    const top = rule - shown;
    if (top > y) this.transcript.draw({ x, y, w, h: top - y });
    else this.transcript.hide();
    for (let i = 0; i < shown; i++) {
      const row = /** @type {StripRow} */ (strip[i]);
      text(x, top + i, clip(row.text, w), row.group || "UIDim");
    }
    if (rule >= y) this._drawRule(x, rule, w);
    this.composer.draw(focused);
  }

  // The rule row. A plugin puts a line on it, such as the working indicator, and the rule fills the rest.
  /** @param {number} x @param {number} y @param {number} w @returns {void} */
  _drawRule(x, y, w) {
    const line = /** @type {StripRow | null} */ (slot.get(this, "rule"));
    const label = line ? clip(line.text, w) : "";
    const used = label ? term.measure(label) : 0;
    if (label) text(x, y, label, (line && line.group) || "YukeRule");
    if (w > used) text(x + used, y, "─".repeat(w - used), "YukeRule");
  }

  // The caret belongs to the focused region, so a transcript with no cursor provider shows none.
  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    const supplied = /** @type {{ x: number, y: number, visible: boolean } | null} */ (slot.get(this, "cursor"));
    if (supplied) return supplied;
    return this.focus === "composer" ? this.composer.cursor() : null;
  }
}
