// The chat transcript core: the readers, the render caches, the selection, and the stack of renderers that decide every row.
import { rowText, rowSourceSpan, rowSourceAt, segmentsOf, Pager } from "yuke:internal/pager";
import { term } from "yuke:internal/native/term";
import { root, isWheel } from "yuke:internal/core";
import { fault, once } from "yuke:internal/kernel";
import { caretAtCol, nextGrapheme } from "yuke:internal/text-input";
import { Document, isLinear } from "yuke:internal/md";

/** @import { HostMouseEvent as MouseEvent, Rect } from "./types/core.js" */
/** @import { TranscriptRow } from "./types/pager.js" */
/** @import { GroupEntry, GroupPlan, MessageDescriptor, MessageEnv, PartCache, PartEnv, PartHit, PartState, Position, Render, Rendered, RowCache, Selection, SelectionAnchors, SelectionRange, SourceLabels, ToolHead, TranscriptOptions } from "./types/transcript.js" */
/** @import { MessagePart, PartRead, TextCursor } from "yuke:internal/native/engine" */
/** @import { Block } from "./types/md.js" */
/** @import { Disposer } from "./types/ext.js" */

// One part in a group packs the group size and its place into one number, so the plan retains no objects; the low two bits mark the first and last part, and the count scales above them.
const GROUP_FIRST = 1;
const GROUP_LAST = 2;
const GROUP_SCALE = 4;

// Rendered messages beyond this count leave the cache oldest first; the viewport and live anchors never leave.
const CACHE_MESSAGES = 16;

const FIELD_UNREAD = "\n[the remaining field could not be read]";

/** @param {unknown} a @param {unknown} b @returns {boolean} */
function sameId(a, b) {
  return a != null && b != null && String(a) === String(b);
}

// The hooks of a renderer. The newest registration that answers a value other than undefined wins.
const HOOKS = /** @type {const} */ (["part", "message", "error", "groupKey", "groupHeader", "fold", "sameVisible", "activate"]);

/**
 * @typedef {{ [K in typeof HOOKS[number]]: Render[] } & { tools: Record<string, ToolHead>, sources: SourceLabels, indent: number, gap: number }} Merged
 */

/** @type {Render[]} */
const renders = [];
/** @type {Merged} */
let merged = mergeRenders();
// A transcript compares these with the values of its last build, so a registration or a ctrl+o rebuilds every row.
let renderRevision = 0;
let expandAll = false;
let expandEpoch = 0;

/** @returns {Merged} */
function mergeRenders() {
  const out = /** @type {Merged} */ ({ tools: Object.create(null), sources: { engine_interruption: (source) => "Engine notice · run " + source.run_id + " interrupted" }, indent: 0, gap: 0 });
  for (const name of HOOKS) out[name] = [];
  for (const r of renders) {
    for (const name of HOOKS) if (r[name]) out[name].push(r);
    Object.assign(out.tools, r.tools);
    Object.assign(out.sources, r.sources);
    if (r.indent !== undefined) out.indent = r.indent;
    if (r.gap !== undefined) out.gap = r.gap;
  }
  return out;
}

// Ask the renderers newest first. A throw reports a fault and asks the next one, so one bad plugin cannot break a frame.
/** @param {typeof HOOKS[number]} name @param {unknown} a @param {unknown} [b] @param {unknown} [c] @returns {any} */
function hook(name, a, b, c) {
  const list = merged[name];
  for (let i = list.length - 1; i >= 0; i--) {
    try {
      const out = /** @type {(a: unknown, b: unknown, c: unknown) => unknown} */ (/** @type {Render} */ (list[i])[name]).call(list[i], a, b, c);
      if (out !== undefined) return out;
    } catch (e) {
      fault(e, "chat.render");
    }
  }
  return undefined;
}

/**
 * Add a renderer to every transcript. A hook that answers undefined passes to the renderer below; `tools` and `sources` merge by name, and the newest wins.
 * The call copies the top level of `render`. A plugin uses `ctx.chat.render`, which removes the registration when the block unloads.
 * @param {Render} render @returns {Disposer} Removes only this registration.
 */
export function registerRender(render) {
  const entry = { ...render };
  renders.push(entry);
  changed();
  return once(() => {
    renders.splice(renders.indexOf(entry), 1);
    changed();
  });
}

function changed() {
  merged = mergeRenders();
  renderRevision++;
  root.invalidate();
}

/** Open every foldable part in every transcript, or fold them all again. It drops each open or fold the user chose one by one. */
export function toggleExpandAll() {
  expandAll = !expandAll;
  expandEpoch++;
  renderRevision++;
  root.invalidate();
}

/**
 * The label of an input from an engine source: the `sources` entry of the renderers, else the source type with spaces.
 * @param {Wire.InputSource | undefined | null} source @returns {string}
 */
export function inputSourceLabel(source) {
  if (!source) return "";
  // The table keys each label by its source type, so the label reads the source it names.
  const label = /** @type {((source: Wire.InputSource) => string) | undefined} */ (merged.sources[source.type]);
  return label ? label(source) : source.type.replaceAll("_", " ");
}

/** @param {import("./types/pager.js").Segment[] | undefined} segments @param {number} base @returns {import("./types/pager.js").Segment[] | undefined} */
function shiftSrc(segments, base) {
  if (!segments || !base) return segments;
  return segments.map((seg) => (seg.src == null ? seg : { ...seg, src: seg.src + base, srcEnd: /** @type {number} */ (seg.srcEnd) + base }));
}

// A stale render keeps its parts and documents, so the next build reparses only what changed.
/** @param {{ w: number }} c @returns {void} */
function stale(c) {
  c.w = -1;
}

/** @param {TranscriptRow} row @param {number} base @returns {TranscriptRow} */
function rowAtBase(row, base) {
  if (!base) return row;
  if (row.segments) return { ...row, segments: shiftSrc(row.segments, base) };
  return row.src != null ? { ...row, src: row.src + base } : row;
}

/** @param {RowCache | null | undefined} cache @param {TranscriptRow} row @returns {number} */
function rowSourceBase(cache, row) {
  if (!cache || row.partId == null) return 0;
  return cache.partBases.get(String(row.partId)) || 0;
}

// The group key of a part. An empty text part answers undefined and passes through a group. A part that closes a group answers null.
/** @param {Wire.AssistantPart} part @returns {string | null | undefined} */
function partKey(part) {
  if (part.type === "text" && !part.text) return undefined;
  return hook("groupKey", part) ?? null;
}

// A snapshot reads no selection, so its selection entries land here and nobody reads them.
/** @type {number[]} */
const snapshotSel = [];

/**
 * The transcript of one chat pane: the message outline, exact row counts, and a bounded cache of rendered rows.
 * The owner feeds it with `setOutline` and `setActive`. The `pager` scrolls and draws it.
 */
