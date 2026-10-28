/**
 * `fuzzyMatch` of `yuke:tui`: the fzy score of a query as a subsequence of a text, with the ranges of the best
 * alignment. Consecutive letters and the starts of words score higher. The match ignores case, and each range covers
 * whole graphemes of the text.
 */
import { graphemes } from "yuke:internal/tui/text";
import type { FuzzyMatch, OffsetRange } from "yuke:tui";

const GAP_LEADING = -0.005;
const GAP_TRAILING = -0.005;
const GAP_INNER = -0.01;
const MATCH_CONSECUTIVE = 1.0;
const MATCH_SLASH = 0.9;
const MATCH_WORD = 0.8;
const MATCH_CAPITAL = 0.7;
const MATCH_DOT = 0.6;
/** A text with more points than this matches with the first points that fit, and gets the lowest score. */
const ALIGN_LIMIT = 1024;
const WORD = /[\p{L}\p{N}]/u;
const SURROGATE = /[\uD800-\uDFFF]/;
/** Printable ASCII: each character is one grapheme. */
const PRINTABLE = /^[\x20-\x7e]*$/;

/** A matched point of the text: its UTF-16 offset and length. */
interface Span {
  readonly at: number;
  readonly length: number;
}

// The tables of the last alignments stay for the next one, so a keystroke over a long list allocates little.
let textKeys = new Int32Array(0);
let queryKeys = new Int32Array(0);
let bonus = new Float64Array(0);
let ending = new Float64Array(0);
let best = new Float64Array(0);

export function fuzzyMatch(query: string, text: string): FuzzyMatch | undefined {
  if (typeof query !== "string" || typeof text !== "string") throw new TypeError("a fuzzy match takes two strings");
  if (query === "") return { score: 0, ranges: [] };
  // Without surrogates and with a lower case of the same length, each UTF-16 unit is one point.
  if (!SURROGATE.test(query) && !SURROGATE.test(text)) {
    const lowerQuery = query.toLowerCase();
    const lowerText = text.toLowerCase();
    if (lowerQuery.length === query.length && lowerText.length === text.length) {
      return matchUnits(lowerQuery, text, lowerText);
    }
  }
  return matchPoints(query, text);
}

/** The match over UTF-16 units, with the lower case texts. */
function matchUnits(lowerQuery: string, text: string, lowerText: string): FuzzyMatch | undefined {
  const m = lowerQuery.length;
  const n = text.length;
  const greedy: number[] = [];
  // The first pass finds whether the query is a subsequence, so a miss fills no table.
  let at = -1;
  for (let j = 0; j < m; j += 1) {
    at = lowerText.indexOf(lowerQuery[j] as string, at + 1);
    if (at < 0) return undefined;
    greedy.push(at);
  }
  const spans = (positions: readonly number[]): Span[] => positions.map((position) => ({ at: position, length: 1 }));
  if (n > ALIGN_LIMIT) return { score: Number.NEGATIVE_INFINITY, ranges: rangesOf(text, spans(greedy)) };
  if (n === m) return { score: Number.POSITIVE_INFINITY, ranges: rangesOf(text, spans(greedy)) };
  reserve(n, m);
  for (let j = 0; j < m; j += 1) queryKeys[j] = lowerQuery.charCodeAt(j);
  for (let i = 0; i < n; i += 1) textKeys[i] = lowerText.charCodeAt(i);
  const [score, positions] = align(n, m, (i) => bonusOf(i === 0 ? 0x2f : text.charCodeAt(i - 1), text.charCodeAt(i)));
  return { score, ranges: rangesOf(text, spans(positions)) };
}

/** The match over code points, for a text with surrogates or with a lower case of another length. */
function matchPoints(query: string, text: string): FuzzyMatch | undefined {
  const wanted = Array.from(query, (character) => character.toLowerCase());
  const points: (Span & { readonly code: number; readonly folded: string })[] = [];
  for (let at = 0; at < text.length; ) {
    const code = text.codePointAt(at) as number;
    const length = code > 0xff_ff ? 2 : 1;
    points.push({ at, length, code, folded: String.fromCodePoint(code).toLowerCase() });
    at += length;
  }
  const greedy: number[] = [];
  for (let at = 0; at < points.length && greedy.length < wanted.length; at += 1) {
    if (points[at]?.folded === wanted[greedy.length]) greedy.push(at);
  }
  if (greedy.length < wanted.length) return undefined;
  const spans = (positions: readonly number[]): Span[] => positions.map((position) => points[position] as Span);
  const n = points.length;
  const m = wanted.length;
  if (n > ALIGN_LIMIT) return { score: Number.NEGATIVE_INFINITY, ranges: rangesOf(text, spans(greedy)) };
  if (n === m) return { score: Number.POSITIVE_INFINITY, ranges: rangesOf(text, spans(greedy)) };
  // A number for each folded form, so the alignment compares numbers.
  const ids = new Map<string, number>();
  const id = (folded: string): number => {
    let found = ids.get(folded);
    if (found === undefined) {
      found = ids.size;
      ids.set(folded, found);
    }
    return found;
  };
  reserve(n, m);
  for (const [i, point] of points.entries()) textKeys[i] = id(point.folded);
  for (const [j, folded] of wanted.entries()) queryKeys[j] = id(folded);
  const [score, positions] = align(n, m, (i) =>
    bonusOf(i === 0 ? 0x2f : (points[i - 1]?.code as number), (points[i] as { code: number }).code),
  );
  return { score, ranges: rangesOf(text, spans(positions)) };
}

