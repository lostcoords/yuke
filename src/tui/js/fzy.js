// yuke:fzy — the fzy fuzzy matcher that ranks picker candidates.

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

// Rank `items` by fuzzy score and drop non-matches; ties break by shorter text, then lexicographically.
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