export class Transcript {
  /** @param {TranscriptOptions} [opts] */
  constructor(opts = {}) {
    this.partsOf = opts.partsOf || (() => []);
    this.partOf = opts.partOf || null;
    this.partTextPage = opts.partTextPage || null;
    /** The scroll state and the drawn rect. Nav bindings drive it. */
    this.pager = new Pager();
    this.pager.setSource({
      rowCount: (width) => this.rowCount(width),
      rows: (width, top, height, out, sel) => this._rowsRange(width, top, height, false, out, sel),
    });
    /** @type {MessageDescriptor[]} */
    this._messages = []; // committed descriptors, oldest first
    /** @type {MessageDescriptor | null} */
    this._active = null; // the streaming draft descriptor, or null
    this._width = -1;
    this._revision = renderRevision;
    this._expandEpoch = expandEpoch;
    /** @type {Map<string, number>} */
    this._positions = new Map();
    /** @type {Map<string, number>} */
    this._counts = new Map();
    this._prefix = [0];
    /** @type {Set<string>} */
    this._viewport = new Set();
    /** @type {Map<string, RowCache>} */
    this._rows = new Map(); // Oldest render first; each text-only render owns its Markdown document.
    /** @type {Map<string, PartState>} */
    this._parts = new Map(); // id -> the part list and one render per part, for the partsOf path
    /** @type {WeakMap<Wire.AssistantPart, TextCursor>} */
    this._cursors = new WeakMap(); // held part -> the end of its text, so a list read again holds no cursor
    /** @type {GroupPlan | null} */
    this._planCache = null;
    /** @type {Map<string, boolean>} */
    this._expand = new Map(); // id:partId -> user override
    /**
     * The selection, or null. It holds two `{ id, row, col }` positions, where `row` counts rendered rows and `col` indexes the row text.
     * @type {Selection | null}
     */
    this.selection = null;
    /**
     * The reader's caret, or null. A rebuild keeps the caret text on the same screen row, so a fold or a rewrap does not move it.
     * The plugin that owns the keyboard cursor sets the caret on each cursor change. It sets null when the transcript loses the focus.
     * @type {Position | null}
     */
    this.caret = null;
    this._dragging = false;
    this._didDrag = false;
    /** @type {Position | null} */
    this._press = null;
    this._pressCol = 0; // the screen column of the press, so a drag orders its ends without a row scan
    /** @type {Position | null} */
    this._pressEnd = null; // the caret after the pressed grapheme, read once on the first reverse drag
    /** Receives the selected text when a mouse drag ends on a selection that is not empty. */
    this.onSelect = opts.onSelect || null;
  }

  /**
   * Remove the selection and stop a drag in progress.
   * @returns {void}
   */
  clearSelection() {
    this.selection = null;
    this._dragging = false;
    this._didDrag = false;
    this._press = null;
  }

  /**
   * Set both ends of the selection. `{ inclusive: true }` grows the later end by one grapheme. A null end clears the selection.
   * @param {Position | null} anchor @param {Position | null} cursor @param {{ inclusive?: boolean } | null | undefined} [opts] @returns {void}
   */
  select(anchor, cursor, opts) {
    if (!anchor || !cursor) {
      this.clearSelection();
      return;
    }
    let a = anchor;
    let b = cursor;
    if (opts && opts.inclusive) {
      if (this.comparePos(b, a) >= 0) b = this._after(b);
      else a = this._after(a);
    }
    this.selection = { anchor: a, cursor: b };
  }

  /** @param {Position} p @returns {Position} */
  _after(p) {
    const body = this.rowTextAt(p.id, p.row);
    return { id: p.id, row: p.row, col: Math.min(nextGrapheme(body, p.col), body.length) };
  }

  /**
   * Compare two positions in transcript order: below 0 when `a` comes first, 0 when they are equal, above 0 when `b` comes first.
   * @param {Position} a @param {Position} b @returns {number}
   */
  comparePos(a, b) {
    if (a.id !== b.id) return this.messageIndex(a.id) - this.messageIndex(b.id);
    return a.row !== b.row ? a.row - b.row : a.col - b.col;
  }

  /**
   * Forget the drawn rect and clear the selection. Call it when the pane draws something else in this space, so a click cannot hit a row that left.
   * @returns {void}
   */
  hide() {
    this.pager.clearRect();
    this.clearSelection();
  }

  /** True when the transcript holds no committed message and no streaming draft. */
  /** @returns {boolean} */
  isEmpty() {
    return this._messages.length === 0 && this._active === null;
  }

  /**
   * Replace the outline with the committed `messages` and the streaming draft `active`, or null without a draft. It clears the selection.
   * A committed message never changes under its id, so its render survives. The draft render goes, because a live part renders apart from its committed form.
   * @param {MessageDescriptor[]} messages @param {MessageDescriptor | null} active @returns {void}
   */
  setOutline(messages, active) {
    const oldPlan = this._planCache;
    const oldMessages = oldPlan ? this.messages() : [];
    const keep = new Set();
    for (const m of messages) if (!sameId(m.id, this._active?.id)) keep.add(String(m.id));
    for (const key of new Set([...this._rows.keys(), ...this._parts.keys()])) if (!keep.has(key)) this._evict(key);
    for (const key of this._counts.keys()) if (!keep.has(key)) this._counts.delete(key);
    this._messages = messages;
    this._active = active || null;
    this._resetOrder();
    this._planCache = null;
    this._refreshGroupRows(oldPlan, oldMessages);
    // `_positions` now holds every live id, the draft included; an override key is "id:partId".
    for (const k of this._expand.keys()) if (!this._positions.has(k.slice(0, k.indexOf(":")))) this._expand.delete(k);
    this.clearSelection();
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
    this._parts.delete(key);
  }

  // The oldest renders leave first, but a message on the screen or under a live position never leaves.
  /** @returns {void} */
  _trimCaches() {
    if (this._rows.size <= CACHE_MESSAGES) return;
    for (const key of this._rows.keys()) {
      if (this._rows.size <= CACHE_MESSAGES) break;
      if (this._viewport.has(key) || sameId(key, this._active?.id) || sameId(key, this._press?.id)
        || sameId(key, this.selection?.anchor.id) || sameId(key, this.selection?.cursor.id)) continue;
      this._evict(key);
    }
  }

  // The render and the count of one message are stale, and the prefix sums from it onward with them.
  /** @param {number} id @returns {void} */
  _markStale(id) {
    const key = String(id);
    const c = this._rows.get(key);
    if (c) stale(c);
    this._counts.delete(key);
    const i = this.messageIndex(id);
    if (i >= 0) this._prefix.length = Math.min(this._prefix.length, i + 1);
  }

