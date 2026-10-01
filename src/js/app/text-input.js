// Edit text and map its UTF-16 offsets to terminal cells.
import { term } from "yuke:internal/native/term";
import { strokeOf, textOf } from "yuke:internal/keys";

/** @typedef {{ onChange?: (() => void) | null, onEdit?: ((from: number, to: number, insertedLength: number) => void) | null }} TextInputOptions */
/** @typedef {{ at: number, cls: number }} GraphemeCell */
/** @typedef {{ start: number, end: number, soft: boolean }} WrapRow */
/**
 * Limit `s` to `max` terminal cells. With `ellipsis`, a cut ends in "…". Pass `width`, the cell width of `s`, when you already have it.
 * @param {string} s @param {number} max @param {boolean} [ellipsis] @param {number} [width] @returns {string}
 */
export function clip(s, max, ellipsis = true, width = -1) {
  if (max <= 0) return "";
  // A caller that measured `s` passes the width, so a fitted string costs no second measure.
  if ((width >= 0 ? width : term.measure(s)) <= max) return s;
  const ell = ellipsis && max > 1 ? 1 : 0;
  return s.slice(0, term.fit(s, max - ell)) + (ell ? "…" : "");
}

// Wrap `s` and keep its UTF-16 offsets as [start, end) plus a soft flag, because a plain wrap drops the space runs.
/** @param {string} s @param {number} width @returns {WrapRow[]} */
export function wrapText(s, width) {
  const wrapped = term.wrap(s, width).rows;
  const rows = /** @type {WrapRow[]} */ ([]);
  for (let i = 0; i < wrapped.length; i += 3) {
    rows.push({ start: /** @type {number} */ (wrapped[i]), end: /** @type {number} */ (wrapped[i + 1]), soft: wrapped[i + 2] !== 0 });
  }
  return rows;
}

// Place `caret` in the rows of `wrapText`; a soft break takes the next row, so the caret stays on the screen.
/** @param {string} s @param {WrapRow[]} rows @param {number} caret @returns {{ row: number, col: number }} */
export function caretRowCol(s, rows, caret) {
  for (let i = 0; i < rows.length; i++) {
    const r = /** @type {WrapRow} */ (rows[i]);
    if (caret > r.end) continue;
    if (caret === r.end && r.soft && i + 1 < rows.length) continue;
    return { row: i, col: term.measure(s.slice(r.start, caret)) };
  }
  const last = /** @type {WrapRow} */ (rows[rows.length - 1]);
  return { row: rows.length - 1, col: term.measure(s.slice(last.start, last.end)) };
}

// Return the caret index in `row` before the grapheme under the cell column `col`, or after it when `after` is true.
/** @param {string} s @param {WrapRow} row @param {number} col @param {boolean} [after] @returns {number} */
export function caretAtCol(s, row, col, after = false) {
  const line = s.slice(row.start, row.end);
  const gs = term.graphemes(line);
  let w = 0;
  for (let k = 0; k < gs.length; k += 3) {
    const cellWidth = /** @type {number} */ (gs[k + 2]);
    // Each grapheme is a triple of its start, its length, and its width.
    if (w + cellWidth > col) return row.start + /** @type {number} */ (gs[k]) + (after ? /** @type {number} */ (gs[k + 1]) : 0);
    w += cellWidth;
  }
  return row.end;
}

// QuickJS builds a new RegExp each time a literal runs, so the per-grapheme tests hold one each.
const BLANK = /\s/u;
const WORD = /[\p{L}\p{N}_]/u;

// A blank, a word character, or punctuation. A word motion stops where the class changes.
/** @param {string} g @returns {number} */
function graphemeClass(g) {
  if (!g || BLANK.test(g)) return 0;
  return WORD.test(g) ? 1 : 2;
}

// The graphemes of `s` with their offset and class, so a word motion never lands inside a cluster.
/** @param {string} s @returns {GraphemeCell[]} */
function graphemeCells(s) {
  const gs = term.graphemes(s);
  /** @type {GraphemeCell[]} */
  const out = [];
  for (let k = 0; k < gs.length; k += 3) {
    const at = /** @type {number} */ (gs[k]);
    const length = /** @type {number} */ (gs[k + 1]);
    out.push({ at, cls: graphemeClass(s.slice(at, at + length)) });
  }
  return out;
}

/** @param {GraphemeCell[]} cells @param {number} at @returns {number} */
function cellIndex(cells, at) {
  for (let i = 0; i < cells.length; i++) if (/** @type {GraphemeCell} */ (cells[i]).at >= at) return i;
  return cells.length;
}

// The start of the next word, or the end of the text. This is vim's `w`.
/** @param {string} s @param {number} at @returns {number} */
export function nextWordStart(s, at) {
  const cells = graphemeCells(s);
  let i = cellIndex(cells, at);
  const cls = i < cells.length ? /** @type {GraphemeCell} */ (cells[i]).cls : 0;
  if (cls !== 0) while (i < cells.length && /** @type {GraphemeCell} */ (cells[i]).cls === cls) i++;
  while (i < cells.length && /** @type {GraphemeCell} */ (cells[i]).cls === 0) i++;
  return i < cells.length ? /** @type {GraphemeCell} */ (cells[i]).at : s.length;
}

// The start of the previous word, or the start of the text. This is vim's `b`.
/** @param {string} s @param {number} at @returns {number} */
export function prevWordStart(s, at) {
  const cells = graphemeCells(s);
  let i = cellIndex(cells, at) - 1;
  while (i >= 0 && /** @type {GraphemeCell} */ (cells[i]).cls === 0) i--;
  if (i < 0) return 0;
  const cls = /** @type {GraphemeCell} */ (cells[i]).cls;
  while (i > 0 && /** @type {GraphemeCell} */ (cells[i - 1]).cls === cls) i--;
  return /** @type {GraphemeCell} */ (cells[i]).at;
}