/** Grow the tables to hold a text of `n` points and a query of `m` points. */
function reserve(n: number, m: number): void {
  if (textKeys.length < n) {
    textKeys = new Int32Array(n);
    bonus = new Float64Array(n);
  }
  if (queryKeys.length < m) queryKeys = new Int32Array(m);
  if (ending.length < n * m) {
    ending = new Float64Array(n * m);
    best = new Float64Array(n * m);
  }
}

/** The bonus of a match at `code` after `previous`: a word after a separator, or a capital after a lower letter. */
function bonusOf(previous: number, code: number): number {
  if (previous < 0x80 && code < 0x80) {
    if (previous >= 0x61 && previous <= 0x7a && code >= 0x41 && code <= 0x5a) return MATCH_CAPITAL;
    const word = (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
    return word ? separatorBonus(previous) : 0;
  }
  const before = String.fromCodePoint(previous);
  const current = String.fromCodePoint(code);
  if (before !== before.toUpperCase() && current !== current.toLowerCase()) return MATCH_CAPITAL;
  return WORD.test(current) ? separatorBonus(previous) : 0;
}

function separatorBonus(previous: number): number {
  if (previous === 0x2f) return MATCH_SLASH;
  if (previous === 0x2d || previous === 0x5f || previous === 0x20) return MATCH_WORD;
  if (previous === 0x2e) return MATCH_DOT;
  return 0;
}

/**
 * The fzy alignment of the query keys over the text keys: the best score, and the point of each query letter.
 * `ending[j][i]` is the best score that ends with letter `j` at point `i`. `best[j][i]` is the best score of the first
 * `j + 1` letters up to point `i`. `bonusAt` runs only at a point where a letter matches, once for each point.
 */
function align(n: number, m: number, bonusAt: (i: number) => number): [number, number[]] {
  bonus.fill(Number.NaN, 0, n);
  const bonusOfPoint = (i: number): number => {
    let found = bonus[i] as number;
    if (Number.isNaN(found)) {
      found = bonusAt(i);
      bonus[i] = found;
    }
    return found;
  };
  for (let j = 0; j < m; j += 1) {
    const gap = j === m - 1 ? GAP_TRAILING : GAP_INNER;
    const key = queryKeys[j];
    let running = Number.NEGATIVE_INFINITY;
    for (let i = 0; i < n; i += 1) {
      let score = Number.NEGATIVE_INFINITY;
      if (textKeys[i] === key) {
        if (j === 0) score = i * GAP_LEADING + bonusOfPoint(i);
        else if (i > 0) {
          score = Math.max(
            (best[(j - 1) * n + i - 1] as number) + bonusOfPoint(i),
            (ending[(j - 1) * n + i - 1] as number) + MATCH_CONSECUTIVE,
          );
        }
        running = Math.max(score, running + gap);
      } else running += gap;
      ending[j * n + i] = score;
      best[j * n + i] = running;
    }
  }
  // Walk back from the end: each letter takes the last point where its best score ends with a match.
  const positions = new Array<number>(m);
  let consecutive = false;
  let i = n - 1;
  for (let j = m - 1; j >= 0; j -= 1) {
    for (; i >= 0; i -= 1) {
      const end = ending[j * n + i] as number;
      if (end !== Number.NEGATIVE_INFINITY && (consecutive || end === best[j * n + i])) {
        consecutive = j > 0 && i > 0 && end === (ending[(j - 1) * n + i - 1] as number) + MATCH_CONSECUTIVE;
        positions[j] = i;
        i -= 1;
        break;
      }
    }
  }
  return [best[(m - 1) * n + n - 1] as number, positions];
}

/** The UTF-16 ranges of `spans`, grown to whole graphemes and joined when they touch or overlap. */
function rangesOf(text: string, spans: readonly Span[]): OffsetRange[] {
  const triples = PRINTABLE.test(text) ? undefined : graphemes(text);
  const ranges: OffsetRange[] = [];
  let grapheme = 0;
  for (const span of spans) {
    let from = span.at;
    let to = span.at + span.length;
    if (triples !== undefined) {
      while (grapheme + 3 < triples.length && (triples[grapheme + 3] as number) <= span.at) grapheme += 3;
      from = triples[grapheme] as number;
      to = from + (triples[grapheme + 1] as number);
    }
    const last = ranges.at(-1);
    if (last !== undefined && last.to >= from)
      ranges[ranges.length - 1] = { from: last.from, to: Math.max(last.to, to) };
    else ranges.push({ from, to });
  }
  return ranges;
}