  // A missing count renders its message once and lets the cache drop the rows; later reads use the counts alone.
  /** @param {number} last @returns {void} */
  _indexRowsThrough(last) {
    if (merged.groupKey.length && !this._planCache && this._prefix.length === 1) {
      this._buildPlan(
        (m) => this._partState(m.id).list,
        this._indexRowsThrough,
      );
      return;
    }
    for (let i = this._prefix.length - 1; i <= last; i++) {
      const m = this._at(i);
      if (!m) break;
      const key = String(m.id);
      let count = this._counts.get(key);
      if (count == null) count = this._rowsOf(m, this._width, i).length;
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

  /**
   * Apply a streaming delta on draft `id`: adopt the draft when it is new, then read part `partId` again, or every part without `partId`.
   * @param {number} id @param {number} [partId] @returns {void}
   */
  setActive(id, partId) {
    const oldPlan = this._planCache;
    const adopted = !this._active || !sameId(this._active.id, id);
    const oldMessages = adopted && oldPlan ? this.messages() : undefined;
    if (adopted) {
      if (this._active) this._markStale(this._active.id);
      this._active = { id, type: "assistant" };
      this._resetOrder();
    }
    const refreshed = this._refreshParts(id, partId);
    const groupingChanged = adopted || refreshed.groupingChanged;
    if (!groupingChanged && !refreshed.rowsChanged) return;
    // Capture the old source only when visible rows can change.
    const sel = this.selection;
    const touches = !!sel && (sameId(sel.anchor.id, id) || sameId(sel.cursor.id, id));
    const anchors = touches ? this._anchors() : null;
    if (groupingChanged) this._planCache = null;
    if (adopted || refreshed.rowsChanged) this._markStale(id);
    if (groupingChanged) this._refreshGroupRows(oldPlan, oldMessages);
    if (touches) this._reanchor(anchors);
  }

  /**
   * Rebuild the rows of part `partId`, because its renderer reads state outside the part, such as the activity of a child agent. Nothing happens when the part has no render.
   * @param {number} id @param {number} partId @returns {void}
   */
  refreshRow(id, partId) {
    const state = this._parts.get(String(id));
    const c = state && state.rows.get(String(partId));
    if (!c) return;
    // The header text changes length, so a selection on this message moves back to the same source offsets.
    const sel = this.selection;
    const touches = !!sel && (sameId(sel.anchor.id, id) || sameId(sel.cursor.id, id));
    const anchors = touches ? this._anchors() : null;
    stale(c);
    this._markStale(id);
    if (touches) this._reanchor(anchors);
  }

  // Replace one part in the held list, or drop the list so the next render reads every part again.
  /** @param {number} id @param {number} [partId] @returns {{ groupingChanged: boolean, rowsChanged: boolean }} */
  _refreshParts(id, partId) {
    const state = this._parts.get(String(id));
    if (!state || !state.list) return { groupingChanged: true, rowsChanged: true };
    const at = partId == null ? -1 : state.list.findIndex((part) => sameId(part.id, partId));
    /** @type {PartRead | null} */
    let read = null;
    // A failing reader keeps the held part, so one bad read never drops the list.
    if (at >= 0 && this.partOf) try { read = this.partOf(id, /** @type {number} */ (partId), this._cursors.get(/** @type {Wire.AssistantPart} */ (state.list[at]))); } catch (_) {}
    let fresh = read && read.part;
    if (read && fresh && (fresh.type === "text" || fresh.type === "tool" || fresh.type === "reasoning")) {
      const before = /** @type {Wire.AssistantPart} */ (state.list[at]);
      const c = state.rows.get(String(partId));
      // A tail read carries only the new text, so the document of the held text takes it now and no build reads the whole text.
      // Any other read can change the text under the same object, so the next build sets the whole text.
      const text = c && c.text;
      if (read.tail && fresh.type !== "tool") {
        const grown = { ...fresh, text: /** @type {{ text: string }} */ (before).text + fresh.text };
        if (text && text.part === before) {
          text.ends.length = Math.min(text.doc.append(fresh.text, grown.text), text.ends.length);
          text.part = grown;
        }
        fresh = grown;
      } else if (text) text.part = null;
      state.list[at] = fresh;
      if (read.cursor) this._cursors.set(fresh, read.cursor);
      const groupingChanged = merged.groupKey.length !== 0 && partKey(before) !== partKey(fresh);
      // A delta asks the hook only when a renderer has one, so the default look pays no call per delta.
      const rowsChanged = !c || merged.sameVisible.length === 0 || hook("sameVisible", before, fresh, c.expanded) !== true;
      if (c && rowsChanged) stale(c);
      return { groupingChanged, rowsChanged };
    }
    state.list = null;
    for (const c of state.rows.values()) {
      stale(c);
      if (c.text) c.text.part = null;
    }
    return { groupingChanged: true, rowsChanged: true };
  }

  // Each read calls this, and the width and renderer rarely change, so the rebuild and its locals live in `_rebuild`.
  /** @param {number} width @returns {void} */
  _invalidate(width) {
    if (width !== this._width || this._revision !== renderRevision) this._rebuild(width);
  }

  // A width or renderer change rebuilds rows and moves the selection back to the same source offsets.
  /** @param {number} width @returns {void} */
  _rebuild(width) {
    const changed = this._revision !== renderRevision;
    const anchors = this._anchors();
    const kept = this._screenAnchor();
    this._width = width;
    this._revision = renderRevision;
    // A ctrl+o opens or folds every part, so each choice the user made one by one ends.
    if (this._expandEpoch !== expandEpoch) {
      this._expandEpoch = expandEpoch;
      this._expand.clear();
    }
    if (changed) {
      for (const state of this._parts.values()) for (const c of state.rows.values()) stale(c);
      this._planCache = null;
    }
    for (const c of this._rows.values()) stale(c);
    this._counts.clear();
    this._prefix = [0];
    if (this.selection) this._reanchor(anchors);
    if (kept) this._keepAnchor(kept);
  }

  // The text that a rebuild keeps on its screen row `y`: the caret on the screen, else the first drawn row. Without a caret, a pane at the tail follows the tail.
  /** @returns {{ pos: Position, off: number, y: number } | null} */
  _screenAnchor() {
    if (this._width <= 0 || this._prefix.length === 1) return null;
    const caret = this.caret;
    const rect = this.pager.rect();
    const y = caret && rect ? this._globalRow(caret) - this.pager.scroll : -1;
    if (caret && rect && y >= 0 && y < rect.h) return { pos: caret, off: this.sourceAt(caret), y };
    if (this.pager.stuck) return null;
    const i = this._messageAtRow(this.pager.scroll);
    const m = this._at(i);
    if (!m) return null;
    const pos = { id: m.id, row: this.pager.scroll - this._offset(i), col: 0 };
    return { pos, off: this.sourceAt(pos), y: 0 };
  }

  // A row with no source, such as a separator, keeps its row in its message instead.
  /** @param {{ pos: Position, off: number, y: number }} kept @returns {void} */
  _keepAnchor(kept) {
    const { id, row } = kept.pos;
    const pos = (kept.off >= 0 ? this.posAtSource(id, kept.off) : null) ?? { id, row: Math.min(row, Math.max(0, this.rowCountOf(id) - 1)), col: 0 };
    const g = this._globalRow(pos);
    if (g < 0) return;
    this.pager.scroll = Math.max(0, g - kept.y);
    // The draw clamps the scroll. A scroll at the tail follows the tail again.
    this.pager.stuck = false;
  }

  /** @param {number} id @returns {string} */
  _sourceOf(id) {
    this._rowsFor(id);
    const c = this._rows.get(String(id));
    if (!c) return "";
    if (c.source === null) c.source = this._joinParts(id, c.partBases);
    return c.source;
  }

  // One line feed joins two part sources, as `partBases` counts them. A part source changes only in a build of its message, so it matches the bases.
  /** @param {number} id @param {Map<string, number>} partBases @returns {string} */
  _joinParts(id, partBases) {
    // The build of the message made this state, and an eviction removes it with the message rows.
    const parts = /** @type {PartState} */ (this._parts.get(String(id))).rows;
    let source = "";
    for (const key of partBases.keys()) {
      if (source) source += "\n";
      source += /** @type {PartCache} */ (parts.get(key)).source;
    }
    return source;
  }

  // The selection as source offsets. Return null when either end carries no source.
  /** @returns {SelectionAnchors | null} */
  _anchors() {
    const sel = this.selection;
    if (!sel || this._width <= 0) return null;
    /** @param {Position} pos @returns {{ id: number, off: number, was: string, partId?: string } | null} */
    const anchor = (pos) => {
      const off = this.sourceAt(pos);
      if (off < 0) return null;
      const cache = this._rows.get(String(pos.id));
      const rows = this._rowsFor(pos.id);
      const row = pos.row >= 0 && pos.row < rows.length ? /** @type {TranscriptRow} */ (rows[pos.row]) : null;
      if (row && row.partId != null && cache) {
        const partId = String(row.partId);
        const part = this._parts.get(String(pos.id))?.rows.get(partId);
        if (part) return { id: pos.id, partId, off: off - rowSourceBase(cache, row), was: part.source };
      }
      return { id: pos.id, off, was: this._sourceOf(pos.id) };
    };
    const a = anchor(sel.anchor);
    const b = anchor(sel.cursor);
    if (!a || !b) return null;
    return {
      a,
      b,
    };
  }

  // An edit before the anchor moves the text under it, so the offset no longer names it.
  /** @param {{ id: number, off: number, was: string, partId?: string }} a @returns {Position | null} */
  _posAtAnchor(a) {
    if (a.partId != null) {
      this._rowsFor(a.id);
      const part = this._parts.get(String(a.id))?.rows.get(a.partId);
      if (!part || part.source.slice(0, a.off) !== a.was.slice(0, a.off)) return null;
      const cache = this._rows.get(String(a.id));
      const base = cache?.partBases.get(a.partId);
      return base == null ? null : this.posAtSource(a.id, base + a.off);
    }
    if (this._sourceOf(a.id).slice(0, a.off) !== a.was.slice(0, a.off)) return null;
    return this.posAtSource(a.id, a.off);
  }

  // Put the selection back on the same source text. An end on hidden text moves to the next shown row, and an end whose text changed clears the selection.
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

  /**
   * The markdown blocks of message `id`, oldest first, as source offsets. A plain turn has none.
   * @param {number} id @returns {{ kind: string, at: number, end: number }[]}
   */
  blocksOf(id) {
    this._rowsFor(id);
    const c = this._rows.get(String(id));
    const state = this._parts.get(String(id));
    if (c && state) {
      const blocks = [];
      for (const [key, base] of c.partBases) {
        const doc = state.rows.get(key)?.text?.doc;
        if (!doc) continue;
        for (const block of doc.blocks()) blocks.push({ kind: block.kind, at: base + block.at, end: base + block.end });
      }
      return blocks;
    }
    return [];
  }

  // The rendered rows of one message at the drawn width, owned by the render cache, so only this class holds them.
  /** @param {number} id @returns {TranscriptRow[]} */
  _rowsFor(id) {
    const i = this.messageIndex(id);
    if (i < 0 || this._width <= 0) return [];
    const message = /** @type {MessageDescriptor} */ (this._at(i));
    return this._rowsOf(message, this._width, i);
  }

  /**
   * The number of rendered rows in message `id` at the drawn width. 0 before the first draw or for an id outside the outline.
   * @param {number} id @returns {number}
   */
  rowCountOf(id) {
    if (this._width <= 0 || this.messageIndex(id) < 0) return 0;
    return this._counts.get(String(id)) ?? this._rowsFor(id).length;
  }

  /**
   * The rendered text of one row, or "" when the row is gone.
   * @param {number} id @param {number} row @returns {string}
   */
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
    const i = this.messageIndex(pos.id);
    if (i < 0) return -1;
    this._indexRowsThrough(Infinity);
    return pos.row < this._offset(i + 1) - this._offset(i) ? this._offset(i) + pos.row : -1;
  }

  /**
   * The message source offset under `pos`, or -1 when `pos` is null or no source is under it.
   * @param {Position | null} pos @returns {number}
   */
  sourceAt(pos) {
    if (!pos || pos.row < 0) return -1;
    const rows = this._rowsFor(pos.id);
    if (pos.row >= rows.length) return -1;
    const row = /** @type {TranscriptRow} */ (rows[pos.row]);
    return rowSourceAt(row, pos.col, rowSourceBase(this._rows.get(String(pos.id)), row));
  }

  /**
   * The position that renders source `offset` of message `id`, or the first after it, so a selection to the end survives a rewrap.
   * Past the end it answers the end of the last source text. Null when no row of the message has a source.
   * @param {number} id @param {number} offset @returns {Position | null}
   */
  posAtSource(id, offset) {
    const rows = this._rowsFor(id);
    const cache = this._rows.get(String(id));
    let tail = null;
    let tailOff = -1;
    for (let k = 0; k < rows.length; k++) {
      const row = /** @type {TranscriptRow} */ (rows[k]);
      const base = rowSourceBase(cache, row);
      const segments = segmentsOf(row);
      if (!segments) continue;
      let at = 0;
      for (const seg of segments) {
        const end = at + seg.text.length;
        if (seg.src != null) {
          if (base + /** @type {number} */ (seg.srcEnd) > offset) {
            // A caret at the end of the source before a gap belongs to that end, not past it.
            if (offset === tailOff) return tail;
            const col = offset > base + seg.src && isLinear(seg) ? at + (offset - base - seg.src) : at;
            const body = rowText(row);
            const wrapRow = { start: 0, end: body.length, soft: false };
            return { id, row: k, col: caretAtCol(body, wrapRow, term.measure(body.slice(0, Math.min(col, end)))) };
          }
          tail = { id, row: k, col: end };
          tailOff = base + /** @type {number} */ (seg.srcEnd);
        }
        at = end;
      }
    }
    return tail;
  }

  /**
   * The screen cell of a logical position, or null when it is off the drawn rows.
   * @param {Position | null} pos @returns {{ x: number, y: number } | null}
   */
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

  /**
   * Scroll the least amount that brings `pos` onto the screen.
   * @param {Position} pos @returns {void}
   */
  ensureVisible(pos) {
    this.pager.scrollIntoView(this._globalRow(pos));
  }

  // Each drawn message reads here and most hit the cache, so the build and its locals live in `_buildRows`.
  /** @param {MessageDescriptor} m @param {number} width @param {number} index @returns {TranscriptRow[]} */
  _rowsOf(m, width, index) {
    const key = String(m.id);
    const c = this._rows.get(key);
    if (c && c.w === width) {
      this._rows.delete(key);
      this._rows.set(key, c);
      return c.rows;
    }
    return this._buildRows(m, width, index, key, c);
  }

  /** @param {MessageDescriptor} m @param {number} width @param {number} index @param {string} key @param {RowCache | undefined} c @returns {TranscriptRow[]} */
  _buildRows(m, width, index, key, c) {
    // The stale render leaves first, so a fault cannot keep rows a build half wrote.
    if (c) this._rows.delete(key);
    // A viewport read trims once after the range; an individual read trims before its new entry exists.
    if (!this._viewport.has(key)) this._trimCaches();

    /** @type {TranscriptRow[]} */
    let rows;
    /** @type {string | null} */
    let source = null;
    /** @type {Map<string, number>} */
    let partBases;
    if (m.type === "assistant") {
      const built = this._partRows(m, width, index, c && c.rows);
      rows = built.rows;
      partBases = built.partBases;
    } else {
      /** @type {MessageEnv} */
      const env = { messageId: m.id, width, expanded: this._isExpanded(m.id, -1, null) };
      /** @type {Rendered | undefined} */
      const out = hook("message", m, this._allParts(m.id), env);
      rows = out ? out.rows : [];
      source = out ? out.source : "";
      // The rows of a message form one part, so a fold key and a source base of -1 name the whole message.
      for (const r of rows) {
        r.key = m.id;
        r.partId = -1;
      }
      partBases = new Map([["-1", 0]]);
    }
    if (m.error) {
      /** @type {Rendered | undefined} */
      const out = hook("error", m.error, { messageId: m.id, width, expanded: false });
      if (out) {
        // A failed message is rare, so it joins its parts at once.
        const text = source ?? this._joinParts(m.id, partBases);
        const base = text.length ? text.length + 1 : 0;
        source = text.length ? text + "\n" + out.source : out.source;
        for (const r of out.rows) {
          r.key = m.id;
          rows.push(rowAtBase(r, base));
        }
      }
    }
    if (!this._planCache || !this._planCache.joinAfter[index]) rows.push({ text: "", key: m.id });
    this._rows.set(key, { w: width, rows, source, partBases });
    this._counts.set(key, rows.length);
    return rows;
  }

  // Read every part of one message; a reader fault gives no parts, so one bad read cannot break a frame.
  /** @param {number} id @returns {readonly MessagePart[]} */
  _allParts(id) {
    try {
      const read = this.partsOf(id);
      if (Array.isArray(read)) return read;
    } catch (_) {}
    return [];
  }

  /** @param {number} id @returns {Wire.AssistantPart[]} */
  _readParts(id) {
    // A thought with no text and no duration renders nothing, such as hidden reasoning that still streams. A text part never reads that clause.
    return /** @type {Wire.AssistantPart[]} */ (this._allParts(id).filter((part) => part.type === "text" || part.type === "tool" || (part.type === "reasoning" && (part.text || part.duration_ms != null))));
  }

  // The parts of one rendered message stay held until a delta or an eviction drops them.
  /** @param {number} id */
  _partState(id) {
    const key = String(id);
    let state = this._parts.get(key);
    if (!state) {
      state = { list: this._readParts(id), rows: new Map() };
      this._parts.set(key, state);
    } else if (!state.list) state.list = this._readParts(id);
    return /** @type {PartState & { list: Wire.AssistantPart[] }} */ (state);
  }

  // The plan holds one tree value per filtered part, so a lookup is the message start plus the part index.
  /** @returns {GroupPlan} */
  _plan() {
    if (this._planCache) return this._planCache;
    return this._buildPlan((m) => {
      const held = this._parts.get(String(m.id));
      return held && held.list ? held.list : this._readParts(m.id);
    });
  }

  // Walk the outline once and record each group of consecutive parts that share a `groupKey`. `ready` reports the last message whose groups have closed, so a caller can index its rows before the walk ends.
  /** @param {(message: MessageDescriptor) => readonly Wire.AssistantPart[]} readParts @param {((last: number) => void) | null} [ready] @returns {GroupPlan} */
  _buildPlan(readParts, ready = null) {
    // One flat part list avoids retaining a JS array object for every assistant message.
    /** @type {number[]} */
    const trees = [];
    const starts = [0];
    /** @type {number[]} */
    const joinAfter = [];
    /** @type {GroupEntry[]} */
    const segment = [];
    /** @type {GroupPlan} */
    const plan = { trees, starts, joinAfter };
    this._planCache = plan;
    /** @type {string | null} */
    let openKey = null;
    // A group closes here: each part in it learns its place, and the messages it spans render without a separator.
    const flush = () => {
      if (segment.length === 0) return;
      const count = segment.length;
      for (let i = 0; i < count; i++) trees[/** @type {GroupEntry} */ (segment[i]).part] = count * GROUP_SCALE + (i === 0 ? GROUP_FIRST : 0) + (i + 1 === count ? GROUP_LAST : 0);
      const first = /** @type {GroupEntry} */ (segment[0]);
      const last = /** @type {GroupEntry} */ (segment[segment.length - 1]);
      for (let i = first.message; i < last.message; i++) joinAfter[i] = 1;
      segment.length = 0;
    };
    for (let message = 0; ; message++) {
      const m = this._at(message);
      if (!m) break;
      joinAfter.push(0);
      if (m.type !== "assistant") {
        starts.push(trees.length);
        flush();
        openKey = null;
        if (ready) ready.call(this, message);
        continue;
      }
      const messageParts = readParts(m);
      const start = trees.length;
      for (let index = 0; index < messageParts.length; index++) trees.push(0);
      starts.push(trees.length);
      for (let index = 0; index < messageParts.length; index++) {
        const key = partKey(/** @type {Wire.AssistantPart} */ (messageParts[index]));
        if (key === undefined) continue;
        if (key !== openKey) flush();
        openKey = key;
        if (key !== null) segment.push({ part: start + index, message });
      }
      if (m.error) {
        flush();
        openKey = null;
      }
      if (ready && segment.length === 0) ready.call(this, message);
    }
    flush();
    plan.trees = new Float64Array(trees);
    plan.starts = new Float64Array(starts);
    plan.joinAfter = new Uint8Array(joinAfter);
    // The last group has closed, so every message is ready; the draft sits one past the committed ones.
    if (ready) ready.call(this, this._messages.length + (this._active ? 0 : -1));
    return plan;
  }

  // Mark stale every message whose `groupKey` group changed. Walk the old outline, because a message that left it still holds rows drawn against the old plan.
  /** @param {GroupPlan | null} oldPlan @param {MessageDescriptor[]} [oldMessages] @returns {void} */
  _refreshGroupRows(oldPlan, oldMessages) {
    if (!oldPlan) return;
    const next = this._plan();
    // Without a new order the live list is the old one, so a streamed part copies no message.
    for (let i = 0, m; (m = oldMessages ? oldMessages[i] : this._at(i)); i++) {
      const index = this.messageIndex(m.id);
      if (index < 0) continue;
      let changed = oldPlan.joinAfter[i] !== next.joinAfter[index];
      if (!changed && m.type === "assistant") {
        const before = oldPlan.starts[i] || 0;
        const after = next.starts[index] || 0;
        const length = (oldPlan.starts[i + 1] || 0) - before;
        changed = length !== (next.starts[index + 1] || 0) - after;
        for (let p = 0; !changed && p < length; p++) {
          if (oldPlan.trees[before + p] !== next.trees[after + p]) {
            changed = true;
            break;
          }
        }
      }
      if (changed) this._markStale(m.id);
    }
  }

  /** @param {number} id @param {number} partId @returns {string} */
  _expandKey(id, partId) {
    return String(id) + ":" + String(partId);
  }

  /** @param {number} id @param {number} partId @returns {boolean} */
  _reasoningLive(id, partId) {
    if (!sameId(this._active?.id, id)) return false;
    const parts = this._partState(id).list;
    const last = parts.length ? parts[parts.length - 1] : null;
    return !!last && last.type === "reasoning" && sameId(last.id, partId);
  }

  // The choice of the user wins, then ctrl+o, then the `fold` hook of the renderers. A whole message (`partId` -1) has no `fold`.
  /** @param {number} id @param {number} partId @param {Wire.AssistantPart | null} part @returns {boolean} */
  _isExpanded(id, partId, part) {
    const choice = this._expand.get(this._expandKey(id, partId));
    if (choice !== undefined) return choice;
    if (expandAll) return true;
    return !!part && merged.fold.length !== 0 && hook("fold", part, part.type === "reasoning" && this._reasoningLive(id, partId)) === true;
  }

  /**
   * Open a folded part or fold an open part, and redraw. `partId` -1 names a whole message.
   * @param {number} id @param {number} partId @returns {void}
   */
  togglePart(id, partId) {
    let part = null;
    if (partId !== -1) for (const p of this._partState(id).list) if (sameId(p.id, partId)) part = p;
    this._expand.set(this._expandKey(id, partId), !this._isExpanded(id, partId, part));
    this._markStale(id);
    root.invalidate();
  }

  /**
   * The whole text of field `field` of part `partId`: "arguments", "text", or a field of the tool state such as "output" or "error".
   * The engine cuts a long field, so this reads the rest page by page. A page that fails or does not advance ends the read with a note.
   * @param {number} id @param {number} partId @param {string} field @returns {string}
   */
  readField(id, partId, field) {
    const part = this._partState(id).list.find((entry) => sameId(entry.id, partId));
    if (!part) return "";
    const own = /** @type {Record<string, unknown>} */ (field === "arguments" || field === "text" ? part : /** @type {{ state?: object }} */ (part).state || {});
    let text = String(own[field] ?? "");
    const cuts = /** @type {{ cut?: readonly { field?: string, next?: number | null }[] }} */ (part).cut || [];
    const cut = cuts.find((entry) => entry.field === field && entry.next != null);
    if (!cut || !this.partTextPage) return text;
    let offset = /** @type {number} */ (cut.next);
    if (!Number.isSafeInteger(offset) || offset < 0) return text + FIELD_UNREAD;
    while (true) {
      let page = null;
      try {
        page = this.partTextPage(id, part.id, field, offset, 0);
      } catch (_) {}
      if (!page || typeof page.text !== "string") return text + FIELD_UNREAD;
      text += page.text;
      if (page.next == null) return text;
      if (!Number.isSafeInteger(page.next) || page.next <= offset) return text + FIELD_UNREAD;
      offset = page.next;
    }
  }

  /**
   * The part under a logical position, or null on a row of no part, such as a separator.
   * @param {Position | null} pos @returns {PartHit | null}
   */
  partAt(pos) {
    if (!pos) return null;
    const rows = this._rowsFor(pos.id);
    const row = pos.row >= 0 && pos.row < rows.length ? rows[pos.row] : null;
    if (!row || row.partId == null) return null;
    return { id: pos.id, partId: row.partId, row };
  }

  /**
   * Act on the part under `pos`: the `activate` hook of the renderers first, else a fold toggle when the part has a header row.
   * It answers where the reader lands, or null when no part acts.
   * @param {Position} pos @returns {Position | null}
   */
  activate(pos) {
    const hit = this.partAt(pos);
    if (!hit) return null;
    /** @type {Position | null | undefined} */
    const out = hook("activate", hit, this);
    if (out !== undefined) return out;
    if (!this.partHeader(hit.id, hit.partId)) return null;
    this.togglePart(hit.id, hit.partId);
    const header = this.partHeader(hit.id, hit.partId) ?? pos;
    this.ensureVisible(header);
    return header;
  }

  /**
   * The position of the header row of a part, or null when the part has none.
   * @param {number} id @param {number} partId @returns {Position | null}
   */
  partHeader(id, partId) {
    const rows = this._rowsFor(id);
    for (let row = 0; row < rows.length; row++) {
      const r = /** @type {TranscriptRow} */ (rows[row]);
      if (r.partId === partId && r.header) return { id, row, col: 0 };
    }
    return null;
  }

  /**
   * The next part stop after `pos` when `dir` is above 0, else the previous one. Null when `pos` is null or no stop is left.
   * A stop is a row with `stop` set: the renderers set it, and the first row of a text part has it.
   * @param {Position | null} pos @param {number} dir @returns {Position | null}
   */
  partStep(pos, dir) {
    if (!pos) return null;
    const step = dir > 0 ? 1 : -1;
    for (let i = this.messageIndex(pos.id); i >= 0; i += step) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsFor(m.id);
      for (let n = step > 0 ? 0 : rows.length - 1; n >= 0 && n < rows.length; n += step) {
        if (!(/** @type {TranscriptRow} */ (rows[n]).stop)) continue;
        const stop = { id: m.id, row: n, col: 0 };
        if (this.comparePos(stop, pos) * step > 0) return stop;
      }
    }
    return null;
  }

