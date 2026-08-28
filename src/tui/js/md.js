import { term } from "yuke:term";
import { style } from "yuke:core";

// Register the Markdown groups once.
if (!style.groups.MdText) {
  Object.assign(style.groups, {
    MdText: { link: "Normal" },
    MdStrong: { fg: "fg", bold: true },
    MdEm: { fg: "fg", italic: true },
    MdCode: { fg: "muted" },
    MdHeading: { fg: "fg", bold: true },
    MdQuote: { fg: "muted" },
    MdCodeBlock: { fg: "muted" },
    MdRule: { fg: "rule" },
    MdListMark: { fg: "muted" },
    MdTableBorder: { fg: "rule" },
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
  return c === " " || c === "\t" || c === "\n" || c === "\r";
}

function isWord(c) {
  return c !== undefined && /[\p{L}\p{N}]/u.test(c);
}

function isPunctuation(c) {
  return c !== undefined && /[\p{P}\p{S}]/u.test(c);
}

function canOpen(text, i, length, marker) {
  const before = text[i - 1];
  const after = text[i + length];
  const left = after !== undefined && !isSpace(after) && (!isPunctuation(after) || before === undefined || isSpace(before) || isPunctuation(before));
  if (!left) return false;
  return marker !== "_" || !isWord(before) || !isWord(after);
}

function canClose(text, i, length, marker) {
  const before = text[i - 1];
  const after = text[i + length];
  const right = before !== undefined && !isSpace(before) && (!isPunctuation(before) || after === undefined || isSpace(after) || isPunctuation(after));
  if (!right) return false;
  return marker !== "_" || !isWord(before) || !isWord(after);
}

function findDelimiter(text, start, marker, length) {
  const delimiter = marker.repeat(length);
  for (let i = text.indexOf(delimiter, start); i >= 0; i = text.indexOf(delimiter, i + 1)) {
    if (canClose(text, i, length, marker)) return i;
  }
  return -1;
}

function findLinkEnd(text, start) {
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    if (text[i] === "\\") {
      i++;
      continue;
    }
    if (text[i] === "(") depth++;
    if (text[i] === ")") {
      if (depth === 0) return i;
      depth--;
    }
  }
  return -1;
}

function parseInline(text, baseGroup) {
  const base = baseGroup || "MdText";
  const out = [];
  let buf = "";
  let i = 0;
  const flush = (group) => {
    if (buf) out.push({ text: buf, group: group || base });
    buf = "";
  };

  while (i < text.length) {
    const c = text[i];

    if (c === "\\" && text[i + 1] && ESCAPABLE.indexOf(text[i + 1]) >= 0) {
      buf += text[i + 1];
      i += 2;
      continue;
    }

    if (c === "`") {
      let length = 1;
      while (text[i + length] === "`") length++;
      const delimiter = "`".repeat(length);
      const end = text.indexOf(delimiter, i + length);
      if (end >= i + length) {
        flush();
        let code = text.slice(i + length, end).replace(/[\r\n]/g, " ");
        if (code.length > 1 && code[0] === " " && code[code.length - 1] === " " && /[^ ]/.test(code)) code = code.slice(1, -1);
        out.push({ text: code, group: "MdCode" });
        i = end + length;
        continue;
      }
      buf += delimiter;
      i += length;
      continue;
    }

    if ((c === "*" || c === "_") && text[i + 1] === c) {
      if (canOpen(text, i, 2, c)) {
        const close = findDelimiter(text, i + 2, c, 2);
        if (close >= i + 3) {
          flush();
          out.push({ text: text.slice(i + 2, close), group: "MdStrong" });
          i = close + 2;
          continue;
        }
      }
      buf += c + c;
      i += 2;
      continue;
    }

    if ((c === "*" || c === "_") && canOpen(text, i, 1, c)) {
      const close = findDelimiter(text, i + 1, c, 1);
      if (close >= i + 2) {
        flush();
        out.push({ text: text.slice(i + 1, close), group: "MdEm" });
        i = close + 1;
        continue;
      }
    }

    if (c === "[") {
      let depth = 0;
      let bar = -1;
      for (let j = i + 1; j < text.length; j++) {
        if (text[j] === "\\") {
          j++;
          continue;
        }
        if (text[j] === "[") depth++;
        if (text[j] === "]") {
          if (depth === 0) {
            bar = j;
            break;
          }
          depth--;
        }
      }
      if (bar > i && text[bar + 1] === "(") {
        const paren = findLinkEnd(text, bar + 2);
        if (paren > bar) {
          flush();
          for (const segment of parseInline(text.slice(i + 1, bar), base)) {
            if (segment.text) out.push(segment);
          }
          i = paren + 1;
          continue;
        }
      }
    }

    buf += c;
    i++;
  }
  flush();
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
