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
const HEADING = /^( {0,3})(#{1,6})(?:[ \t]+(.*?))?[ \t]*$/;
const HR = /^( {0,3})(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/;
const QUOTE = /^( {0,3})>[ \t]?(.*)$/;
const UL_ITEM = /^( {0,3})([-*+])[ \t]+(.*)$/;
const OL_ITEM = /^( {0,3})(\d{1,9})[.)][ \t]+(.*)$/;
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
  const cells = splitTableRow(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{1,}:?$/.test(cell));
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

// Keep the source of each block as the cache key. Only the open tail block may still change.
function segment(text) {
  const lines = text.split("\n");
  const blocks = [];
  let i = 0;

  const push = (b, from, to) => {
    b.src = lines.slice(from, to).join("\n");
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
      let j = i + 1;
      let closed = false;
      for (; j < lines.length; j++) {
        if (fenceClose(lines[j], marker, fence.length)) {
          closed = true;
          break;
        }
        body.push(stripFenceIndent(lines[j], fence.indent));
      }
      const to = closed ? j + 1 : lines.length;
      push({ kind: "code", lang: fence.lang, lines: body, closed }, i, to);
      i = to;
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      const headingText = (heading[3] || "").replace(/[ \t]+#+[ \t]*$/, "").trim();
      push({ kind: "heading", level: heading[2].length, text: headingText }, i, i + 1);
      i++;
      continue;
    }

    if (isSetextHeading(lines, i)) {
      push({ kind: "heading", level: lines[i + 1].trimStart()[0] === "=" ? 1 : 2, text: line.trim() }, i, i + 2);
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
      const body = [];
      for (; j < lines.length && QUOTE.test(lines[j]); j++) body.push(QUOTE.exec(lines[j])[2]);
      push({ kind: "quote", text: body.join("\n") }, i, j);
      i = j;
      continue;
    }

    if (UL_ITEM.test(line) || OL_ITEM.test(line)) {
      let j = i;
      const items = [];
      let ordered = !!OL_ITEM.exec(line);
      for (; j < lines.length; j++) {
        const ul = UL_ITEM.exec(lines[j]);
        const ol = OL_ITEM.exec(lines[j]);
        const m = ordered ? ol : ul;
        if (!m) break;
        items.push({ indent: Math.floor(m[1].length / 2), marker: ordered ? m[2] + "." : "•", text: m[3] });
      }
      push({ kind: "list", ordered, items }, i, j);
      i = j;
      continue;
    }

    const headerCells = hasUnescapedPipe(line) ? splitTableRow(line) : [];
    const separatorCells = i + 1 < lines.length && isTableSeparator(lines[i + 1]) ? splitTableRow(lines[i + 1]) : [];
    if (headerCells.length > 0 && headerCells.length === separatorCells.length) {
      let j = i + 2;
      for (; j < lines.length && lines[j].trim() !== "" && !isBlockStart(lines[j]); j++);
      const rows = [];
      for (let k = i; k < j; k++) {
        if (k === i + 1) continue;
        rows.push(splitTableRow(lines[k]));
      }
      push({ kind: "table", columns: headerCells.length, rows }, i, j);
      i = j;
      continue;
    }

    // Consume a paragraph until a blank line or a new block.
    let j = i;
    const body = [];
    for (; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === "") break;
      if (isBlockStart(l) || isSetextHeading(lines, j)) break;
      body.push(l);
    }
    push({ kind: "paragraph", text: body.join(" ") }, i, j);
    i = j;
  }

  // The last block may still grow as a stream appends text, so never cache it.
  if (blocks.length) blocks[blocks.length - 1].open = true;
  return blocks;
}