  // Each part renders once per width, fold, and live state, so a delta rebuilds only the changed part.
  // `old` is the stale render's rows, which the caller already removed from the cache, so this build writes them in place.
  /** @param {MessageDescriptor} m @param {number} width @param {number} messageIndex @param {TranscriptRow[] | undefined} old @returns {{ rows: TranscriptRow[], partBases: Map<string, number> }} */
  _partRows(m, width, messageIndex, old) {
    const state = this._partState(m.id);
    const plan = merged.groupKey.length ? this._plan() : null;
    const start = plan ? plan.starts[messageIndex] || 0 : 0;
    const seen = new Set();
    // The old rows stay in place up to the first row a build changed.
    const rows = old || [];
    let reuse = !!old;
    let n = 0;
    let shown = 0;
    const partBases = new Map();
    // The length of the joined part sources, so a build places each part without the joined string.
    let length = 0;
    const list = state.list;
    for (let index = 0; index < list.length; index++) {
      const part = /** @type {Wire.AssistantPart} */ (list[index]);
      const tree = plan ? plan.trees[start + index] || 0 : 0;
      const head = tree !== 0 && (tree & GROUP_FIRST) !== 0;
      const gap = shown++ === 0 ? 0 : merged.gap;
      if (length) length++;
      const base = length;
      const key = String(part.id);
      seen.add(key);
      const expanded = part.type === "text" || this._isExpanded(m.id, part.id, part);
      const live = part.type === "reasoning" && this._reasoningLive(m.id, part.id);
      let c = state.rows.get(key);
      let built = false;
      if (!c || c.w !== width || c.expanded !== expanded || c.live !== live || c.shape !== tree) {
        c = this._buildPart(m.id, part, width, expanded, live, tree, c);
        state.rows.set(key, c);
        built = true;
      }
      partBases.set(key, base);
      length = base + c.source.length;
      // A row belongs to one part build, so an old first row places the part where it was; a rebuilt part keeps only the rows its text kept and writes its group header again.
      if (reuse && (built && head || !c.rows.length || rows[n + gap + (head ? c.lead : 0)] !== c.rows[0])) {
        rows.length = n;
        reuse = false;
      }
      if (!reuse) {
        for (let g = 0; g < gap; g++) rows.push({ text: "", key: m.id });
        if (head) {
          /** @type {TranscriptRow[]} */
          const header = hook("groupHeader", { key: partKey(part), count: Math.floor(tree / GROUP_SCALE) }, { messageId: m.id, width, expanded: false }) || [];
          c.lead = header.length;
          for (const r of header) {
            r.key = m.id;
            rows.push(r);
          }
        }
      }
      const at = n + gap + (head ? c.lead : 0);
      const own = c.rows;
      const end = own.length;
      const from = !reuse ? 0 : !built ? end : c.text ? c.text.kept : 0;
      if (from < end) {
        if (reuse) rows.length = at + from;
        reuse = false;
        for (let k = from; k < end; k++) rows.push(/** @type {TranscriptRow} */ (own[k]));
      }
      n = at + end;
    }
    for (const key of state.rows.keys()) if (!seen.has(key)) state.rows.delete(key);
    if (reuse) rows.length = n;
    return { rows, partBases };
  }

