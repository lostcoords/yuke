import { term } from "yuke:term";
import { style } from "yuke:core";

// Register the Markdown groups once.
if (!style.groups.MdText) {
  Object.assign(style.groups, {
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
  style.invalidate();
}

const FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const FENCE_CLOSE = /^( {0,3})(`{3,}|~{3,})[ \t]*$/;
const HEADING = /^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?[ \t]*$/;
const HR = /^( {0,3})(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/;
const QUOTE = /^( {0,3})>([ \t]?)(.*)$/;
const UL_ITEM = /^( {0,3})([-*+])([ \t]+)(.*)$/;
const OL_ITEM = /^( {0,3})(\d{1,9})([.)])([ \t]+)(.*)$/;
const SETEXT = /^( {0,3})(=+|-+)[ \t]*$/;

function fenceOpen(line) {
  const m = FENCE.exec(line);
  if (!m || (m[2][0] === "`" && m[3].indexOf("`") >= 0)) return null;
  return { marker: m[2][0], length: m[2].length, indent: m[1].length, lang: m[3].trim() };
}

function fenceClose(line, marker, length) {
  const m = FENCE_CLOSE.exec(line);
  return m && m[2][0] === marker && m[2].length >= length;
}

function isBlockStart(line) {
  return fenceOpen(line) || HEADING.test(line) || HR.test(line) || QUOTE.test(line) || UL_ITEM.test(line) || OL_ITEM.test(line);
}

function isTableSeparator(line) {
  const cells = splitTableRow(line, 0);
  return cells.length > 0 && cells.every((cell) => /^:?-{1,}:?$/.test(cell.text));
}

function hasUnescapedPipe(line) {
  for (let i = 0; i < line.length; i++) if (line[i] === "|" && !isEscaped(line, i)) return true;
  return false;
}

function isSetextHeading(lines, i) {
  return i + 1 < lines.length && lines[i].trim() !== "" && !isBlockStart(lines[i]) && SETEXT.test(lines[i + 1]);
}

function stripFenceIndent(line, indent) {
  let count = 0;
  while (count < indent && line[count] === " ") count++;
  return line.slice(count);
}

// Inline text plus where each part comes from. A run maps text [at, at+len) to source [src, src+len).
function inlineSource() {
  return { text: "", runs: [] };
}

function addSource(s, text, src) {
  if (!text) return;
  const last = s.runs[s.runs.length - 1];
  if (last && last.src + last.len === src) last.len += text.length;
  else s.runs.push({ at: s.text.length, src, len: text.length });
  s.text += text;
}

// One run, for text that comes from a single contiguous source range.
function oneRun(text, src) {
  return text.length ? [{ at: 0, src, len: text.length }] : [];
}

// The run that holds inline index `i`. The runs cover the whole inline text in order.
function runFor(runs, i) {
  for (let k = runs.length - 1; k > 0; k--) if (i >= runs[k].at) return runs[k];
  return runs[0];
}

// The source offset of inline index `i`. `end` gives the offset after that character.
function srcAt(runs, i, end) {
  const r = runFor(runs, i);
  const o = r.src + Math.min(Math.max(0, i - r.at), r.len - 1);
  return end ? o + 1 : o;
}

// Split the text into blocks. `at` and `end` are source offsets, and `raw` checks the block cache.
// Only the open tail block may still change.
function segment(text) {
  const lines = text.split("\n");
  const starts = new Array(lines.length + 1);
  {
    let off = 0;
    for (let k = 0; k < lines.length; k++) {
      starts[k] = off;
      off += lines[k].length + 1;
    }
    starts[lines.length] = off;
  }
  const blocks = [];
  let i = 0;

  const push = (b, from, to) => {
    b.raw = lines.slice(from, to).join("\n");
    b.at = starts[from];
    b.end = starts[to] - 1;
    blocks.push(b);
  };

  while (i < lines.length) {
    const line = lines[i];

    if (line.trim() === "") {
      i++;
      continue;
    }

    const fence = fenceOpen(line);
    if (fence) {
      const marker = fence.marker;
      const body = [];
      const bodyAt = [];
      let j = i + 1;
      let closed = false;
      for (; j < lines.length; j++) {
        if (fenceClose(lines[j], marker, fence.length)) {
          closed = true;
          break;
        }
        const stripped = stripFenceIndent(lines[j], fence.indent);
        body.push(stripped);
        bodyAt.push(starts[j] + lines[j].length - stripped.length);
      }
      const to = closed ? j + 1 : lines.length;
      push({ kind: "code", lang: fence.lang, lines: body, lineAt: bodyAt, closed }, i, to);
      i = to;
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      const headingText = (heading[4] || "").replace(/[ \t]+#+[ \t]*$/, "").trim();
      const src = starts[i] + heading[1].length + heading[2].length + (heading[3] ? heading[3].length : 0);
      push({ kind: "heading", level: heading[2].length, text: headingText, runs: oneRun(headingText, src) }, i, i + 1);
      i++;
      continue;
    }

    if (isSetextHeading(lines, i)) {
      const headingText = line.trim();
      const src = starts[i] + line.length - line.trimStart().length;
      const level = lines[i + 1].trimStart()[0] === "=" ? 1 : 2;
      push({ kind: "heading", level, text: headingText, runs: oneRun(headingText, src) }, i, i + 2);
      i += 2;
      continue;
    }

    if (HR.test(line)) {
      push({ kind: "hr" }, i, i + 1);
      i++;
      continue;
    }

    if (QUOTE.test(line)) {
      let j = i;
      const body = inlineSource();
      let markEnd = starts[i];
      for (; j < lines.length && QUOTE.test(lines[j]); j++) {
        const m = QUOTE.exec(lines[j]);
        const src = starts[j] + m[1].length + 1 + m[2].length;
        if (j === i) markEnd = src;
        else addSource(body, "\n", starts[j] - 1);
        addSource(body, m[3], src);
      }
      push({ kind: "quote", text: body.text, runs: body.runs, markAt: starts[i], markEnd }, i, j);
      i = j;
      continue;
    }

    if (UL_ITEM.test(line) || OL_ITEM.test(line)) {
      let j = i;
      const items = [];
      let ordered = !!OL_ITEM.exec(line);
      for (; j < lines.length; j++) {
        const m = ordered ? OL_ITEM.exec(lines[j]) : UL_ITEM.exec(lines[j]);
        if (!m) break;
        // The last group runs to the end of the line, so its offset needs no group arithmetic.
        const body = m[m.length - 1];
        const src = starts[j] + lines[j].length - body.length;
        items.push({
          indent: Math.floor(m[1].length / 2),
          marker: ordered ? m[2] + "." : "•",
          text: body,
          runs: oneRun(body, src),
          markAt: starts[j],
          markEnd: src,
        });
      }
      push({ kind: "list", ordered, items }, i, j);
      i = j;
      continue;
    }

    const headerCells = hasUnescapedPipe(line) ? splitTableRow(line, starts[i]) : [];
    const separatorCells = i + 1 < lines.length && isTableSeparator(lines[i + 1]) ? splitTableRow(lines[i + 1], starts[i + 1]) : [];
    if (headerCells.length > 0 && headerCells.length === separatorCells.length) {
      let j = i + 2;
      for (; j < lines.length && lines[j].trim() !== "" && !isBlockStart(lines[j]); j++);
      const rows = [];
      for (let k = i; k < j; k++) {
        if (k === i + 1) continue;
        rows.push(splitTableRow(lines[k], starts[k]));
      }
      const sepAt = starts[i + 1];
      push({ kind: "table", columns: headerCells.length, rows, sepAt, sepEnd: sepAt + lines[i + 1].length }, i, j);
      i = j;
      continue;
    }

    // Consume a paragraph until a blank line or a new block. A line feed joins as one space, so
    // the inline text keeps the length of its source.
    let j = i;
    const body = inlineSource();
    for (; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === "") break;
      if (isBlockStart(l) || isSetextHeading(lines, j)) break;
      if (j > i) addSource(body, " ", starts[j] - 1);
      addSource(body, l, starts[j]);
    }
    push({ kind: "paragraph", text: body.text, runs: body.runs }, i, j);
    i = j;
  }

  // The last block may still grow as a stream appends text, so never cache it.
  if (blocks.length) blocks[blocks.length - 1].open = true;
  return blocks;
}

// Split a table row into cells. `base` is the source offset of the line, so a cell keeps its runs.
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
function tableCell(line, from, to, base) {
  while (from < to && (line[from] === " " || line[from] === "\t")) from++;
  while (to > from && (line[to - 1] === " " || line[to - 1] === "\t")) to--;
  const text = line.slice(from, to);
  return { text, runs: oneRun(text, base + from) };
}

function isEscaped(text, index) {
  let slashes = 0;
  for (let i = index - 1; i >= 0 && text[i] === "\\"; i--) slashes++;
  return slashes % 2 === 1;
}

const ESCAPABLE = "\\`*{}[]()#+-.!_>~|";

function isSpace(c) {
  return c === undefined || /\s/u.test(c);
}

function isPunctuation(c) {
  return c !== undefined && /[\p{P}\p{S}]/u.test(c);
}

// The emphasis group for a bold and italic depth.
function emphGroup(bold, italic) {
  if (bold && italic) return "MdStrongEm";
  if (bold) return "MdStrong";
  if (italic) return "MdEm";
  return null;
}

// Flanking: a delimiter run opens or closes emphasis by the chars around it (CommonMark rules).
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

// Read a `[label](dest)` link. Return the label and the end index, or null when it is not a link.
// A destination holds no space, so a malformed link stays literal.
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

// Parse inline text into styled segments. Code spans and links resolve first; a delimiter stack
// then folds emphasis, so nested and triple runs (**a *b* c**, ***x***) render correctly.
function parseInline(text, baseGroup) {
  const base = baseGroup || "MdText";
  const cps = Array.from(text);
  // The parser walks code points, but a segment range is UTF-16, so keep both indexes.
  const units = new Array(cps.length + 1);
  {
    let u = 0;
    for (let k = 0; k < cps.length; k++) {
      units[k] = u;
      u += cps[k].length;
    }
    units[cps.length] = u;
  }
  const nodes = []; // { kind, text, at, len, … }; at and len are the UTF-16 range of the source
  const delims = []; // indices into nodes of open/close delimiter runs

  let i = 0;
  while (i < cps.length) {
    const c = cps[i];
    if (c === "\\" && i + 1 < cps.length && ESCAPABLE.indexOf(cps[i + 1]) >= 0) {
      nodes.push({ kind: "text", text: cps[i + 1], at: units[i], len: units[i + 2] - units[i] });
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
        nodes.push({ kind: "seg", text: code, group: "MdCode", at: units[from], len: units[to] - units[from] });
        i = close + n;
        continue;
      }
      nodes.push({ kind: "text", text: "`".repeat(n), at: units[i], len: units[i + n] - units[i] });
      i += n;
      continue;
    }
    if (c === "[") {
      const link = scanLink(cps, i);
      if (link) {
        // The label is a verbatim slice of the parent, so a sub-range shifts by the label offset.
        const shift = units[i + 1];
        for (const s of parseInline(link.label, base)) {
          if (s.text) nodes.push({ kind: "seg", text: s.text, group: s.group, at: shift + s.at, len: s.len });
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
        at: units[i],
        len: units[i + d.count] - units[i],
        marker: c,
        count: d.count,
        canOpen: d.canOpen,
        canClose: d.canClose,
      });
      delims.push(nodes.length - 1);
      i += d.count;
      continue;
    }
    nodes.push({ kind: "text", text: c, at: units[i], len: c.length });
    i++;
  }

  foldEmphasis(nodes, delims);
  return flattenInline(nodes, base);
}

// The delimiter stack. For each closer, match the nearest compatible opener and record a strong or
// emphasis pair on the two runs. Unused delimiters stay literal.
function foldEmphasis(nodes, delims) {
  for (let ci = 0; ci < delims.length; ci++) {
    const closer = nodes[delims[ci]];
    if (closer.kind !== "delim" || !closer.canClose) continue;
    while (closer.count > 0) {
      let matched = false;
      for (let oi = ci - 1; oi >= 0; oi--) {
        const opener = nodes[delims[oi]];
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

// Walk the folded nodes and emit segments, tracking the bold and emphasis depth per position.
// Text merges only while the source stays contiguous, so a merged segment can split by offset.
function flattenInline(nodes, base) {
  const out = [];
  let bold = 0;
  let italic = 0;
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

// Map inline segments onto source offsets. A segment splits at a run edge, so every piece stays
// linear (`srcEnd - src === text.length`) unless the markup itself is not, as with an escape.
function resolveSegments(segments, runs) {
  if (!runs || runs.length === 0) return segments.map((s) => ({ text: s.text, group: s.group }));
  const out = [];
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

// One source character per rendered character, so an offset survives a slice. A mark stands for
// markup it hides, and an escape renders fewer characters than its source; neither one is linear.
export function isLinear(seg) {
  return seg.src != null && !seg.mark && seg.srcEnd - seg.src === seg.text.length;
}

// Slice a resolved segment. A segment that is not linear keeps its whole source span. It is never
// wider than one grapheme, so a wrap never splits one.
function sliceSegment(seg, from, to) {
  const out = { text: seg.text.slice(from, to), group: seg.group };
  if (seg.src == null) return out;
  if (!isLinear(seg)) {
    out.src = seg.src;
    out.srcEnd = seg.srcEnd;
    if (seg.mark) out.mark = true;
    return out;
  }
  out.src = seg.src + from;
  out.srcEnd = seg.src + to;
  return out;
}

// Two neighbours merge only while both their text and their source stay contiguous.
function segmentsJoin(a, b) {
  if (a.group !== b.group) return false;
  if (a.src == null && b.src == null) return true;
  return a.srcEnd === b.src && isLinear(a) && isLinear(b);
}

function wrapSegments(segments, width, opts) {
  const o = opts || {};
  const first = o.firstPrefix || null;
  const cont = o.contPrefix || null;
  const prefixW = (p) => (p ? term.measure(p.text) : 0);
  const firstW = prefixW(first);
  const contW = prefixW(cont);
  const available = () => Math.max(1, width - (rows.length === 0 ? firstW : contW));
  const spaceW = term.measure(" ");

  const words = segmentsToWords(segments);
  const rows = [];
  let line = [];
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
        line = broken[i].segments;
        lineW = broken[i].w;
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

// Split the segments at every blank run. A piece keeps its source offsets, so a wrap does not
// lose them. The blank runs drop out, and `wrapSegments` puts one space back between two words.
function segmentsToWords(segments) {
  const words = [];
  let cur = null;
  let spaceGroup = null;
  const close = () => {
    if (cur) words.push(cur);
    cur = null;
  };
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

function hardBreakPieces(pieces, width) {
  const out = [];
  let segments = [];
  let lineW = 0;
  const emit = () => {
    if (segments.length) out.push({ segments, w: lineW });
    segments = [];
    lineW = 0;
  };
  const append = (seg, w) => {
    const last = segments[segments.length - 1];
    if (last && segmentsJoin(last, seg)) {
      last.text += seg.text;
      if (last.src != null) last.srcEnd = seg.srcEnd;
    } else segments.push(seg);
    lineW += w;
  };
  for (const piece of pieces) {
    const gs = term.graphemes(piece.text);
    for (let k = 0; k < gs.length; k += 3) {
      const w = gs[k + 2];
      if (segments.length && lineW + w > width) emit();
      append(sliceSegment(piece, gs[k], gs[k] + gs[k + 1]), w);
      if (lineW >= width) emit();
    }
  }
  emit();
  return out;
}

function plainRow(text, group) {
  return { segments: [{ text, group: group || "MdText" }] };
}

function ruleText(width) {
  const glyph = "─";
  const glyphW = term.measure(glyph);
  const count = Math.max(1, Math.floor(Math.max(1, width) / glyphW));
  return glyph.repeat(count);
}

// A rendered segment carries the source it came from. A `mark` segment stands for markup it does
// not show, so it takes that markup's span. A pure separator, such as a column border, carries none.
function renderBlock(block, width) {
  switch (block.kind) {
    case "heading": {
      const segs = resolveSegments(parseInline(block.text, "MdHeading"), block.runs).map((s) => ({ ...s, group: "MdHeading" }));
      return wrapSegments(segs, width, { emptyGroup: "MdHeading" });
    }
    case "paragraph":
      return wrapSegments(resolveSegments(parseInline(block.text), block.runs), width);
    case "code": {
      const rows = [];
      for (let k = 0; k < block.lines.length; k++) {
        const at = block.lineAt[k];
        const line = { text: block.lines[k], group: "MdCodeBlock", src: at, srcEnd: at + block.lines[k].length };
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
      const rows = [];
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
      const rows = [];
      for (let r = 0; r < block.rows.length; r++) {
        const cells = block.rows[r].slice(0, block.columns);
        while (cells.length < block.columns) cells.push({ text: "", runs: [] });
        const segs = [];
        for (let c = 0; c < cells.length; c++) {
          if (c > 0) segs.push({ text: " │ ", group: "MdTableBorder" });
          for (const s of resolveSegments(parseInline(cells[c].text), cells[c].runs)) segs.push(s);
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
    this._src = null;
    this._blocks = [];
    this._cache = new Map();
  }

  // Return true when the source changed, so a caller can drop its own cache for this document.
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
  sourceText() {
    return this._src == null ? "" : this._src;
  }

  rows(width) {
    const out = [];
    let first = true;
    for (const block of this._blocks) {
      if (!first) out.push(plainRow(""));
      first = false;
      for (const r of this._blockRows(block, width)) out.push(r);
    }
    return out;
  }

  // The fenced code blocks, in document order. The text is the body, without the fence lines.
  codeBlocks() {
    const out = [];
    for (const b of this._blocks) {
      if (b.kind === "code") out.push({ lang: b.lang || "", text: b.lines.join("\n") });
    }
    return out;
  }

  // The cache keys on the block offset, because a rendered segment holds absolute source offsets.
  // Two blocks can hold the same text, so `raw` catches a block that changed under one offset.
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
    return entry.rows;
  }
}

export function renderRows(text, width) {
  const doc = new Document();
  doc.setText(text);
  return doc.rows(width);
}

export { segment, parseInline };