// The last grapheme of the word at or after the caret. This is vim's `e`, which lands on the char.
/** @param {string} s @param {number} at @returns {number} */
export function nextWordEnd(s, at) {
  const cells = graphemeCells(s);
  let i = cellIndex(cells, at) + 1;
  while (i < cells.length && /** @type {GraphemeCell} */ (cells[i]).cls === 0) i++;
  if (i >= cells.length) return s.length;
  const cls = /** @type {GraphemeCell} */ (cells[i]).cls;
  while (i + 1 < cells.length && /** @type {GraphemeCell} */ (cells[i + 1]).cls === cls) i++;
  return /** @type {GraphemeCell} */ (cells[i]).at;
}

// A caret step reads this many code units around the caret. No grapheme cluster is this long.
const grapheme_window = 256;

// A step needs only the grapheme beside the caret, so it scans a window and not the whole text.
/** @param {string} s @param {number} at @returns {number} */
export function prevGrapheme(s, at) {
  const from = Math.max(0, at - grapheme_window);
  const gs = term.graphemes(s.slice(from, at));
  let p = from;
  for (let k = 0; k < gs.length; k += 3) p = from + /** @type {number} */ (gs[k]);
  return p;
}

/** @param {string} s @param {number} at @returns {number} */
export function nextGrapheme(s, at) {
  const to = Math.min(s.length, at + grapheme_window);
  const gs = term.graphemes(s.slice(at, to));
  if (gs.length === 0) return s.length;
  const offset = /** @type {number} */ (gs[0]);
  const length = /** @type {number} */ (gs[1]);
  return at + offset + length;
}

/**
 * A text buffer with a caret: the edit state of a query line, a prompt, or a composer.
 * Each offset is a UTF-16 index into `text`. `onKey` applies the common line keys.
 */
export class TextInput {
  /** @param {TextInputOptions} opts */
  constructor(opts = {}) {
    /** The buffer. Change it through `setText`, `replace`, or `insert`, so the hooks run. */
    this.text = "";
    /** The caret offset in `text`. A direct set moves the caret and runs no hook. */
    this.caret = 0;
    /**
     * Called after each edit.
     * @type {(() => void) | null}
     */
    this.onChange = opts.onChange || null;
    /**
     * Reports the range [from, to) that an edit replaced and the inserted length, for an owner that keeps its own offsets.
     * @type {((from: number, to: number, insertedLength: number) => void) | null}
     */
    this.onEdit = opts.onEdit || null;
  }

  /**
   * Replace the whole text and put the caret at the end. `setText("")` clears the buffer.
   * @param {string} s
   * @returns {void}
   */
  setText(s) {
    const had = this.text.length;
    this.text = String(s);
    this.caret = this.text.length;
    this.onEdit?.(0, had, this.text.length);
    this.onChange?.();
  }

  /**
   * The text before the caret.
   * @returns {string}
   */
  beforeCaret() {
    return this.text.slice(0, this.caret);
  }

  /**
   * Replace [from, to) with `s`. The caret lands after the new text.
   * @param {number} from
   * @param {number} to
   * @param {string} s
   * @returns {void}
   */
  replace(from, to, s) {
    s = String(s);
    this.text = this.text.slice(0, from) + s + this.text.slice(to);
    this.caret = from + s.length;
    this.onEdit?.(from, to, s.length);
    this.onChange?.();
  }

  /**
   * Insert `s` at the caret with one edit, and put the caret after it. An empty `s` does nothing.
   * @param {string} s
   * @returns {void}
   */
  insert(s) {
    s = String(s);
    if (s !== "") this.replace(this.caret, this.caret, s);
  }

  /**
   * Apply one key: left, right, home, end, ctrl+a, ctrl+e, backspace, delete, ctrl+w, ctrl+u, or typed text.
   * Answer false for any other key. A caret move steps over a whole grapheme.
   * @param {HostEvent} ev
   * @returns {boolean}
   */
  onKey(ev) {
    const s = strokeOf(/** @type {Extract<HostEvent, { type: "key" }>} */ (ev));
    switch (s) {
      case "left":
        this.caret = prevGrapheme(this.text, this.caret);
        return true;
      case "right":
        this.caret = nextGrapheme(this.text, this.caret);
        return true;
      case "home":
      case "ctrl+a":
        this.caret = 0;
        return true;
      case "end":
      case "ctrl+e":
        this.caret = this.text.length;
        return true;
      case "backspace": {
        const p = prevGrapheme(this.text, this.caret);
        if (p !== this.caret) this.replace(p, this.caret, "");
        return true;
      }
      case "delete": {
        const n = nextGrapheme(this.text, this.caret);
        if (n !== this.caret) this.replace(this.caret, n, "");
        return true;
      }
      case "ctrl+w": {
        // Delete back over blanks, then over the word before them.
        let p = this.caret;
        while (p > 0 && this.text[p - 1] === " ") p--;
        while (p > 0 && this.text[p - 1] !== " ") p--;
        if (p !== this.caret) this.replace(p, this.caret, "");
        return true;
      }
      case "ctrl+u":
        if (this.caret > 0) this.replace(0, this.caret, "");
        return true;
    }
    const ins = textOf(ev);
    if (ins === "") return false;
    this.insert(ins);
    return true;
  }
}

/** @param {number} w @param {string} prompt @param {string} before @returns {number} */
export function caretCol(w, prompt, before) {
  return Math.min(w - 1, term.measure(prompt + before));
}