  // Render one part at source base 0; retain rows before the last two markdown blocks.
  /** @param {number} id @param {Wire.AssistantPart} part @param {number} width @param {boolean} expanded @param {boolean} live @param {number} tree @param {PartCache | undefined} previous @returns {PartCache} */
  _buildPart(id, part, width, expanded, live, tree, previous) {
    if (part.type === "text") {
      const indent = merged.indent;
      const contentW = Math.max(1, width - indent);
      const text = previous?.text || { doc: new Document(), part: null, width: contentW, ends: [], kept: 0 };
      const { doc, ends } = text;
      // A tail read already appended to the document, so only a new part object sets the whole text.
      const keep = text.part === part ? -1 : doc._setText(part.text);
      text.part = part;
      if (text.width !== contentW) ends.length = 0;
      else if (keep >= 0) ends.length = Math.min(keep, ends.length);
      text.width = contentW;
      const rows = previous?.text === text ? previous.rows : [];
      rows.length = ends.at(-1) || 0;
      text.kept = rows.length;
      for (let i = ends.length; i < doc._blocks.length; i++) {
        if (i) rows.push({ segments: [{ text: "", group: "MdText" }], indent, key: id, partId: part.id, kind: "text" });
        const block = /** @type {Block} */ (doc._blocks[i]);
        for (const r of doc._blockRows(block, contentW)) {
          // Only the first row of a part is a stop, so the other rows keep one shape and copy one field less.
          /** @type {TranscriptRow} */
          const row = { segments: r.segments, indent, key: id, partId: part.id, kind: "text" };
          if (rows.length === 0) row.stop = true;
          rows.push(row);
        }
        ends.push(rows.length);
      }
      return { w: width, expanded, live, shape: tree, lead: 0, rows, source: doc.sourceText(), text };
    }
    /** @type {PartEnv} */
    const env = { messageId: id, width, expanded, live, group: tree ? { count: Math.floor(tree / GROUP_SCALE), first: (tree & GROUP_FIRST) !== 0, last: (tree & GROUP_LAST) !== 0 } : null, tools: merged.tools };
    /** @type {Rendered | undefined} */
    const out = hook("part", part, env);
    const rows = out ? out.rows : [];
    // The renderer answers new rows, so the core writes the owner of each one in place.
    for (const r of rows) {
      r.key = id;
      r.partId = part.id;
    }
    return { w: width, expanded, live, shape: tree, lead: 0, rows, source: out ? out.source : "", text: null };
  }