function splitTableRow(line) {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|") && !isEscaped(s, s.length - 1)) s = s.slice(0, -1);
  const cells = [];
  let cell = "";
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "|" && !isEscaped(s, i)) {
      cells.push(cell.trim());
      cell = "";
    } else if (s[i] === "|" && isEscaped(s, i)) {
      if (cell.endsWith("\\")) cell = cell.slice(0, -1);
      cell += "|";
    } else {
      cell += s[i];
    }
  }
  cells.push(cell.trim());
  return cells;
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
  const nodes = []; // { kind:"text"|"seg", text, group?, marker?, count?, canOpen?, canClose? }
  const delims = []; // indices into nodes of open/close delimiter runs

  let i = 0;
  while (i < cps.length) {
    const c = cps[i];
    if (c === "\\" && i + 1 < cps.length && ESCAPABLE.indexOf(cps[i + 1]) >= 0) {
      nodes.push({ kind: "text", text: cps[i + 1] });
      i += 2;
      continue;
    }
    if (c === "`") {
      let n = 1;
      while (cps[i + n] === "`") n++;
      const close = closeCodeSpan(cps, i + n, n);
      if (close >= 0) {
        let code = cps.slice(i + n, close).join("").replace(/[\r\n]/g, " ");
        if (code.length > 2 && code[0] === " " && code[code.length - 1] === " " && /[^ ]/.test(code)) code = code.slice(1, -1);
        nodes.push({ kind: "seg", text: code, group: "MdCode" });
        i = close + n;
        continue;
      }
      nodes.push({ kind: "text", text: "`".repeat(n) });
      i += n;
      continue;
    }
    if (c === "[") {
      const link = scanLink(cps, i);
      if (link) {
        for (const s of parseInline(link.label, base)) if (s.text) nodes.push({ kind: "seg", text: s.text, group: s.group });
        i = link.end + 1;
        continue;
      }
    }
    if (c === "*" || c === "_") {
      const d = scanDelims(cps, i, c);
      nodes.push({ kind: "delim", text: c.repeat(d.count), marker: c, count: d.count, canOpen: d.canOpen, canClose: d.canClose });
      delims.push(nodes.length - 1);
      i += d.count;
      continue;
    }
    nodes.push({ kind: "text", text: c });
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
// Adjacent same-group text merges into one segment.
function flattenInline(nodes, base) {
  const out = [];
  let bold = 0;
  let italic = 0;
  const emit = (text, group) => {
    if (!text) return;
    const last = out[out.length - 1];
    if (last && last.group === group) last.text += text;
    else out.push({ text, group });
  };
  for (const n of nodes) {
    if (n.kind === "seg") {
      emit(n.text, n.group);
      continue;
    }
    if (n.kind === "delim") {
      bold -= n.closeStrong || 0;
      italic -= n.closeEm || 0;
      if (n.count > 0) emit(n.marker.repeat(n.count), emphGroup(bold > 0, italic > 0) || base);
      bold += n.openStrong || 0;
      italic += n.openEm || 0;
      continue;
    }
    emit(n.text, emphGroup(bold > 0, italic > 0) || base);
  }
  return out.length ? out : [{ text: "", group: base }];
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

function segmentsToWords(segments) {
  const words = [];
  let cur = null;
  let spaceGroup = null;
  const close = () => {
    if (cur) words.push(cur);
    cur = null;
  };
  for (const seg of segments) {
    const parts = seg.text.split(/[ \t]+/);
    for (let k = 0; k < parts.length; k++) {
      if (k > 0) {
        close();
        spaceGroup = seg.group;
      }
      const t = parts[k];
      if (t === "") continue;
      if (!cur) {
        cur = { pieces: [], w: 0, spaceGroup };
        spaceGroup = null;
      }
      const w = term.measure(t);
      cur.pieces.push({ text: t, group: seg.group });
      cur.w += w;
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
  const append = (text, group, w) => {
    const last = segments[segments.length - 1];
    if (last && last.group === group) last.text += text;
    else segments.push({ text, group });
    lineW += w;
  };
  for (const piece of pieces) {
    const gs = term.graphemes(piece.text);
    for (let k = 0; k < gs.length; k += 3) {
      const text = piece.text.slice(gs[k], gs[k] + gs[k + 1]);
      const w = gs[k + 2];
      if (segments.length && lineW + w > width) emit();
      append(text, piece.group, w);
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

function renderBlock(block, width) {
  switch (block.kind) {
    case "heading": {
      const segs = parseInline(block.text, "MdHeading").map((s) => ({ text: s.text, group: "MdHeading" }));
      return wrapSegments(segs, width, { emptyGroup: "MdHeading" });
    }
    case "paragraph":
      return wrapSegments(parseInline(block.text), width);
    case "code": {
      const rows = [];
      for (const l of block.lines) {
        const parts = hardBreakPieces([{ text: l, group: "MdCodeBlock" }], width);
        if (parts.length === 0) rows.push(plainRow("", "MdCodeBlock"));
        for (const p of parts) rows.push({ segments: p.segments });
      }
      if (rows.length === 0) rows.push(plainRow("", "MdCodeBlock"));
      return rows;
    }
    case "quote": {
      const bar = { text: "▏ ", group: "MdQuote" };
      return wrapSegments(parseInline(block.text, "MdQuote"), width, { firstPrefix: bar, contPrefix: bar, emptyGroup: "MdQuote" });
    }
    case "hr":
      return [plainRow(ruleText(width), "MdRule")];
    case "list": {
      const rows = [];
      for (const item of block.items) {
        const pad = "  ".repeat(item.indent);
        const mark = { text: pad + item.marker + " ", group: "MdListMark" };
        const cont = { text: pad + "  ", group: "MdListMark" };
        for (const r of wrapSegments(parseInline(item.text), width, { firstPrefix: mark, contPrefix: cont })) rows.push(r);
      }
      return rows;
    }
    case "table": {
      const rows = [];
      for (let r = 0; r < block.rows.length; r++) {
        const cells = block.rows[r].slice(0, block.columns);
        while (cells.length < block.columns) cells.push("");
        const segs = [];
        for (let c = 0; c < cells.length; c++) {
          if (c > 0) segs.push({ text: " │ ", group: "MdTableBorder" });
          for (const s of parseInline(cells[c])) segs.push(s);
        }
        for (const row of wrapSegments(segs, width)) rows.push(row);
        if (r === 0) rows.push(plainRow(ruleText(width), "MdTableBorder"));
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

  setText(text) {
    text = String(text).replace(/\r\n?/g, "\n");
    if (text === this._src) return;
    this._src = text;
    this._blocks = segment(text);
    // Drop cache entries for blocks that the new text no longer holds.
    const live = new Set();
    for (const b of this._blocks) if (!b.open) live.add(b.src);
    for (const key of this._cache.keys()) if (!live.has(key)) this._cache.delete(key);
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

  _blockRows(block, width) {
    if (block.open) return renderBlock(block, width);
    let entry = this._cache.get(block.src);
    if (!entry) {
      entry = { width: null, rows: null };
      this._cache.set(block.src, entry);
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
