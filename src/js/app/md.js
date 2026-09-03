import { term } from "yuke:term";
import { style } from "yuke:core";

/** @typedef {{at: number, src: number, len: number}} SourceRun */
/** @typedef {string[] & {[index: number]: string}} StringList */
/** @typedef {number[] & {[index: number]: number}} NumberList */
/** @typedef {[full: string, indent: string, fence: string, lang: string]} FenceMatch */
/** @typedef {[full: string, indent: string, fence: string]} FenceCloseMatch */
/** @typedef {[full: string, indent: string, marks: string, spacing: string | undefined, text: string | undefined]} HeadingMatch */
/** @typedef {[full: string, indent: string, spacing: string, text: string]} QuoteMatch */
/** @typedef {[full: string, indent: string, marker: string, spacing: string, text: string]} UlItemMatch */
/** @typedef {[full: string, indent: string, number: string, delimiter: string, spacing: string, text: string]} OlItemMatch */
/** @typedef {{text: string, runs: SourceRun[]}} InlineSource */
/** @typedef {{text: string, runs: SourceRun[]}} TableCell */
/** @typedef {{marker: string, length: number, indent: number, lang: string}} Fence */
/** @typedef {{indent: number, marker: string, text: string, runs: SourceRun[], markAt: number, markEnd: number}} ListItem */
/** @typedef {{raw: string, at: number, end: number, open?: boolean}} BlockMeta */
/** @typedef {BlockMeta & {kind: "code", lang: string, lines: StringList, lineAt: NumberList, closed: boolean}} CodeBlock */
/** @typedef {BlockMeta & {kind: "heading", level: number, text: string, runs: SourceRun[]}} HeadingBlock */
/** @typedef {BlockMeta & {kind: "quote", text: string, runs: SourceRun[], markAt: number, markEnd: number}} QuoteBlock */
/** @typedef {BlockMeta & {kind: "list", ordered: boolean, items: ListItem[]}} ListBlock */
/** @typedef {BlockMeta & {kind: "table", columns: number, rows: TableCell[][], sepAt: number, sepEnd: number}} TableBlock */
/** @typedef {BlockMeta & {kind: "paragraph", text: string, runs: SourceRun[]}} ParagraphBlock */
/** @typedef {BlockMeta & {kind: "hr"}} RuleBlock */
/** @typedef {CodeBlock | HeadingBlock | QuoteBlock | ListBlock | TableBlock | ParagraphBlock | RuleBlock} Block */
/** @typedef {{kind: Block["kind"], at: number, end: number}} BlockSummary */
/** @typedef {{kind: "text", text: string, at: number, len: number}} TextNode */
/** @typedef {{kind: "seg", text: string, group: string, at: number, len: number}} StyledNode */
/** @typedef {{kind: "delim", text: string, at: number, len: number, marker: string, count: number, canOpen: boolean, canClose: boolean, openStrong?: number, closeStrong?: number, openEm?: number, closeEm?: number}} DelimiterNode */
/** @typedef {TextNode | StyledNode | DelimiterNode} InlineNode */
/** @typedef {{text: string, group: string, at: number, len: number}} InlinePiece */
/** @typedef {{text: string, group: string, src?: number, srcEnd?: number, mark?: boolean}} Segment */
/** @typedef {{src: number, srcEnd: number, text: string, group: string}} LinearSegment */
/** @typedef {{segments: Segment[]}} Row */
/** @typedef {{segments: Segment[], w: number}} BreakPiece */
/** @typedef {{pieces: Segment[], w: number, spaceGroup: string | null}} Word */
/** @typedef {{firstPrefix?: Segment, contPrefix?: Segment, emptyGroup?: string}} WrapOptions */
/** @typedef {{raw: string, width: number | null, rows: Row[] | null}} CacheEntry */

// Register the Markdown groups once.
style.add({
  MdText: { link: "Normal" },
  MdStrong: { fg: "fg", bold: true },
  MdEm: { fg: "fg", italic: true },
  MdStrongEm: { fg: "fg", bold: true, italic: true },
  MdCode: { fg: "fg", dim: true },
  MdHeading: { fg: "fg", bold: true },
  MdQuote: { fg: "fg", dim: true },
  MdCodeBlock: { fg: "fg", dim: true },
  MdRule: { fg: "fg", dim: true },
  MdListMark: { fg: "fg", dim: true },
  MdTableBorder: { fg: "fg", dim: true },
});

const FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const FENCE_CLOSE = /^( {0,3})(`{3,}|~{3,})[ \t]*$/;
const HEADING = /^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?[ \t]*$/;
const HR = /^( {0,3})(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/;
const QUOTE = /^( {0,3})>([ \t]?)(.*)$/;
const UL_ITEM = /^( {0,3})([-*+])([ \t]+)(.*)$/;
const OL_ITEM = /^( {0,3})(\d{1,9})([.)])([ \t]+)(.*)$/;
const SETEXT = /^( {0,3})(=+|-+)[ \t]*$/;

/** @param {string} line @returns {Fence | null} */
function fenceOpen(line) {
  const m = /** @type {FenceMatch | null} */ (FENCE.exec(line));
  if (!m) return null;
  const marker = /** @type {string} */ (m[2][0]);
  if (marker === "`" && m[3].indexOf("`") >= 0) return null;
  return { marker, length: m[2].length, indent: m[1].length, lang: m[3].trim() };
}

/** @param {string} line @param {string} marker @param {number} length @returns {boolean | null} */
function fenceClose(line, marker, length) {
  const m = /** @type {FenceCloseMatch | null} */ (FENCE_CLOSE.exec(line));
  return m && m[2][0] === marker && m[2].length >= length;
}

/** @param {string} line @returns {Fence | boolean} */
function isBlockStart(line) {
  return fenceOpen(line) || HEADING.test(line) || HR.test(line) || QUOTE.test(line) || UL_ITEM.test(line) || OL_ITEM.test(line);
}

/** @param {string} line @returns {boolean} */
function isTableSeparator(line) {
  const cells = splitTableRow(line, 0);
  return cells.length > 0 && cells.every((cell) => /^:?-{1,}:?$/.test(cell.text));
}

/** @param {string} line @returns {boolean} */
function hasUnescapedPipe(line) {
  for (let i = 0; i < line.length; i++) if (line[i] === "|" && !isEscaped(line, i)) return true;
  return false;
}

/** @param {StringList} lines @param {number} i @returns {boolean} */
function isSetextHeading(lines, i) {
  return i + 1 < lines.length && /** @type {string} */ (lines[i]).trim() !== "" && !isBlockStart(/** @type {string} */ (lines[i])) && SETEXT.test(/** @type {string} */ (lines[i + 1]));
}

/** @param {string} line @param {number} indent @returns {string} */
function stripFenceIndent(line, indent) {
  let count = 0;
  while (count < indent && line[count] === " ") count++;
  return line.slice(count);
}

// Inline text plus where each part comes from. A run maps text [at, at+len) to source [src, src+len).
/** @returns {InlineSource} */
function inlineSource() {
  return { text: "", runs: [] };
}

/** @param {InlineSource} s @param {string} text @param {number} src @returns {void} */
function addSource(s, text, src) {
  if (!text) return;
  const last = s.runs[s.runs.length - 1];
  if (last && last.src + last.len === src) last.len += text.length;
  else s.runs.push({ at: s.text.length, src, len: text.length });
  s.text += text;
}

// One run, for text that comes from a single contiguous source range.
/** @param {string} text @param {number} src @returns {SourceRun[]} */
function oneRun(text, src) {
  return text.length ? [{ at: 0, src, len: text.length }] : [];
}

// The run that holds inline index `i`. The runs cover the whole inline text in order.
/** @param {SourceRun[]} runs @param {number} i @returns {SourceRun} */
function runFor(runs, i) {
  for (let k = runs.length - 1; k > 0; k--) {
    const run = /** @type {SourceRun} */ (runs[k]);
    if (i >= run.at) return run;
  }
  return /** @type {SourceRun} */ (runs[0]);
}

// The source offset of inline index `i`. `end` gives the offset after that character.
/** @param {SourceRun[]} runs @param {number} i @param {boolean} end @returns {number} */
function srcAt(runs, i, end) {
  const r = runFor(runs, i);
  const o = r.src + Math.min(Math.max(0, i - r.at), r.len - 1);
  return end ? o + 1 : o;
}

// Split the text into blocks with `at`/`end` source offsets and `raw` for the cache; only the tail block still changes.
/** @param {string} text @returns {Block[]} */
function segment(text) {
  const lines = /** @type {StringList} */ (text.split("\n"));
  const starts = /** @type {NumberList} */ (new Array(lines.length + 1));
  {
    let off = 0;
    for (let k = 0; k < lines.length; k++) {
      starts[k] = off;
      const sourceLine = /** @type {string} */ (lines[k]);
      off += sourceLine.length + 1;
    }
    starts[lines.length] = /** @type {number} */ (off);
  }
  const blocks = /** @type {Block[]} */ ([]);
  let i = 0;

  /** @param {Block} b @param {number} from @param {number} to @returns {void} */
  const push = (b, from, to) => {
    b.raw = lines.slice(from, to).join("\n");
    b.at = /** @type {number} */ (starts[from]);
    b.end = /** @type {number} */ (starts[to]) - 1;
    blocks.push(b);
  };

  while (i < lines.length) {
    const line = /** @type {string} */ (lines[i]);

    if (line.trim() === "") {
      i++;
      continue;
    }

    const fence = fenceOpen(line);
    if (fence) {
      const marker = fence.marker;
      const body = /** @type {StringList} */ (/** @type {unknown} */ ([]));
      const bodyAt = /** @type {NumberList} */ (/** @type {unknown} */ ([]));
      let j = i + 1;
      let closed = false;
      for (; j < lines.length; j++) {
        const sourceLine = /** @type {string} */ (lines[j]);
        if (fenceClose(sourceLine, marker, fence.length)) {
          closed = true;
          break;
        }
        const sourceAt = /** @type {number} */ (starts[j]);
        const stripped = stripFenceIndent(sourceLine, fence.indent);
        body.push(stripped);
        bodyAt.push(sourceAt + sourceLine.length - stripped.length);
      }
      const to = closed ? j + 1 : lines.length;
      push(/** @type {CodeBlock} */ ({ kind: "code", lang: fence.lang, lines: body, lineAt: bodyAt, closed }), i, to);
      i = to;
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      const m = /** @type {HeadingMatch} */ (/** @type {unknown} */ (heading));
      const headingText = (m[4] || "").replace(/[ \t]+#+[ \t]*$/, "").trim();
      const src = /** @type {number} */ (starts[i]) + m[1].length + m[2].length + (m[3] ? m[3].length : 0);
      push(/** @type {HeadingBlock} */ ({ kind: "heading", level: m[2].length, text: headingText, runs: oneRun(headingText, src) }), i, i + 1);
      i++;
      continue;
    }

    if (isSetextHeading(lines, i)) {
      const headingText = line.trim();
      const src = /** @type {number} */ (starts[i]) + line.length - line.trimStart().length;
      const nextLine = /** @type {string} */ (lines[i + 1]);
      const level = nextLine.trimStart()[0] === "=" ? 1 : 2;
      push(/** @type {HeadingBlock} */ ({ kind: "heading", level, text: headingText, runs: oneRun(headingText, src) }), i, i + 2);
      i += 2;
      continue;
    }

    if (HR.test(line)) {
      push(/** @type {RuleBlock} */ ({ kind: "hr" }), i, i + 1);
      i++;
      continue;
    }

    if (QUOTE.test(line)) {
      let j = i;
      const body = inlineSource();
      let markEnd = /** @type {number} */ (starts[i]);
      for (; j < lines.length && QUOTE.test(/** @type {string} */ (lines[j])); j++) {
        const sourceLine = /** @type {string} */ (lines[j]);
        const m = /** @type {QuoteMatch} */ (/** @type {unknown} */ (QUOTE.exec(sourceLine)));
        const src = /** @type {number} */ (starts[j]) + m[1].length + 1 + m[2].length;
        if (j === i) markEnd = src;
        else addSource(body, "\n", /** @type {number} */ (starts[j]) - 1);
        addSource(body, m[3], src);
      }
      push(/** @type {QuoteBlock} */ ({ kind: "quote", text: body.text, runs: body.runs, markAt: /** @type {number} */ (starts[i]), markEnd }), i, j);
      i = j;
      continue;
    }

    if (UL_ITEM.test(line) || OL_ITEM.test(line)) {
      let j = i;
      const items = /** @type {ListItem[]} */ ([]);
      let ordered = !!OL_ITEM.exec(line);
      for (; j < lines.length; j++) {
        const sourceLine = /** @type {string} */ (lines[j]);
        const m = /** @type {OlItemMatch | UlItemMatch | null} */ (ordered ? OL_ITEM.exec(sourceLine) : UL_ITEM.exec(sourceLine));
        if (!m) break;
        // The last group runs to the end of the line, so its offset needs no group arithmetic.
        const body = /** @type {string} */ (m[m.length - 1]);
        const src = /** @type {number} */ (starts[j]) + sourceLine.length - body.length;
        items.push({
          indent: Math.floor(/** @type {string} */ (m[1]).length / 2),
          marker: ordered ? /** @type {string} */ (m[2]) + "." : "•",
          text: body,
          runs: oneRun(body, src),
          markAt: /** @type {number} */ (starts[j]),
          markEnd: src,
        });
      }
      push(/** @type {ListBlock} */ ({ kind: "list", ordered, items }), i, j);
      i = j;
      continue;
    }

    const headerCells = hasUnescapedPipe(line) ? splitTableRow(line, /** @type {number} */ (starts[i])) : [];
    const nextLine = i + 1 < lines.length ? /** @type {string} */ (lines[i + 1]) : "";
    const separatorAt = i + 1 < lines.length ? /** @type {number} */ (starts[i + 1]) : 0;
    const separatorCells = i + 1 < lines.length && isTableSeparator(nextLine) ? splitTableRow(nextLine, separatorAt) : [];
    if (headerCells.length > 0 && headerCells.length === separatorCells.length) {
      let j = i + 2;
      for (; j < lines.length && /** @type {string} */ (lines[j]).trim() !== "" && !isBlockStart(/** @type {string} */ (lines[j])); j++);
      const rows = /** @type {TableCell[][]} */ ([]);
      for (let k = i; k < j; k++) {
        if (k === i + 1) continue;
        rows.push(splitTableRow(/** @type {string} */ (lines[k]), /** @type {number} */ (starts[k])));
      }
      const sepAt = /** @type {number} */ (starts[i + 1]);
      push(/** @type {TableBlock} */ ({ kind: "table", columns: headerCells.length, rows, sepAt, sepEnd: sepAt + /** @type {string} */ (lines[i + 1]).length }), i, j);
      i = j;
      continue;
    }

    // Consume a paragraph until a blank line or a new block; a line feed joins as one space and keeps the source length.
    let j = i;
    const body = inlineSource();
    for (; j < lines.length; j++) {
      const l = /** @type {string} */ (lines[j]);
      if (l.trim() === "") break;
      if (isBlockStart(l) || isSetextHeading(lines, j)) break;
      if (j > i) addSource(body, " ", /** @type {number} */ (starts[j]) - 1);
      addSource(body, l, /** @type {number} */ (starts[j]));
    }
    push(/** @type {ParagraphBlock} */ ({ kind: "paragraph", text: body.text, runs: body.runs }), i, j);
    i = j;
  }

  // The last block may still grow as a stream appends text, so never cache it.
  if (blocks.length) /** @type {Block} */ (blocks[blocks.length - 1]).open = true;
  return blocks;
}

// Split a table row into cells. `base` is the source offset of the line, so a cell keeps its runs.
/** @param {string} line @param {number} base @returns {TableCell[]} */
function splitTableRow(line, base) {
  let start = line.length - line.trimStart().length;
  let stop = start + line.trim().length;
  if (line[start] === "|") start++;
  if (stop > start && line[stop - 1] === "|" && !isEscaped(line, stop - 1)) stop--;
  const cells = [];
  let from = start;
  for (let i = start; i <= stop; i++) {
    if (i === stop || (line[i] === "|" && !isEscaped(line, i))) {
      cells.push(tableCell(line, from, i, base || 0));
      from = i + 1;
    }
  }
  return cells;
}

// One cell: trim the edges. An escaped pipe stays in the text, so `parseInline` resolves it.
/** @param {string} line @param {number} from @param {number} to @param {number} base @returns {TableCell} */
function tableCell(line, from, to, base) {
  while (from < to && (line[from] === " " || line[from] === "\t")) from++;
  while (to > from && (line[to - 1] === " " || line[to - 1] === "\t")) to--;
  const text = line.slice(from, to);
  return { text, runs: oneRun(text, base + from) };
}

/** @param {string} text @param {number} index @returns {boolean} */
function isEscaped(text, index) {
  let slashes = 0;
  for (let i = index - 1; i >= 0 && text[i] === "\\"; i--) slashes++;
  return slashes % 2 === 1;
}

const ESCAPABLE = "\\`*{}[]()#+-.!_>~|";

/** @param {string | undefined} c @returns {boolean} */
function isSpace(c) {
  return c === undefined || /\s/u.test(c);
}

/** @param {string | undefined} c @returns {boolean} */
function isPunctuation(c) {
  return c !== undefined && /[\p{P}\p{S}]/u.test(c);
}

// The emphasis group for a bold and italic depth.
/** @param {boolean} bold @param {boolean} italic @returns {string | null} */
function emphGroup(bold, italic) {
  if (bold && italic) return "MdStrongEm";
  if (bold) return "MdStrong";
  if (italic) return "MdEm";
  return null;
}

// Flanking: a delimiter run opens or closes emphasis by the chars around it (CommonMark rules).
/** @param {StringList} cps @param {number} i @param {string} marker @returns {{count: number, canOpen: boolean, canClose: boolean}} */
function scanDelims(cps, i, marker) {
  let count = 0;
  while (cps[i + count] === marker) count++;
  const before = i === 0 ? " " : cps[i - 1];
  const after = cps[i + count] === undefined ? " " : cps[i + count];
  const beforeWs = isSpace(before);
  const afterWs = isSpace(after);
  const beforeP = isPunctuation(before);
  const afterP = isPunctuation(after);
  const leftFlank = !afterWs && (!afterP || beforeWs || beforeP);
  const rightFlank = !beforeWs && (!beforeP || afterWs || afterP);
  let canOpen = leftFlank;
  let canClose = rightFlank;
  if (marker === "_") {
    canOpen = leftFlank && (!rightFlank || beforeP);
    canClose = rightFlank && (!leftFlank || afterP);
  }
  return { count, canOpen, canClose };
}

// Find the closing backtick run of exactly `n`, so an inner shorter run stays literal.
/** @param {StringList} cps @param {number} start @param {number} n @returns {number} */
function closeCodeSpan(cps, start, n) {
  let j = start;
  while (j < cps.length) {
    if (cps[j] !== "`") {
      j++;
      continue;
    }
    let m = 0;
    while (cps[j + m] === "`") m++;
    if (m === n) return j;
    j += m;
  }
  return -1;
}

// Read a `[label](dest)` link and return the label and end index, or null; a destination holds no space.
/** @param {StringList} cps @param {number} open @returns {{label: string, end: number} | null} */
function scanLink(cps, open) {
  let depth = 0;
  let close = -1;
  for (let j = open + 1; j < cps.length; j++) {
    const c = cps[j];
    if (c === "\\") {
      j++;
      continue;
    }
    if (c === "[") depth++;
    else if (c === "]") {
      if (depth === 0) {
        close = j;
        break;
      }
      depth--;
    }
  }
  if (close < 0 || cps[close + 1] !== "(") return null;
  let paren = 1;
  let end = -1;
  for (let j = close + 2; j < cps.length; j++) {
    const c = cps[j];
    if (c === "\\") {
      j++;
      continue;
    }
    if (isSpace(c)) return null;
    if (c === "(") paren++;
    else if (c === ")") {
      paren--;
      if (paren === 0) {
        end = j;
        break;
      }
    }
  }
  if (end < 0) return null;
  return { label: cps.slice(open + 1, close).join(""), end };
}

// Parse inline text into styled segments: code spans and links resolve first, then a delimiter stack folds emphasis.
/** @param {string} text @param {string} [baseGroup] @returns {InlinePiece[]} */
function parseInline(text, baseGroup) {
  const base = baseGroup || "MdText";
  const cps = /** @type {StringList} */ (Array.from(text));
  // The parser walks code points, but a segment range is UTF-16, so keep both indexes.
  const units = /** @type {NumberList} */ (new Array(cps.length + 1));
  {
    let u = 0;
    for (let k = 0; k < cps.length; k++) {
      units[k] = u;
      u += /** @type {string} */ (cps[k]).length;
    }
    units[cps.length] = u;
  }
  const nodes = /** @type {InlineNode[]} */ ([]); // { kind, text, at, len, … }; at and len are the UTF-16 range of the source
  const delims = /** @type {number[]} */ ([]); // indices into nodes of open/close delimiter runs

  let i = 0;
  while (i < cps.length) {
    const c = cps[i];
    if (c === "\\" && i + 1 < cps.length && ESCAPABLE.indexOf(/** @type {string} */ (cps[i + 1])) >= 0) {
      nodes.push({ kind: "text", text: /** @type {string} */ (cps[i + 1]), at: /** @type {number} */ (units[i]), len: /** @type {number} */ (units[i + 2]) - /** @type {number} */ (units[i]) });
      i += 2;
      continue;
    }
    if (c === "`") {
      let n = 1;
      while (cps[i + n] === "`") n++;
      const close = closeCodeSpan(cps, i + n, n);
      if (close >= 0) {
        let from = i + n;
        let to = close;
        let code = cps.slice(from, to).join("").replace(/[\r\n]/g, " ");
        if (code.length > 2 && code[0] === " " && code[code.length - 1] === " " && /[^ ]/.test(code)) {
          code = code.slice(1, -1);
          from++;
          to--;
        }
        nodes.push({ kind: "seg", text: code, group: "MdCode", at: /** @type {number} */ (units[from]), len: /** @type {number} */ (units[to]) - /** @type {number} */ (units[from]) });
        i = close + n;
        continue;
      }
      nodes.push({ kind: "text", text: "`".repeat(n), at: /** @type {number} */ (units[i]), len: /** @type {number} */ (units[i + n]) - /** @type {number} */ (units[i]) });
      i += n;
      continue;
    }
    if (c === "[") {
      const link = scanLink(cps, i);
      if (link) {
        // The label is a verbatim slice of the parent, so a sub-range shifts by the label offset.
        const shift = /** @type {number} */ (units[i + 1]);
        for (const s of parseInline(link.label, base)) {
          if (!s.text) continue;
          const styled = s.group !== base;
          nodes.push({ kind: styled ? "seg" : "text", text: s.text, group: s.group, at: shift + s.at, len: s.len });
        }
        i = link.end + 1;
        continue;
      }
    }
    if (c === "*" || c === "_") {
      const d = scanDelims(cps, i, c);
      nodes.push({
        kind: "delim",
        text: c.repeat(d.count),
        at: /** @type {number} */ (units[i]),
        len: /** @type {number} */ (units[i + d.count]) - /** @type {number} */ (units[i]),
        marker: c,
        count: d.count,
        canOpen: d.canOpen,
        canClose: d.canClose,
      });
      delims.push(nodes.length - 1);
      i += d.count;
      continue;
    }
    nodes.push({ kind: "text", text: /** @type {string} */ (c), at: /** @type {number} */ (units[i]), len: /** @type {string} */ (c).length });
    i++;
  }

  foldEmphasis(nodes, delims);
  return flattenInline(nodes, base);
}

// The delimiter stack: each closer matches the nearest compatible opener, and an unused delimiter stays literal.
/** @param {InlineNode[]} nodes @param {number[]} delims @returns {void} */
function foldEmphasis(nodes, delims) {
  for (let ci = 0; ci < delims.length; ci++) {
    const closer = /** @type {DelimiterNode} */ (nodes[/** @type {number} */ (delims[ci])]);
    if (closer.kind !== "delim" || !closer.canClose) continue;
    while (closer.count > 0) {
      let matched = false;
      for (let oi = ci - 1; oi >= 0; oi--) {
        const opener = /** @type {DelimiterNode} */ (nodes[/** @type {number} */ (delims[oi])]);
        if (opener.kind !== "delim" || opener.marker !== closer.marker || !opener.canOpen || opener.count === 0) continue;
        // The rule of three: an open-and-close run matches only when the lengths allow it.
        const oddMatch = (closer.canOpen || opener.canClose) && (opener.count + closer.count) % 3 === 0 && !(opener.count % 3 === 0 && closer.count % 3 === 0);
        if (oddMatch) continue;
        const use = opener.count >= 2 && closer.count >= 2 ? 2 : 1;
        opener.count -= use;
        closer.count -= use;
        closer.at += use;
        if (use === 2) {
          opener.openStrong = (opener.openStrong || 0) + 1;
          closer.closeStrong = (closer.closeStrong || 0) + 1;
        } else {
          opener.openEm = (opener.openEm || 0) + 1;
          closer.closeEm = (closer.closeEm || 0) + 1;
        }
        matched = true;
        break;
      }
      if (!matched) break;
    }
  }
}

// Walk the folded nodes and emit segments; text merges only while the source stays contiguous.
/** @param {InlineNode[]} nodes @param {string} base @returns {InlinePiece[]} */
function flattenInline(nodes, base) {
  const out = /** @type {InlinePiece[]} */ ([]);
  let bold = 0;
  let italic = 0;
  /** @param {string} text @param {string} group @param {number} at @param {number} len @returns {void} */
  const emit = (text, group, at, len) => {
    if (!text) return;
    const last = out[out.length - 1];
    const joins = last && last.group === group && last.at + last.len === at && last.len === last.text.length && len === text.length;
    if (joins) {
      last.text += text;
      last.len += len;
    } else out.push({ text, group, at, len });
  };
  for (const n of nodes) {
    if (n.kind === "seg") {
      emit(n.text, n.group, n.at, n.len);
      continue;
    }
    if (n.kind === "delim") {
      bold -= n.closeStrong || 0;
      italic -= n.closeEm || 0;
      if (n.count > 0) emit(n.marker.repeat(n.count), emphGroup(bold > 0, italic > 0) || base, n.at, n.count);
      bold += n.openStrong || 0;
      italic += n.openEm || 0;
      continue;
    }
    emit(n.text, emphGroup(bold > 0, italic > 0) || base, n.at, n.len);
  }
  return out.length ? out : [{ text: "", group: base, at: 0, len: 0 }];
}

// Map inline segments onto source offsets, so every piece stays linear (`srcEnd - src === text.length`) unless the markup is not.
/** @param {InlinePiece[]} segments @param {SourceRun[]} runs @returns {Segment[]} */
function resolveSegments(segments, runs) {
  if (!runs || runs.length === 0) return segments.map((s) => ({ text: s.text, group: s.group }));
  const out = /** @type {Segment[]} */ ([]);
  for (const s of segments) {
    if (s.text.length === 0) {
      out.push({ text: "", group: s.group });
      continue;
    }
    if (s.len !== s.text.length) {
      out.push({ text: s.text, group: s.group, src: srcAt(runs, s.at, false), srcEnd: srcAt(runs, s.at + s.len - 1, true) });
      continue;
    }
    let k = 0;
    while (k < s.text.length) {
      const r = runFor(runs, s.at + k);
      const take = Math.min(s.text.length - k, Math.max(1, r.at + r.len - (s.at + k)));
      const src = r.src + (s.at + k - r.at);
      out.push({ text: s.text.slice(k, k + take), group: s.group, src, srcEnd: src + take });
      k += take;
    }
  }
  return out;
}

// One source character per rendered character, so an offset survives a slice; a mark and an escape are not linear.
/** @param {Segment} seg @returns {seg is LinearSegment} */
export function isLinear(seg) {
  return seg.src != null && !seg.mark && /** @type {number} */ (seg.srcEnd) - seg.src === seg.text.length;
}

// Slice a resolved segment; one that is not linear keeps its whole source span, and only an escape reaches a wrap.
/** @param {Segment} seg @param {number} from @param {number} to @returns {Segment} */
function sliceSegment(seg, from, to) {
  const out = /** @type {Segment} */ ({ text: seg.text.slice(from, to), group: seg.group });
  if (seg.src == null) return out;
  if (!isLinear(seg)) {
    out.src = seg.src;
    out.srcEnd = /** @type {number} */ (seg.srcEnd);
    if (seg.mark) out.mark = true;
    return out;
  }
  out.src = seg.src + from;
  out.srcEnd = seg.src + to;
  return out;
}

// Two neighbours merge only while both their text and their source stay contiguous.
/** @param {Segment} a @param {Segment} b @returns {boolean} */
function segmentsJoin(a, b) {
  if (a.group !== b.group) return false;
  if (a.src == null && b.src == null) return true;
  return a.srcEnd === b.src && isLinear(a) && isLinear(b);
}

/** @param {Segment[]} segments @param {number} width @param {WrapOptions} [opts] @returns {Row[]} */
function wrapSegments(segments, width, opts) {
  const o = opts || {};
  const first = o.firstPrefix || null;
  const cont = o.contPrefix || null;
  /** @param {Segment | null} p @returns {number} */
  const prefixW = (p) => (p ? term.measure(p.text) : 0);
  const firstW = prefixW(first);
  const contW = prefixW(cont);
  const available = () => Math.max(1, width - (rows.length === 0 ? firstW : contW));
  const spaceW = term.measure(" ");

  const words = segmentsToWords(segments);
  const rows = /** @type {Row[]} */ ([]);
  let line = /** @type {Segment[]} */ ([]);
  let lineW = 0;

  const emit = () => {
    const prefix = rows.length === 0 ? first : cont;
    const segs = prefix ? [prefix].concat(line) : line.slice();
    rows.push({ segments: segs.length ? segs : [{ text: "", group: o.emptyGroup || "MdText" }] });
    line = [];
    lineW = 0;
  };

  for (const word of words) {
    if (line.length && lineW + spaceW + word.w > available()) emit();
    if (word.w > available()) {
      if (line.length) emit();
      const broken = hardBreakPieces(word.pieces, available());
      for (let i = 0; i < broken.length; i++) {
        const piece = /** @type {BreakPiece} */ (broken[i]);
        line = piece.segments;
        lineW = piece.w;
        if (i + 1 < broken.length) emit();
      }
      continue;
    }
    if (line.length) {
      line.push({ text: " ", group: word.spaceGroup || "MdText" });
      lineW += spaceW;
    }
    for (const p of word.pieces) line.push(p);
    lineW += word.w;
  }
  emit();
  return rows;
}

// Split the segments at every blank run, keeping the source offsets; `wrapSegments` puts one space back between words.
/** @param {Segment[]} segments @returns {Word[]} */
function segmentsToWords(segments) {
  const words = /** @type {Word[]} */ ([]);
  let cur = /** @type {Word | null} */ (null);
  let spaceGroup = null;
  const close = () => {
    if (cur) words.push(cur);
    cur = null;
  };
  /** @param {string | undefined} c @returns {boolean} */
  const blank = (c) => c === " " || c === "\t" || c === "\n";
  for (const seg of segments) {
    let k = 0;
    while (k <= seg.text.length) {
      let e = k;
      while (e < seg.text.length && !blank(seg.text[e])) e++;
      if (e > k) {
        if (!cur) {
          cur = { pieces: [], w: 0, spaceGroup };
          spaceGroup = null;
        }
        const piece = sliceSegment(seg, k, e);
        cur.pieces.push(piece);
        cur.w += term.measure(piece.text);
      }
      if (e >= seg.text.length) break;
      let ws = e;
      while (ws < seg.text.length && blank(seg.text[ws])) ws++;
      close();
      spaceGroup = seg.group;
      k = ws;
    }
  }
  close();
  return words;
}

/** @param {Segment[]} pieces @param {number} width @returns {BreakPiece[]} */
function hardBreakPieces(pieces, width) {
  const out = /** @type {BreakPiece[]} */ ([]);
  let segments = /** @type {Segment[]} */ ([]);
  let lineW = 0;
  const emit = () => {
    if (segments.length) out.push({ segments, w: lineW });
    segments = [];
    lineW = 0;
  };
  /** @param {Segment} seg @param {number} w @returns {void} */
  const append = (seg, w) => {
    const last = segments[segments.length - 1];
    if (last && segmentsJoin(last, seg)) {
      last.text += seg.text;
      if (last.src != null) last.srcEnd = /** @type {number} */ (seg.srcEnd);
    } else segments.push(seg);
    lineW += w;
  };
  for (const piece of pieces) {
    const gs = term.graphemes(piece.text);
    for (let k = 0; k < gs.length; k += 3) {
      const from = /** @type {number} */ (gs[k]);
      const len = /** @type {number} */ (gs[k + 1]);
      const w = /** @type {number} */ (gs[k + 2]);
      if (segments.length && lineW + w > width) emit();
      append(sliceSegment(piece, from, from + len), w);
      if (lineW >= width) emit();
    }
  }
  emit();
  return out;
}

/** @param {string} text @param {string} [group] @returns {Row} */
function plainRow(text, group) {
  return { segments: [{ text, group: group || "MdText" }] };
}

/** @param {number} width @returns {string} */
function ruleText(width) {
  const glyph = "─";
  const glyphW = term.measure(glyph);
  const count = Math.max(1, Math.floor(Math.max(1, width) / glyphW));
  return glyph.repeat(count);
}

// A rendered segment carries its source span: a `mark` takes the span of the markup it hides, and a separator carries none.
/** @param {Block} block @param {number} width @returns {Row[]} */
function renderBlock(block, width) {
  switch (block.kind) {
    case "heading": {
      const segs = resolveSegments(parseInline(block.text, "MdHeading"), block.runs).map((s) => ({ ...s, group: "MdHeading" }));
      return wrapSegments(segs, width, { emptyGroup: "MdHeading" });
    }
    case "paragraph":
      return wrapSegments(resolveSegments(parseInline(block.text), block.runs), width);
    case "code": {
      const rows = /** @type {Row[]} */ ([]);
      for (let k = 0; k < block.lines.length; k++) {
        const at = /** @type {number} */ (block.lineAt[k]);
        const line = /** @type {Segment} */ ({ text: /** @type {string} */ (block.lines[k]), group: "MdCodeBlock", src: at, srcEnd: at + /** @type {string} */ (block.lines[k]).length });
        const parts = hardBreakPieces([line], width);
        if (parts.length === 0) rows.push(plainRow("", "MdCodeBlock"));
        for (const p of parts) rows.push({ segments: p.segments });
      }
      if (rows.length === 0) rows.push(plainRow("", "MdCodeBlock"));
      return rows;
    }
    case "quote": {
      const bar = { text: "▏ ", group: "MdQuote", src: block.markAt, srcEnd: block.markEnd, mark: true };
      const cont = { text: "▏ ", group: "MdQuote" };
      const segs = resolveSegments(parseInline(block.text, "MdQuote"), block.runs);
      return wrapSegments(segs, width, { firstPrefix: bar, contPrefix: cont, emptyGroup: "MdQuote" });
    }
    case "hr":
      return [{ segments: [{ text: ruleText(width), group: "MdRule", src: block.at, srcEnd: block.end, mark: true }] }];
    case "list": {
      const rows = /** @type {Row[]} */ ([]);
      for (const item of block.items) {
        const pad = "  ".repeat(item.indent);
        const mark = { text: pad + item.marker + " ", group: "MdListMark", src: item.markAt, srcEnd: item.markEnd, mark: true };
        const cont = { text: pad + "  ", group: "MdListMark" };
        const segs = resolveSegments(parseInline(item.text), item.runs);
        for (const r of wrapSegments(segs, width, { firstPrefix: mark, contPrefix: cont })) rows.push(r);
      }
      return rows;
    }
    case "table": {
      const rows = /** @type {Row[]} */ ([]);
      for (let r = 0; r < block.rows.length; r++) {
        const sourceCells = /** @type {TableCell[]} */ (block.rows[r]);
        const cells = sourceCells.slice(0, block.columns);
        while (cells.length < block.columns) cells.push({ text: "", runs: [] });
        const segs = [];
        for (let c = 0; c < cells.length; c++) {
          if (c > 0) segs.push({ text: " │ ", group: "MdTableBorder" });
          const cell = /** @type {TableCell} */ (cells[c]);
          for (const s of resolveSegments(parseInline(cell.text), cell.runs)) segs.push(s);
        }
        for (const row of wrapSegments(segs, width)) rows.push(row);
        if (r === 0) rows.push({ segments: [{ text: ruleText(width), group: "MdTableBorder", src: block.sepAt, srcEnd: block.sepEnd, mark: true }] });
      }
      return rows;
    }
    default:
      return [plainRow("")];
  }
}

export class Document {
  constructor() {
    /** @type {string | null} */
    this._src = null;
    /** @type {Block[]} */
    this._blocks = [];
    /** @type {Map<number, CacheEntry>} */
    this._cache = new Map();
  }

  // Return true when the source changed, so a caller can drop its own cache for this document.
  /** @param {string} text @returns {boolean} */
  setText(text) {
    text = String(text).replace(/\r\n?/g, "\n");
    if (text === this._src) return false;
    this._src = text;
    this._blocks = segment(text);
    // Drop cache entries for blocks that the new text no longer holds.
    const live = new Set();
    for (const b of this._blocks) if (!b.open) live.add(b.at);
    for (const key of this._cache.keys()) if (!live.has(key)) this._cache.delete(key);
    return true;
  }

  // The normalized markdown. A segment offset indexes into this text, never into the raw input.
  /** @returns {string} */
  sourceText() {
    return this._src == null ? "" : this._src;
  }

  /** @param {number} width @returns {Row[]} */
  rows(width) {
    const out = /** @type {Row[]} */ ([]);
    let first = true;
    for (const block of this._blocks) {
      if (!first) out.push(plainRow(""));
      first = false;
      for (const r of this._blockRows(block, width)) out.push(r);
    }
    return out;
  }

  // The blocks in document order, for a caller that moves by markdown structure.
  /** @returns {BlockSummary[]} */
  blocks() {
    return this._blocks.map((b) => ({ kind: b.kind, at: b.at, end: b.end }));
  }

  // The fenced code blocks, in document order. The text is the body, without the fence lines.
  /** @returns {{lang: string, text: string}[]} */
  codeBlocks() {
    const out = /** @type {{lang: string, text: string}[]} */ ([]);
    for (const b of this._blocks) {
      if (b.kind === "code") out.push({ lang: b.lang || "", text: b.lines.join("\n") });
    }
    return out;
  }

  // The cache keys on the block offset, because a segment holds absolute offsets; `raw` catches a change under one offset.
  /** @param {Block} block @param {number} width @returns {Row[]} */
  _blockRows(block, width) {
    if (block.open) return renderBlock(block, width);
    let entry = this._cache.get(block.at);
    if (!entry || entry.raw !== block.raw) {
      entry = { raw: block.raw, width: null, rows: null };
      this._cache.set(block.at, entry);
    }
    if (entry.width !== width) {
      entry.width = width;
      entry.rows = renderBlock(block, width);
    }
    return /** @type {Row[]} */ (entry.rows);
  }
}

/** @param {string} text @param {number} width @returns {Row[]} */
export function renderRows(text, width) {
  const doc = new Document();
  doc.setText(text);
  return doc.rows(width);
}

export { segment, parseInline };