  /** @param {number} i @returns {MessageDescriptor | null} */
  _at(i) {
    return i < this._messages.length ? /** @type {MessageDescriptor} */ (this._messages[i]) : i === this._messages.length ? this._active : null;
  }

  /**
   * The order index of message `id`, or -1 when `id` is outside the outline. The streaming draft comes last.
   * @param {number} id @returns {number}
   */
  messageIndex(id) {
    return this._positions.get(String(id)) ?? -1;
  }

  // Order the two ends and resolve them to message indexes. Return null without a live selection.
  /** @returns {SelectionRange | null} */
  _range() {
    const sel = this.selection;
    if (!sel) return null;
    const a = sel.anchor;
    const b = sel.cursor;
    const ia = this.messageIndex(a.id);
    const ib = this.messageIndex(b.id);
    if (ia < 0 || ib < 0) return null;
    const ordered = this.comparePos(a, b) <= 0;
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

  /**
   * The selection as shown text, one line feed between rows and no indent, or "" without a selection.
   * With `source`, a turn whose rows map to markdown gives that markdown instead.
   * @param {boolean} [source] @returns {string}
   */
  selectedText(source = false) {
    const range = this._range();
    if (!range || this._width <= 0) return "";
    const out = [];
    for (let i = range.si; i <= range.ei; i++) {
      const m = this._at(i);
      if (!m) break;
      const rows = this._rowsOf(m, this._width, i);
      const cache = source ? this._rows.get(String(m.id)) : undefined;
      const plain = [];
      let from = -1;
      let to = -1;
      for (let k = 0; k < rows.length; k++) {
        const row = /** @type {TranscriptRow} */ (rows[k]);
        const body = rowText(row);
        const r = this._rowRange(range, i, k, body.length);
        if (!r) continue;
        plain.push(body.slice(r.from, r.to));
        const span = source ? rowSourceSpan(row, r.from, r.to, rowSourceBase(cache, row)) : null;
        if (!span) continue;
        if (from < 0 || span.from < from) from = span.from;
        if (span.to > to) to = span.to;
      }
      if (from >= 0) out.push(this._sourceOf(m.id).slice(from, to));
      else if (plain.length) out.push(plain.join("\n"));
    }
    return out.join("\n");
  }

  /**
   * The total number of rendered rows at `width`. It renders each message whose count it does not know yet.
   * @param {number} width @returns {number}
   */
  rowCount(width) {
    if (width <= 0) return 0;
    this._invalidate(width);
    this._indexRowsThrough(Infinity);
    return this._offset(this._prefix.length - 1);
  }

  /** @param {number} width @param {number} top @param {number} height @param {boolean} absolute @param {TranscriptRow[]} out @param {number[]} sel @returns {void} */
  _rowsRange(width, top, height, absolute, out, sel) {
    if (width <= 0 || height <= 0) return;
    this._invalidate(width);
    this._indexRowsThrough(Infinity);
    const first = this._messageAtRow(top);
    this._viewport.clear();
    const range = this._range();
    for (let i = first; i + 1 < this._prefix.length && this._offset(i) < top + height; i++) {
      const m = /** @type {MessageDescriptor} */ (this._at(i));
      // A message joins the viewport before its read, so the read trims nothing this pass draws.
      this._viewport.add(String(m.id));
      const rows = this._rowsOf(m, width, i);
      const cache = this._rows.get(String(m.id));
      const base = this._offset(i);
      for (let k = Math.max(0, top - base); k < rows.length && base + k < top + height; k++) {
        const local = /** @type {TranscriptRow} */ (rows[k]);
        const row = absolute ? rowAtBase(local, rowSourceBase(cache, local)) : local;
        out.push(row);
        // The pager paints the selection from `sel`, so a cached row never carries one.
        const r = range && this._rowRange(range, i, k, rowText(row).length);
        if (r && r.to > r.from) sel.push(out.length - 1, r.from, r.to);
      }
    }
    this._trimCaches();
  }

  /**
   * A new list of the rendered rows from row `top` for `height` rows at `width`. Source offsets count from the start of each message source.
   * @param {number} width @param {number} top @param {number} height @returns {TranscriptRow[]}
   */
  rows(width, top, height) {
    /** @type {TranscriptRow[]} */
    const out = [];
    snapshotSel.length = 0;
    this._rowsRange(width, top, height, true, out, snapshotSel);
    return out;
  }

  /**
   * The committed messages oldest first, then the streaming draft, each a copy the caller cannot write through.
   * @returns {MessageDescriptor[]}
   */
  messages() {
    const out = this._messages.map((m) => ({ ...m }));
    if (this._active) out.push({ ...this._active });
    return out;
  }

  /**
   * The number of committed messages, plus one for a streaming draft.
   * @returns {number}
   */
  messageCount() {
    return this._messages.length + (this._active ? 1 : 0);
  }

  /**
   * The id of the message at order `index`. The streaming draft comes last. Throws a RangeError when `index` is out of range.
   * @param {number} index @returns {number}
   */
  messageIdAt(index) {
    const m = this._at(index);
    if (!m) throw new RangeError("message index out of range");
    return m.id;
  }

  /**
   * Draw the visible rows into `rect`.
   * @param {Rect} rect @returns {void}
   */
  draw(rect) {
    this.pager.draw(rect);
  }

  /**
   * The logical position before the grapheme under a screen cell, or after it when `after` is true. Null off the drawn rows. `clamp` pulls a drag back to the nearest row.
   * @param {number} col @param {number} row @param {boolean} clamp @param {boolean} [after] @returns {Position | null}
   */
  posAt(col, row, clamp, after = false) {
    const rect = this.pager.rect();
    if (!rect) return null;
    const y = clamp ? Math.min(Math.max(row, rect.y), rect.y + rect.h - 1) : row;
    const g = this.pager.rowAtY(y);
    if (g < 0) return null;
    this._indexRowsThrough(Infinity);
    const i = this._messageAtRow(g);
    const m = this._at(i);
    if (!m) return null;
    const rows = this._rowsOf(m, this._width, i);
    const k = g - this._offset(i);
    const line = /** @type {TranscriptRow} */ (rows[k]);
    const body = rowText(line);
    const x = Math.max(0, col - rect.x - (line.indent || 0));
    const wrapRow = { start: 0, end: body.length, soft: false };
    return { id: m.id, row: k, col: caretAtCol(body, wrapRow, x, after) };
  }

  /**
   * A left drag selects text: a press records the start and a drag opens the range, so a click leaves no one-cell range.
   * A click on a part opens or folds it. The wheel scrolls. A finished selection goes to `onSelect`.
   * @param {MouseEvent} ev @returns {boolean}
   */
  onMouse(ev) {
    if (isWheel(ev.button)) return this.pager.onMouse(ev);
    if (ev.button !== "left") return false;
    if (ev.event === "press") {
      const r = this.pager.rect();
      if (!r || ev.col < r.x || ev.col >= r.x + r.w) return false;
      const pos = this.posAt(ev.col, ev.row, false);
      this.clearSelection();
      this._press = pos;
      this._pressCol = ev.col;
      this._pressEnd = null;
      this._dragging = pos != null;
      this._didDrag = false;
      return true;
    }
    if (!this._dragging) return false;
    if (ev.event === "drag") {
      this._didDrag = true;
      const press = this._press;
      const r = this.pager.rect();
      if (!press || !r) return true;
      // A drag past the edge clamps, so the selection follows the pointer out of the pane.
      const g = this.pager.scroll + Math.min(Math.max(ev.row, r.y), r.y + r.h - 1) - r.y;
      const p = this._globalRow(press);
      // The selection holds both end cells, so the later end reads the caret after its grapheme. The screen order needs no row scan.
      if (g > p || (g === p && ev.col >= this._pressCol)) {
        const end = this.posAt(ev.col, ev.row, true, true);
        if (end) this.selection = { anchor: press, cursor: end };
      } else {
        const start = this.posAt(ev.col, ev.row, true);
        if (start) this.selection = { anchor: (this._pressEnd ??= this._after(press)), cursor: start };
      }
      return true;
    }
    if (ev.event === "release") {
      const press = this._press;
      const dragged = this._didDrag;
      this._dragging = false;
      this._press = null;
      this._didDrag = false;
      if (!dragged && press && this.activate(press)) {
        this.clearSelection();
        return true;
      }
      const selected = this.selectedText();
      if (selected === "") this.clearSelection();
      else if (this.onSelect) this.onSelect(selected);
      return true;
    }
    return false;
  }
}
