// The fzy fuzzy matcher that ranks picker candidates.

// The fzy algorithm over code points, so an astral char never splits. See github.com/jhawthorn/fzy.
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

// QuickJS builds a new RegExp each time a literal runs, so the per-char test holds one.
const WORD_CHAR = /[\p{L}\p{N}]/u;

// The bonuses and score rows every match reuses, so a keystroke over a long list allocates nothing per item.
// They grow to the longest text that aligns, at most FUZZY_MAX_LEN. A match runs to its end without a callback.
// Until the first match every row is one empty array, so a boot with no picker pays for none.
const EMPTY = new Float64Array(0);
let capacity = 0;
/** @type {Array<number | string>} */
let keys = [];
let bonus = EMPTY;
let D = EMPTY; // best score that ends in a match at text i
let M = EMPTY; // best score for query[0..j] over text[0..i]
let Dprev = EMPTY;
let Mprev = EMPTY;

// A code point as `toLowerCase` folds it: a number when the fold is one code point, else the folded string.
// Two folds are equal exactly when their lowercase strings are.
/** @param {number} c @returns {number | string} */
function fold(c) {
  if (c < 128) return c >= 65 && c <= 90 ? c + 32 : c;
  const lower = String.fromCodePoint(c).toLowerCase();
  const first = /** @type {number} */ (lower.codePointAt(0));
  return lower.length === (first > 0xffff ? 2 : 1) ? first : lower;
}

/** @param {number} c @returns {boolean} */
function isUpper(c) {
  if (c < 128) return c >= 65 && c <= 90;
  const s = String.fromCodePoint(c);
  return s !== s.toLowerCase() && s === s.toUpperCase();
}

/** @param {number} c @returns {boolean} */
function isLower(c) {
  if (c < 128) return c >= 97 && c <= 122;
  const s = String.fromCodePoint(c);
  return s !== s.toUpperCase() && s === s.toLowerCase();
}

// The bonus for a code point given the one before it. fzy rewards a boundary only for a word char.
/** @param {number} prev @param {number} cur @returns {number} */
function charBonus(prev, cur) {
  if (isLower(prev) && isUpper(cur)) return MATCH_CAPITAL;
  const word = cur < 128 ? (cur >= 48 && cur <= 57) || ((cur | 32) >= 97 && (cur | 32) <= 122) : WORD_CHAR.test(String.fromCodePoint(cur));
  if (!word) return 0;
  if (prev === 47) return MATCH_SLASH; // "/"
  if (prev === 45 || prev === 95 || prev === 32) return MATCH_WORD; // "-", "_", " "
  if (prev === 46) return MATCH_DOT; // "."
  return 0;
}

/** @param {string} query @returns {Array<number | string>} */
function foldQuery(query) {
  const out = [];
  for (let i = 0; i < query.length; ) {
    const c = /** @type {number} */ (query.codePointAt(i));
    i += c > 0xffff ? 2 : 1;
    out.push(fold(c));
  }
  return out;
}

// Score the folded `query` against `text`; null when the query is not a subsequence. Higher is better.
/** @param {string} text @param {Array<number | string>} query @returns {number | null} */
function score(text, query) {
  const m = query.length;
  // One pass counts the code points and tests the subsequence, so a miss costs no row work.
  let n = 0;
  let qi = 0;
  for (let i = 0; i < text.length; n++) {
    const c = /** @type {number} */ (text.codePointAt(i));
    i += c > 0xffff ? 2 : 1;
    if (qi < m && fold(c) === query[qi]) qi++;
  }
  if (qi < m) return null;
  if (n > FUZZY_MAX_LEN) return SCORE_MIN; // too long to align; it matches but ranks last
  if (n === m) return SCORE_MAX; // a same-length subsequence is an exact match

  if (n > capacity) {
    capacity = Math.min(FUZZY_MAX_LEN, Math.max(n, capacity * 2, 64));
    keys = new Array(capacity);
    bonus = new Float64Array(capacity);
    D = new Float64Array(capacity);
    M = new Float64Array(capacity);
    Dprev = new Float64Array(capacity);
    Mprev = new Float64Array(capacity);
  }
  let prev = 47; // "/"
  for (let i = 0, k = 0; k < n; k++) {
    const c = /** @type {number} */ (text.codePointAt(i));
    i += c > 0xffff ? 2 : 1;
    keys[k] = fold(c);
    bonus[k] = charBonus(prev, c);
    prev = c;
  }
  for (let j = 0; j < m; j++) {
    const gap = j === m - 1 ? GAP_TRAILING : GAP_INNER;
    const q = query[j];
    // Row j reads row j - 1, so the two pairs trade places; row 0 reads nothing.
    let held = Dprev;
    Dprev = D;
    D = held;
    held = Mprev;
    Mprev = M;
    M = held;
    let prevM = SCORE_MIN;
    for (let i = 0; i < n; i++) {
      if (q === keys[i]) {
        let s = SCORE_MIN;
        if (j === 0) s = i * GAP_LEADING + /** @type {number} */ (bonus[i]);
        else if (i > 0) s = Math.max(/** @type {number} */ (Mprev[i - 1]) + /** @type {number} */ (bonus[i]), /** @type {number} */ (Dprev[i - 1]) + MATCH_CONSECUTIVE);
        D[i] = s;
        M[i] = prevM = Math.max(s, prevM + gap);
      } else {
        D[i] = SCORE_MIN;
        M[i] = prevM = prevM + gap;
      }
    }
  }
  return /** @type {number} */ (M[n - 1]);
}

// Rank `items` by fuzzy score and drop non-matches; ties break by shorter text, then lexicographically.
/** @template T @param {T[]} items @param {string} query @param {(item: T) => string} textOf @returns {T[]} */
export function fuzzyRank(items, query, textOf) {
  if (query === "") return items.slice();
  const folded = foldQuery(query);
  const scored = [];
  for (const it of items) {
    const t = textOf(it);
    const s = score(t, folded);
    if (s != null) scored.push({ it, s, t });
  }
  scored.sort((a, b) => b.s - a.s || a.t.length - b.t.length || (a.t < b.t ? -1 : a.t > b.t ? 1 : 0));
  return scored.map((e) => e.it);
}
