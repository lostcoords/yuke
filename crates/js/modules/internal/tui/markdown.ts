/**
 * `Markdown` of `yuke:tui`: Markdown to styled rows. A stream parses again only its last two blocks. Each closed block
 * keeps its rows for its newest width. A segment with a source maps back to the source. A layout segment, such as the
 * continuation indent of a list item, has none. A link keeps its brackets and its target, so a copy keeps the target.
 * The style groups are `markdown.*`. The default theme gives most of them a look, and a plugin can change each one.
 */
import { termGraphemes, termMeasure } from "yuke:internal/native";
import type { MarkdownBlock, SourceMapping, TextRow } from "yuke:tui";

/** Printable ASCII: each character is one cell and one grapheme, so its width needs no native call. */
const ASCII = /^[\x20-\x7e]*$/;

/** The width of `text` in cells. */
function widthOf(text: string): number {
  return ASCII.test(text) ? text.length : termMeasure(text);
}

/** A segment before the renderer returns it, with a style group name. */
interface Part {
  text: string;
  style: string;
  source?: SourceMapping;
  link?: string;
  copy?: false;
}

/** A row while it builds. `width` is its width in cells, when the renderer counted it. */
interface Row {
  segments: Part[];
  join: string;
  width?: number;
}

/** The style groups of the rendered text. */
const STYLE = {
  text: "markdown.text",
  strong: "markdown.strong",
  emphasis: "markdown.emphasis",
  strongEmphasis: "markdown.strongEmphasis",
  code: "markdown.code",
  heading: "markdown.heading",
  quote: "markdown.quote",
  codeBlock: "markdown.codeBlock",
  rule: "markdown.rule",
  listMark: "markdown.listMark",
  tableBorder: "markdown.tableBorder",
  /** The label of a link. */
  linkText: "markdown.linkText",
  /** The brackets and the target of a link. */
  link: "markdown.link",
} as const;

/** A contiguous source range of inline text: the inline index `at` maps to the source offset `src`. */
interface SourceRun {
  at: number;
  src: number;
  len: number;
}

interface InlineSource {
  text: string;
  runs: SourceRun[];
}

type Align = "left" | "center" | "right";

interface BlockBase {
  at: number;
  end: number;
}

/** A table cell, with the source offset of the pipe before it when it has one. */
interface TableCell extends InlineSource {
  pipe?: number;
}

interface ListItem extends InlineSource {
  indent: number;
  marker: string;
  markAt: number;
  markEnd: number;
}

type Block = BlockBase &
  (
    | { kind: "heading"; text: string; runs: SourceRun[] }
    | { kind: "paragraph"; text: string; runs: SourceRun[] }
    | { kind: "code"; language: string; lines: string[]; lineAt: number[] }
    | { kind: "quote"; text: string; runs: SourceRun[]; markAt: number; markEnd: number }
    | { kind: "rule" }
    | { kind: "list"; items: ListItem[] }
    | { kind: "table"; columns: number; rows: TableCell[][]; align: Align[]; sepAt: number; sepEnd: number }
  );

/** The fields of a parsed block, without the fields of `BlockBase` that `segment` adds. */
type Parsed = Block extends infer B ? (B extends Block ? Omit<B, keyof BlockBase> : never) : never;

interface Fence {
  marker: string;
  length: number;
  indent: number;
  language: string;
}

const FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const FENCE_CLOSE = /^( {0,3})(`{3,}|~{3,})[ \t]*$/;
const HEADING = /^( {0,3})(#{1,6})(?:([ \t]+)(.*?))?[ \t]*$/;
const HR = /^( {0,3})(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/;
const QUOTE = /^( {0,3})>([ \t]?)(.*)$/;
const UL_ITEM = /^( {0,3})([-*+])([ \t]+)(.*)$/;
const OL_ITEM = /^( {0,3})(\d{1,9})([.)])([ \t]+)(.*)$/;
const SETEXT = /^( {0,3})(=+|-+)[ \t]*$/;
// QuickJS builds a new RegExp each time a literal runs, so the tests per line and per delimiter hold one each.
const TABLE_RULE = /^:?-{1,}:?$/;
const HEADING_TAIL = /[ \t]+#+[ \t]*$/;
const SPACE = /\s/u;
const PUNCT = /[\p{P}\p{S}]/u;
const NOT_SPACE = /[^ ]/;
/** The first characters of a fence, a heading, a rule, a quote, a bullet item, and a setext underline. */
const BLOCK_MARKERS = "`~#-*_>+=";

/** Whether `line` needs the block patterns: a block marker or a digit after at most three spaces. */
function mayStartBlock(line: string): boolean {
  let i = 0;
  while (i < 3 && line[i] === " ") i++;
  const c = line[i];
  return c !== undefined && (BLOCK_MARKERS.includes(c) || (c >= "0" && c <= "9"));
}

function fenceOpen(line: string): Fence | null {
  const m = FENCE.exec(line);
  if (m === null) return null;
  const marks = m[2] as string;
  const marker = marks[0] as string;
  const info = m[3] as string;
  if (marker === "`" && info.includes("`")) return null;
  return { marker, length: marks.length, indent: (m[1] as string).length, language: info.trim() };
}

function isBlockStart(line: string): boolean {
  return (
    mayStartBlock(line) &&
    (fenceOpen(line) !== null ||
      HEADING.test(line) ||
      HR.test(line) ||
      QUOTE.test(line) ||
      UL_ITEM.test(line) ||
      OL_ITEM.test(line))
  );
}

function hasUnescapedPipe(line: string): boolean {
  for (let i = 0; i < line.length; i++) if (line[i] === "|" && !isEscaped(line, i)) return true;
  return false;
}

function isSetextHeading(lines: readonly string[], i: number): boolean {
  const next = lines[i + 1];
  const line = lines[i] as string;
  return next !== undefined && mayStartBlock(next) && line.trim() !== "" && !isBlockStart(line) && SETEXT.test(next);
}

function addSource(s: InlineSource, text: string, src: number): void {
  if (text === "") return;
  const last = s.runs.at(-1);
  if (last !== undefined && last.src + last.len === src) last.len += text.length;
  else s.runs.push({ at: s.text.length, src, len: text.length });
  s.text += text;
}

/** One run, for text that comes from one contiguous source range. */
function oneRun(text: string, src: number): SourceRun[] {
  return text.length > 0 ? [{ at: 0, src, len: text.length }] : [];
}

/** The run that holds the inline index `i`. The runs cover the whole inline text in order. */
function runFor(runs: readonly SourceRun[], i: number): SourceRun {
  for (let k = runs.length - 1; k > 0; k--) {
    const run = runs[k] as SourceRun;
    if (i >= run.at) return run;
  }
  return runs[0] as SourceRun;
}

/** The source offset of the inline index `i`. `end` gives the offset after that character. */
function srcAt(runs: readonly SourceRun[], i: number, end: boolean): number {
  const r = runFor(runs, i);
  const o = r.src + Math.min(Math.max(0, i - r.at), r.len - 1);
  return end ? o + 1 : o;
}

/** The blocks of `text`, with absolute offsets. `base` is the source offset of its first character. */
function segment(text: string, base: number): Block[] {
  const lines = text.split("\n");
  const starts: number[] = [];
  let offset = base;
  for (const line of lines) {
    starts.push(offset);
    offset += line.length + 1;
  }
  starts.push(offset);
  const start = (k: number): number => starts[k] as number;
  const blocks: Block[] = [];
  const push = (parsed: Parsed, first: number, last: number): void => {
    const at = start(first);
    // Each line but the last ends in "\n".
    const end = start(last) - 1;
    blocks.push({ ...parsed, at, end } as Block);
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i] as string;
    if (line.trim() === "") {
      i++;
      continue;
    }
    const canStartBlock = mayStartBlock(line);
    const fence = canStartBlock ? fenceOpen(line) : null;
    if (fence !== null) {
      const body: string[] = [];
      const bodyAt: number[] = [];
      let j = i + 1;
      let closed = false;
      for (; j < lines.length; j++) {
        const sourceLine = lines[j] as string;
        const close = FENCE_CLOSE.exec(sourceLine);
        const marks = close?.[2];
        if (marks !== undefined && marks[0] === fence.marker && marks.length >= fence.length) {
          closed = true;
          break;
        }
        let cut = 0;
        while (cut < fence.indent && sourceLine[cut] === " ") cut++;
        body.push(sourceLine.slice(cut));
        bodyAt.push(start(j) + cut);
      }
      const to = closed ? j + 1 : lines.length;
      push({ kind: "code", language: fence.language, lines: body, lineAt: bodyAt }, i, to);
      i = to;
      continue;
    }

    const heading = canStartBlock ? HEADING.exec(line) : null;
    if (heading !== null) {
      const headingText = (heading[4] ?? "").replace(HEADING_TAIL, "").trim();
      const src = start(i) + (heading[1] as string).length + (heading[2] as string).length + (heading[3] ?? "").length;
      push({ kind: "heading", text: headingText, runs: oneRun(headingText, src) }, i, i + 1);
      i++;
      continue;
    }

    if (isSetextHeading(lines, i)) {
      const headingText = line.trim();
      const src = start(i) + line.length - line.trimStart().length;
      push({ kind: "heading", text: headingText, runs: oneRun(headingText, src) }, i, i + 2);
      i += 2;
      continue;
    }

    if (canStartBlock && HR.test(line)) {
      push({ kind: "rule" }, i, i + 1);
      i++;
      continue;
    }

    if (canStartBlock && QUOTE.test(line)) {
      let j = i;
      const body: InlineSource = { text: "", runs: [] };
      let markEnd = start(i);
      for (; j < lines.length; j++) {
        const m = QUOTE.exec(lines[j] as string);
        if (m === null) break;
        const src = start(j) + (m[1] as string).length + 1 + (m[2] as string).length;
        if (j === i) markEnd = src;
        else addSource(body, "\n", start(j) - 1);
        addSource(body, m[3] as string, src);
      }
      push({ kind: "quote", text: body.text, runs: body.runs, markAt: start(i), markEnd }, i, j);
      i = j;
      continue;
    }

    if (canStartBlock && (UL_ITEM.test(line) || OL_ITEM.test(line))) {
      let j = i;
      const items: ListItem[] = [];
      const ordered = OL_ITEM.test(line);
      for (; j < lines.length; j++) {
        const sourceLine = lines[j] as string;
        const m = ordered ? OL_ITEM.exec(sourceLine) : UL_ITEM.exec(sourceLine);
        if (m === null) break;
        // The last group runs to the end of the line, so its offset needs no group arithmetic.
        const body = m.at(-1) as string;
        const src = start(j) + sourceLine.length - body.length;
        items.push({
          indent: Math.floor((m[1] as string).length / 2),
          marker: ordered ? `${m[2]}.` : "•",
          text: body,
          runs: oneRun(body, src),
          markAt: start(j),
          markEnd: src,
        });
      }
      push({ kind: "list", items }, i, j);
      i = j;
      continue;
    }

    // Only a line with an unescaped pipe can start a table. Another line goes on to the paragraph rule.
    const header = hasUnescapedPipe(line) ? splitTableRow(line, start(i)) : [];
    const separator =
      header.length > 0 && i + 1 < lines.length ? splitTableRow(lines[i + 1] as string, start(i + 1)) : [];
    if (
      header.length > 0 &&
      header.length === separator.length &&
      separator.every((cell) => TABLE_RULE.test(cell.text))
    ) {
      let j = i + 2;
      while (j < lines.length && (lines[j] as string).trim() !== "" && !isBlockStart(lines[j] as string)) j++;
      const rows: TableCell[][] = [];
      for (let k = i; k < j; k++) if (k !== i + 1) rows.push(splitTableRow(lines[k] as string, start(k)));
      const align = separator.map((cell): Align => {
        const right = cell.text.endsWith(":");
        if (cell.text.startsWith(":")) return right ? "center" : "left";
        return right ? "right" : "left";
      });
      const sepAt = start(i + 1);
      const sepEnd = sepAt + (lines[i + 1] as string).length;
      push({ kind: "table", columns: header.length, rows, align, sepAt, sepEnd }, i, j);
      i = j;
      continue;
    }

    // A paragraph runs to a blank line or a new block. A line feed joins as one space and keeps the source length.
    let j = i;
    const body: InlineSource = { text: "", runs: [] };
    for (; j < lines.length; j++) {
      const l = lines[j] as string;
      if (l.trim() === "" || isBlockStart(l) || isSetextHeading(lines, j)) break;
      if (j > i) addSource(body, " ", start(j) - 1);
      addSource(body, l, start(j));
    }
    push({ kind: "paragraph", text: body.text, runs: body.runs }, i, j);
    i = j;
  }

  return blocks;
}

/** The cells of a table row. `base` is the source offset of the line, so a cell keeps its runs and its pipe. */
function splitTableRow(line: string, base: number): TableCell[] {
  let start = line.length - line.trimStart().length;
  let stop = start + line.trim().length;
  if (line[start] === "|") start++;
  if (stop > start && line[stop - 1] === "|" && !isEscaped(line, stop - 1)) stop--;
  const cells: TableCell[] = [];
  let from = start;
  for (let i = start; i <= stop; i++) {
    if (i === stop || (line[i] === "|" && !isEscaped(line, i))) {
      const cell: TableCell = tableCell(line, from, i, base);
      if (cells.length > 0) cell.pipe = base + from - 1;
      cells.push(cell);
      from = i + 1;
    }
  }
  return cells;
}

/** One cell without its edge spaces. An escaped pipe stays in the text, so `parseInline` resolves it. */
function tableCell(line: string, from: number, to: number, base: number): InlineSource {
  while (from < to && (line[from] === " " || line[from] === "\t")) from++;
  while (to > from && (line[to - 1] === " " || line[to - 1] === "\t")) to--;
  const text = line.slice(from, to);
  return { text, runs: oneRun(text, base + from) };
}

function isEscaped(text: string, index: number): boolean {
  let slashes = 0;
  for (let i = index - 1; i >= 0 && text[i] === "\\"; i--) slashes++;
  return slashes % 2 === 1;
}

const ESCAPABLE = "\\`*{}[]()#+-.!_>~|";
/** The characters that start an inline rule. Each is ASCII, so a scan of UTF-16 units never meets one in a pair. */
const INLINE_MARKER = /[\\`[*_]/g;

/** The emphasis group for a bold and an italic depth. */
function emphasisStyle(bold: boolean, italic: boolean): string | undefined {
  if (bold && italic) return STYLE.strongEmphasis;
  if (bold) return STYLE.strong;
  if (italic) return STYLE.emphasis;
  return undefined;
}

/** A piece of inline text with the UTF-16 range `at`, `len` of its source. */
interface Piece {
  text: string;
  style: string;
  at: number;
  len: number;
  link?: string;
}

type InlineNode =
  | { kind: "text"; text: string; at: number; len: number; link?: string }
  | { kind: "styled"; text: string; style: string; at: number; len: number; link?: string }
  | Delimiter;

interface Delimiter {
  kind: "delimiter";
  at: number;
  marker: string;
  count: number;
  canOpen: boolean;
  canClose: boolean;
  openStrong: number;
  closeStrong: number;
  openEmphasis: number;
  closeEmphasis: number;
}

/** A run of `marker` at `i`: its length, and whether it opens or closes emphasis by the CommonMark flanking rules. */
function scanDelimiters(text: string, i: number, marker: string) {
  let count = 0;
  while (text[i + count] === marker) count++;
  const before = i === 0 ? " " : codePointBefore(text, i);
  const after = i + count < text.length ? String.fromCodePoint(text.codePointAt(i + count) as number) : " ";
  const beforeSpace = SPACE.test(before);
  const afterSpace = SPACE.test(after);
  const beforePunct = PUNCT.test(before);
  const afterPunct = PUNCT.test(after);
  const left = !afterSpace && (!afterPunct || beforeSpace || beforePunct);
  const right = !beforeSpace && (!beforePunct || afterSpace || afterPunct);
  if (marker === "_")
    return { count, canOpen: left && (!right || beforePunct), canClose: right && (!left || afterPunct) };
  return { count, canOpen: left, canClose: right };
}

/** The code point that ends at the UTF-16 offset `at` of `text`, as a string. */
function codePointBefore(text: string, at: number): string {
  const low = text.charCodeAt(at - 1);
  const high = text.charCodeAt(at - 2);
  const pair = low >= 0xdc_00 && low <= 0xdf_ff && high >= 0xd8_00 && high <= 0xdb_ff;
  return text.slice(pair ? at - 2 : at - 1, at);
}

/** The closing backtick run of exactly `n`, so a shorter run inside stays literal. */
function closeCodeSpan(text: string, start: number, n: number): number {
  let j = text.indexOf("`", start);
  while (j >= 0) {
    let m = 0;
    while (text[j + m] === "`") m++;
    if (m === n) return j;
    j = text.indexOf("`", j + m);
  }
  return -1;
}

/** A `[label](target)` at `open`: the index of `]` and of the last `)`, or `undefined`. A target holds no space. */
function scanLink(text: string, open: number): { close: number; end: number } | undefined {
  let depth = 0;
  let close = -1;
  for (let j = open + 1; j < text.length; j++) {
    const c = text[j];
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
  if (close < 0 || text[close + 1] !== "(") return undefined;
  let paren = 1;
  for (let j = close + 2; j < text.length; j++) {
    const c = text[j] as string;
    if (c === "\\") {
      j++;
      continue;
    }
    if (SPACE.test(c)) return undefined;
    if (c === "(") paren++;
    else if (c === ")" && --paren === 0) return { close, end: j };
  }
  return undefined;
}

/**
 * The styled pieces of the inline text `text`. Code spans and links resolve first, then a delimiter stack folds the
 * emphasis. A link keeps its brackets and its target as `link` pieces, and its label shows its own inline markup.
 */
function parseInline(text: string, baseStyle: string = STYLE.text): Piece[] {
  // A piece range is UTF-16, and each marker is ASCII, so the parser walks UTF-16 units.
  const span = (from: number, to: number): { at: number; len: number } => ({ at: from, len: to - from });
  const nodes: InlineNode[] = [];
  const delimiters: number[] = [];

  let i = 0;
  while (i < text.length) {
    const c = text[i] as string;
    if (c === "\\" && i + 1 < text.length && ESCAPABLE.includes(text[i + 1] as string)) {
      nodes.push({ kind: "text", text: text[i + 1] as string, ...span(i, i + 2) });
      i += 2;
      continue;
    }
    if (c === "`") {
      let n = 1;
      while (text[i + n] === "`") n++;
      const close = closeCodeSpan(text, i + n, n);
      if (close >= 0) {
        let from = i + n;
        let to = close;
        let code = text.slice(from, to).replace(/[\r\n]/g, " ");
        if (code.length > 2 && code[0] === " " && code.at(-1) === " " && NOT_SPACE.test(code)) {
          code = code.slice(1, -1);
          from++;
          to--;
        }
        nodes.push({ kind: "styled", text: code, style: STYLE.code, ...span(from, to) });
        i = close + n;
        continue;
      }
      nodes.push({ kind: "text", text: "`".repeat(n), ...span(i, i + n) });
      i += n;
      continue;
    }
    if (c === "[") {
      const found = scanLink(text, i);
      if (found !== undefined) {
        const link = text.slice(found.close + 2, found.end);
        nodes.push({ kind: "styled", text: "[", style: STYLE.link, link, ...span(i, i + 1) });
        // The label is a verbatim slice of the parent, so a range inside it shifts by the label offset.
        for (const piece of parseInline(text.slice(i + 1, found.close), baseStyle)) {
          if (piece.text === "") continue;
          // An unstyled piece stays text, so an emphasis around the link reaches it.
          if (piece.style === baseStyle)
            nodes.push({ kind: "text", text: piece.text, at: i + 1 + piece.at, len: piece.len, link });
          else
            nodes.push({
              kind: "styled",
              text: piece.text,
              style: piece.style,
              at: i + 1 + piece.at,
              len: piece.len,
              link,
            });
        }
        const target = text.slice(found.close, found.end + 1);
        nodes.push({ kind: "styled", text: target, style: STYLE.link, link, ...span(found.close, found.end + 1) });
        i = found.end + 1;
        continue;
      }
    }
    if (c === "*" || c === "_") {
      const d = scanDelimiters(text, i, c);
      nodes.push({
        kind: "delimiter",
        at: i,
        marker: c,
        count: d.count,
        canOpen: d.canOpen,
        canClose: d.canClose,
        openStrong: 0,
        closeStrong: 0,
        openEmphasis: 0,
        closeEmphasis: 0,
      });
      delimiters.push(nodes.length - 1);
      i += d.count;
      continue;
    }
    // A run of plain characters is one node, because each rule above reads only its marker character.
    INLINE_MARKER.lastIndex = i + 1;
    const j = INLINE_MARKER.exec(text)?.index ?? text.length;
    nodes.push({ kind: "text", text: text.slice(i, j), ...span(i, j) });
    i = j;
  }

  foldEmphasis(nodes, delimiters);
  return flattenInline(nodes, baseStyle);
}

/** The delimiter stack: each closer matches the nearest fitting opener, and an unused delimiter stays literal. */
function foldEmphasis(nodes: readonly InlineNode[], delimiters: readonly number[]): void {
  for (let ci = 0; ci < delimiters.length; ci++) {
    const closer = nodes[delimiters[ci] as number] as Delimiter;
    if (!closer.canClose) continue;
    while (closer.count > 0) {
      let matched = false;
      for (let oi = ci - 1; oi >= 0; oi--) {
        const opener = nodes[delimiters[oi] as number] as Delimiter;
        if (opener.marker !== closer.marker || !opener.canOpen || opener.count === 0) continue;
        // The rule of three: a run that opens and closes matches only when the lengths allow it.
        const both = closer.canOpen || opener.canClose;
        if (both && (opener.count + closer.count) % 3 === 0 && !(opener.count % 3 === 0 && closer.count % 3 === 0))
          continue;
        const use = opener.count >= 2 && closer.count >= 2 ? 2 : 1;
        opener.count -= use;
        closer.count -= use;
        closer.at += use;
        if (use === 2) {
          opener.openStrong++;
          closer.closeStrong++;
        } else {
          opener.openEmphasis++;
          closer.closeEmphasis++;
        }
        matched = true;
        break;
      }
      if (!matched) break;
    }
  }
}

/** The pieces of the folded nodes. Two pieces join only while their source stays contiguous. */
function flattenInline(nodes: readonly InlineNode[], baseStyle: string): Piece[] {
  const out: Piece[] = [];
  let bold = 0;
  let italic = 0;
  const emit = (text: string, style: string, at: number, len: number, link: string | undefined): void => {
    if (text === "") return;
    const last = out.at(-1);
    const joins =
      last !== undefined &&
      last.style === style &&
      last.link === link &&
      last.at + last.len === at &&
      last.len === last.text.length &&
      len === text.length;
    if (joins) {
      last.text += text;
      last.len += len;
    } else out.push(link === undefined ? { text, style, at, len } : { text, style, at, len, link });
  };
  for (const n of nodes) {
    if (n.kind === "styled") emit(n.text, n.style, n.at, n.len, n.link);
    else if (n.kind === "delimiter") {
      bold -= n.closeStrong;
      italic -= n.closeEmphasis;
      if (n.count > 0)
        emit(n.marker.repeat(n.count), emphasisStyle(bold > 0, italic > 0) ?? baseStyle, n.at, n.count, undefined);
      bold += n.openStrong;
      italic += n.openEmphasis;
    } else {
      const plain = n.link === undefined ? baseStyle : STYLE.linkText;
      emit(n.text, emphasisStyle(bold > 0, italic > 0) ?? plain, n.at, n.len, n.link);
    }
  }
  return out.length > 0 ? out : [{ text: "", style: baseStyle, at: 0, len: 0 }];
}

/** The pieces on source offsets. Markup, such as an escape, makes a piece a replacement of its source. */
function resolveSegments(pieces: readonly Piece[], runs: readonly SourceRun[]): Part[] {
  const withLink = (part: Part, link: string | undefined): Part => (link === undefined ? part : { ...part, link });
  if (runs.length === 0) return pieces.map((p) => withLink({ text: p.text, style: p.style }, p.link));
  const out: Part[] = [];
  for (const p of pieces) {
    if (p.text.length === 0) out.push({ text: "", style: p.style });
    else if (p.len !== p.text.length) {
      const source = mapping("replacement", srcAt(runs, p.at, false), srcAt(runs, p.at + p.len - 1, true));
      out.push(withLink({ text: p.text, style: p.style, source }, p.link));
    } else {
      let k = 0;
      while (k < p.text.length) {
        const r = runFor(runs, p.at + k);
        const take = Math.min(p.text.length - k, Math.max(1, r.at + r.len - (p.at + k)));
        const src = r.src + (p.at + k - r.at);
        out.push(
          withLink(
            { text: p.text.slice(k, k + take), style: p.style, source: mapping("text", src, src + take) },
            p.link,
          ),
        );
        k += take;
      }
    }
  }
  return out;
}

function mapping(kind: SourceMapping["kind"], from: number, to: number): SourceMapping {
  return { kind, from, to };
}

/** A slice of a resolved part. A text source slices with it, and a replacement keeps its whole source. */
function sliceSegment(part: Part, from: number, to: number): Part {
  const out: Part = { text: part.text.slice(from, to), style: part.style };
  if (part.link !== undefined) out.link = part.link;
  if (part.source === undefined) return out;
  out.source =
    part.source.kind === "text" ? mapping("text", part.source.from + from, part.source.from + to) : part.source;
  return out;
}

/** Whether two neighbours join: their style and link match, and their text and source stay contiguous. */
function segmentsJoin(a: Part, b: Part): boolean {
  if (a.style !== b.style || a.link !== b.link) return false;
  if (a.source === undefined && b.source === undefined) return true;
  return a.source?.kind === "text" && b.source?.kind === "text" && a.source.to === b.source.from;
}

/** Add `part` to `parts`. It extends the last part when `segmentsJoin` allows, so a row holds few objects. */
function appendPart(parts: Part[], part: Part): void {
  const last = parts.at(-1);
  if (last !== undefined && segmentsJoin(last, part)) {
    last.text += part.text;
    if (last.source !== undefined && part.source !== undefined) {
      last.source = mapping("text", last.source.from, part.source.to);
    }
  } else parts.push(part);
}

interface WrapOptions {
  limit?: number;
  firstPrefix?: Part;
  restPrefix?: Part;
  emptyStyle?: string;
}

/** Printable ASCII with blanks: each character that is no blank is one cell. */
const ASCII_TEXT = /^[\x20-\x7e\t\n]*$/;

/** The offset of the first `character` in `text` from `from`, or the length of `text`. */
function indexOrEnd(text: string, character: string, from: number): number {
  const at = text.indexOf(character, from);
  return at < 0 ? text.length : at;
}

/** Whether the UTF-16 unit `code` is a space, a tab, or a line end. A wrap puts one space in place of a run of them. */
function isBlank(code: number): boolean {
  return code === 32 || code === 9 || code === 10;
}

/**
 * The rows of `segments` wrapped at `width`, at most `limit`. A word wider than the row breaks between graphemes.
 * A wrap at a space joins with " ". A break in a word joins with "". The last row joins with "\n". Two words on a row
 * have one space between them.
 */
function wrapSegments(segments: readonly Part[], width: number, options: WrapOptions = {}): Row[] {
  const limit = options.limit ?? Number.POSITIVE_INFINITY;
  if (limit === 0) return [];
  const first = options.firstPrefix;
  const rest = options.restPrefix;
  const firstWidth = first === undefined ? 0 : widthOf(first.text);
  const restWidth = rest === undefined ? 0 : widthOf(rest.text);
  const rows: Row[] = [];
  const available = (): number => Math.max(1, width - (rows.length === 0 ? firstWidth : restWidth));
  let line: Part[] = [];
  let lineWidth = 0;
  // The end of the row is a range of one segment that grows while the row stays contiguous in it, so a row slices each
  // segment once and not once for each word.
  let open: Part | undefined;
  let openFrom = 0;
  let openTo = 0;
  // The word that builds, as triples of segment index, start, and end, and its cells.
  const word: number[] = [];
  let wordWidth = 0;
  // The last blank run, as a segment index, a start, and an end: the space before the word that builds.
  let blankAt = -1;
  let blankFrom = 0;
  let blankTo = 0;

  const flush = (): void => {
    if (open !== undefined) appendPart(line, sliceSegment(open, openFrom, openTo));
    open = undefined;
  };
  const extend = (segment: Part, from: number, to: number): void => {
    // A replacement maps each piece to its whole source, so its pieces stay apart, as `appendPart` keeps them.
    if (open === segment && openTo === from && segment.source?.kind !== "replacement") {
      openTo = to;
      return;
    }
    flush();
    open = segment;
    openFrom = from;
    openTo = to;
  };
  const emit = (join: string): boolean => {
    flush();
    if (rows.length >= limit) return false;
    const prefix = rows.length === 0 ? first : rest;
    const segs = prefix === undefined ? line : [prefix, ...line];
    const rowWidth = lineWidth + (rows.length === 0 ? firstWidth : restWidth);
    rows.push({
      segments: segs.length > 0 ? segs : [{ text: "", style: options.emptyStyle ?? STYLE.text }],
      join,
      width: rowWidth,
    });
    line = [];
    lineWidth = 0;
    return rows.length < limit;
  };
  /** Put the space before the word. Only one space character keeps its source as it is. */
  const space = (): void => {
    const segment = segments[blankAt] as Part;
    if (blankTo - blankFrom === 1 && segment.text.charCodeAt(blankFrom) === 32) {
      extend(segment, blankFrom, blankTo);
      return;
    }
    flush();
    const run = sliceSegment(segment, blankFrom, blankTo);
    run.text = " ";
    if (blankTo - blankFrom > 1 && run.source !== undefined) {
      run.source = mapping("replacement", run.source.from, run.source.to);
    }
    appendPart(line, run);
  };
  const empty = (): boolean => line.length === 0 && open === undefined;
  /** Put the word on the row, or on the next rows. Return `false` when the rows reach `limit`. */
  const put = (): boolean => {
    if (rows.length >= limit) return false;
    if (!empty() && lineWidth + 1 + wordWidth > available() && !emit(" ")) return false;
    if (wordWidth > available()) {
      if (!empty() && !emit(" ")) return false;
      const parts: Part[] = [];
      for (let at = 0; at < word.length; at += 3) {
        parts.push(sliceSegment(segments[word[at] as number] as Part, word[at + 1] as number, word[at + 2] as number));
      }
      const broken = hardBreak(parts, available(), limit - rows.length + 1);
      for (let i = 0; i < broken.length; i++) {
        const piece = broken[i] as Row;
        line = piece.segments;
        lineWidth = piece.width ?? 0;
        if (i + 1 < broken.length && !emit("")) return false;
      }
      return rows.length < limit;
    }
    if (!empty()) {
      space();
      lineWidth += 1;
    }
    for (let at = 0; at < word.length; at += 3) {
      extend(segments[word[at] as number] as Part, word[at + 1] as number, word[at + 2] as number);
    }
    lineWidth += wordWidth;
    return true;
  };
  const place = (): boolean => {
    const placed = put();
    word.length = 0;
    wordWidth = 0;
    return placed;
  };

  read: for (const [index, segment] of segments.entries()) {
    const text = segment.text;
    // A native scan finds the end of each word, and printable ASCII needs no width call.
    const ascii = ASCII_TEXT.test(text);
    let nextSpace = -1;
    let nextTab = -1;
    let nextNewline = -1;
    let at = 0;
    while (at < text.length) {
      let end = at + 1;
      if (isBlank(text.charCodeAt(at))) {
        while (end < text.length && isBlank(text.charCodeAt(end))) end += 1;
        if (word.length > 0 && !place()) break read;
        blankAt = index;
        blankFrom = at;
        blankTo = end;
      } else {
        if (nextSpace < at) nextSpace = indexOrEnd(text, " ", at);
        if (nextTab < at) nextTab = indexOrEnd(text, "\t", at);
        if (nextNewline < at) nextNewline = indexOrEnd(text, "\n", at);
        end = Math.min(nextSpace, nextTab, nextNewline);
        word.push(index, at, end);
        wordWidth += ascii ? end - at : widthOf(text.slice(at, end));
      }
      at = end;
    }
  }
  if (word.length > 0) place();
  if (rows.length < limit) emit("\n");
  return rows;
}

/**
 * `pieces` broken into rows of `width` cells between graphemes, at most `limit` rows. A wider grapheme stays whole.
 * Each row joins with "". The caller sets the join of the last row.
 */
function hardBreak(pieces: readonly Part[], width: number, limit: number): Row[] {
  const out: Row[] = [];
  let segments: Part[] = [];
  let lineWidth = 0;
  const emit = (): boolean => {
    if (out.length >= limit) return false;
    if (segments.length > 0) out.push({ segments, join: "", width: lineWidth });
    segments = [];
    lineWidth = 0;
    return out.length < limit;
  };
  const append = (segment: Part, cells: number): void => {
    appendPart(segments, segment);
    lineWidth += cells;
  };
  for (const piece of pieces) {
    if (out.length >= limit) break;
    if (ASCII.test(piece.text)) {
      // Each character is one cell, so a row takes as many characters as it has cells left.
      let from = 0;
      while (from < piece.text.length) {
        if (segments.length > 0 && lineWidth >= width && !emit()) break;
        // A row of no cells still takes one character, as the grapheme path takes one grapheme.
        const take = Math.max(1, Math.min(piece.text.length - from, width - lineWidth));
        append(sliceSegment(piece, from, from + take), take);
        from += take;
        if (lineWidth >= width && !emit()) break;
      }
      continue;
    }
    const clusters = termGraphemes(piece.text);
    for (let k = 0; k < clusters.length; k += 3) {
      if (out.length >= limit) break;
      const from = clusters[k] as number;
      const cells = clusters[k + 2] as number;
      if (segments.length > 0 && lineWidth + cells > width && !emit()) break;
      append(sliceSegment(piece, from, from + (clusters[k + 1] as number)), cells);
      if (lineWidth >= width && !emit()) break;
    }
  }
  if (out.length < limit) emit();
  return out;
}

const TABLE_GAP = " │ ";

/** The width of each column: its widest cell. When the columns do not fit, wide columns shrink to a common cap of 3 or more. */
function columnWidths(cells: readonly Part[][][], available: number): number[] {
  const widths: number[] = [];
  for (const row of cells) {
    row.forEach((segments, c) => {
      const cellWidth = segments.reduce((n, s) => n + widthOf(s.text), 0);
      widths[c] = Math.max(widths[c] ?? 0, cellWidth);
    });
  }
  const total = widths.reduce((n, w) => n + w, 0);
  if (total <= available || widths.length === 0) return widths;

  const excess = total - available;
  const cost = (cap: number): number => widths.reduce((n, w) => n + Math.max(0, w - cap), 0);
  let low = 3;
  let high = Math.max(3, ...widths);
  while (low < high) {
    const cap = Math.floor((low + high) / 2);
    if (cost(cap) <= excess) high = cap;
    else low = cap + 1;
  }
  const cap = low;
  let remaining = excess - cost(cap);
  for (let c = 0; c < widths.length; c++) widths[c] = Math.min(widths[c] as number, cap);
  // The first columns at the common cap give up the cells that are still too many.
  if (cap > 3) {
    for (let c = 0; c < widths.length && remaining > 0; c++) {
      if (widths[c] !== cap) continue;
      widths[c] = cap - 1;
      remaining--;
    }
  }
  return widths;
}

function plainRow(text: string, style: string = STYLE.text): Row {
  return { segments: [{ text, style }], join: "\n" };
}

/**
 * The rows of `block` at `width`, at most `limit`. A replacement segment, such as a list mark, maps to the markup that
 * it stands for. The last row joins with "\n".
 */
function renderBlock(block: Block, width: number, limit = Number.POSITIVE_INFINITY): Row[] {
  switch (block.kind) {
    case "heading": {
      const segments = resolveSegments(parseInline(block.text, STYLE.heading), block.runs);
      return wrapSegments(
        segments.map((s) => ({ ...s, style: s.link === undefined ? STYLE.heading : s.style })),
        width,
        { emptyStyle: STYLE.heading, limit },
      );
    }
    case "paragraph":
      return wrapSegments(resolveSegments(parseInline(block.text), block.runs), width, { limit });
    case "code": {
      const rows: Row[] = [];
      for (let k = 0; k < block.lines.length && rows.length < limit; k++) {
        const at = block.lineAt[k] as number;
        const text = block.lines[k] as string;
        const parts = hardBreak(
          [{ text, style: STYLE.codeBlock, source: mapping("text", at, at + text.length) }],
          width,
          limit - rows.length,
        );
        if (parts.length === 0) rows.push(plainRow("", STYLE.codeBlock));
        // A limit can cut the line, and then its last shown part still joins with "".
        const shown = parts.reduce((length, part) => length + part.segments.reduce((n, s) => n + s.text.length, 0), 0);
        for (const [index, part] of parts.entries()) {
          if (rows.length >= limit) break;
          const end = index + 1 === parts.length && shown === text.length;
          rows.push({ segments: part.segments, join: end ? "\n" : "" });
        }
      }
      if (rows.length === 0 && limit > 0) rows.push(plainRow("", STYLE.codeBlock));
      return rows;
    }
    case "quote": {
      const source = mapping("replacement", block.markAt, block.markEnd);
      const bar: Part = { text: "▏ ", style: STYLE.quote, source, copy: false };
      const segments = resolveSegments(parseInline(block.text, STYLE.quote), block.runs);
      return wrapSegments(segments, width, {
        firstPrefix: bar,
        restPrefix: { text: "▏ ", style: STYLE.quote, copy: false },
        emptyStyle: STYLE.quote,
        limit,
      });
    }
    case "rule": {
      const source = mapping("replacement", block.at, block.end);
      const rule: Part = { text: "─".repeat(Math.max(1, width)), style: STYLE.rule, source };
      return limit > 0 ? [{ segments: [rule], join: "\n" }] : [];
    }
    case "list": {
      const rows: Row[] = [];
      for (const item of block.items) {
        if (rows.length >= limit) break;
        const pad = "  ".repeat(item.indent);
        const source = mapping("replacement", item.markAt, item.markEnd);
        const mark: Part = { text: `${pad}${item.marker} `, style: STYLE.listMark, source };
        const segments = resolveSegments(parseInline(item.text), item.runs);
        const restPrefix: Part = { text: `${pad}  `, style: STYLE.listMark, copy: false };
        rows.push(...wrapSegments(segments, width, { firstPrefix: mark, restPrefix, limit: limit - rows.length }));
      }
      return rows;
    }
    case "table": {
      // Cells line up in columns. The widest column shrinks first, and a long cell wraps inside its own column.
      // A gap between two cells stands for the source pipe between them, when the row has one.
      const pipes = block.rows.map((source) => source.map((cell) => cell.pipe));
      const cells = block.rows.map((source) => {
        const row: TableCell[] = source.slice(0, block.columns);
        while (row.length < block.columns) row.push({ text: "", runs: [] });
        return row.map((cell) => resolveSegments(parseInline(cell.text), cell.runs));
      });
      const gap = widthOf(TABLE_GAP);
      const widths = columnWidths(cells, Math.max(1, width - gap * (block.columns - 1)));
      const rows: Row[] = [];
      for (let r = 0; r < cells.length && rows.length < limit; r++) {
        const row = cells[r] as Part[][];
        const lines = row.map((segments, c) =>
          wrapSegments(segments, widths[c] as number, { limit: limit - rows.length }),
        );
        const height = Math.max(...lines.map((l) => l.length));
        for (let k = 0; k < height && rows.length < limit; k++) {
          const segments: Part[] = [];
          for (let c = 0; c < row.length; c++) {
            const pipe = pipes[r]?.[c];
            if (c > 0) {
              const source = pipe === undefined ? undefined : mapping("replacement", pipe, pipe + 1);
              segments.push(
                source === undefined
                  ? { text: TABLE_GAP, style: STYLE.tableBorder }
                  : { text: TABLE_GAP, style: STYLE.tableBorder, source },
              );
            }
            const cell = lines[c]?.[k];
            const pad = (widths[c] as number) - (cell?.width ?? 0);
            const align = block.align[c] ?? "left";
            const before = align === "right" ? pad : align === "center" ? Math.floor(pad / 2) : 0;
            // The last column has no padding after its text, so a copied row ends at its text.
            const after = c + 1 < row.length ? pad - before : 0;
            if (before > 0) segments.push({ text: " ".repeat(before), style: STYLE.text, copy: false });
            if (cell !== undefined) segments.push(...cell.segments);
            if (after > 0) segments.push({ text: " ".repeat(after), style: STYLE.text, copy: false });
          }
          rows.push({ segments, join: "\n" });
        }
        if (r === 0 && rows.length < limit) {
          const rule = widths.map((w) => "─".repeat(w)).join("─┼─");
          const source = mapping("replacement", block.sepAt, block.sepEnd);
          rows.push({ segments: [{ text: rule, style: STYLE.tableBorder, source }], join: "\n" });
        }
      }
      return rows;
    }
  }
}

/** `text` with "\r\n" and "\r" as "\n". */
function normalized(text: string): string {
  return text.includes("\r") ? text.replace(/\r\n?/g, "\n") : text;
}

interface CacheEntry {
  end: number;
  width: number;
  rows: readonly TextRow[];
}

/** The parse of a text that changes. While the source only grows, an offset and an end name one text. */
interface Stream {
  /** The source text that the last parse read, so an append never slices the whole source. */
  tail: string;
  readonly blocks: Block[];
  readonly cache: Map<number, CacheEntry>;
}

function newStream(): Stream {
  return { tail: "", blocks: [], cache: new Map() };
}

/**
 * A Markdown text as styled rows. A text that changes keeps its blocks and the rows of its closed blocks, so a stream
 * parses again only its last two blocks. A text that stays keeps only its source, and each read parses it. Each source
 * offset indexes `source()`. The cache shares the rows, so they are read-only.
 */
export class Markdown {
  #source = "";
  /** The state of a text that changed after its first value. */
  #stream: Stream | undefined;
  /** The input ended in "\r", so a "\n" at the start of the next fragment belongs to that line break. */
  #carriageReturn = false;

  constructor(text = "") {
    this.setText(text);
  }

  /** Replace the source, and return `true` when it changed. A text that extends the old one keeps its first blocks. */
  setText(text: string): boolean {
    if (typeof text !== "string") throw new TypeError("a Markdown text is a string");
    this.#carriageReturn = text.endsWith("\r");
    const source = normalized(text);
    if (source === this.#source) return false;
    if (!source.startsWith(this.#source)) this.#stream = newStream();
    else if (this.#source !== "") this.#stream ??= newStream();
    this.#source = source;
    this.#parse(source);
    return true;
  }

  /** Add `fragment` at the end of the source. A "\r\n" split between two fragments is one line break. */
  append(fragment: string): void {
    if (typeof fragment !== "string") throw new TypeError("a Markdown fragment is a string");
    const raw = this.#carriageReturn && fragment.startsWith("\n") ? fragment.slice(1) : fragment;
    if (fragment !== "") this.#carriageReturn = raw.endsWith("\r");
    if (raw === "") return;
    const added = normalized(raw);
    if (this.#source !== "") this.#stream ??= newStream();
    this.#source += added;
    this.#parse((this.#stream?.tail ?? "") + added);
  }

  /** The source with each "\r\n" and "\r" as "\n". Each source offset indexes this text. */
  source(): string {
    return this.#source;
  }

  /** The kind and the source range of each block, in order. A code block has its fence language, or "". */
  blocks(): readonly MarkdownBlock[] {
    return this.#parsed().map(
      (block): MarkdownBlock =>
        block.kind === "code"
          ? { kind: block.kind, from: block.at, to: block.end, language: block.language }
          : { kind: block.kind, from: block.at, to: block.end },
    );
  }

  /**
   * The rows at `width`, at most `limit`, with an empty row between two blocks. When the rows end before `limit`, the
   * last row of the text joins with "".
   */
  rows(width: number, limit = Number.POSITIVE_INFINITY): readonly TextRow[] {
    const most = Number.isFinite(limit) ? Math.max(0, Math.floor(limit)) : Number.POSITIVE_INFINITY;
    const out: TextRow[] = [];
    for (const [index, block] of this.#parsed().entries()) {
      if (out.length >= most) break;
      if (index > 0) out.push(plainRow(""));
      out.push(...this.#blockRows(block, width, most - out.length));
    }
    const last = out.at(-1);
    if (out.length < most && last !== undefined) out[out.length - 1] = { ...last, join: "" };
    return out;
  }

  #parsed(): readonly Block[] {
    return this.#stream?.blocks ?? segment(this.#source, 0);
  }

  /** Parse again from the block before the last one. `text` is the end of the source, which holds it already. */
  #parse(text: string): void {
    const stream = this.#stream;
    if (stream === undefined) return;
    const source = this.#source;
    const at = source.length - text.length;
    const keep = Math.max(0, stream.blocks.length - 2);
    const from = keep > 0 ? (stream.blocks[keep] as Block).at : 0;
    // A tail of fewer than two blocks starts before `at`, so only then the parse slices the whole source.
    const tail = from >= at ? text.slice(from - at) : source.slice(from);
    const blocks = segment(tail, from);
    stream.blocks.length = keep;
    stream.blocks.push(...blocks);
    stream.tail = tail;
  }

  /** The rows of `block`. A stream caches them by the offset of the block, and a new end tells that the block grew. */
  #blockRows(block: Block, width: number, limit: number): readonly TextRow[] {
    const stream = this.#stream;
    if (stream === undefined) return renderBlock(block, width, limit);
    const entry = stream.cache.get(block.at);
    const fresh = entry !== undefined && entry.end === block.end && entry.width === width;
    if (limit !== Number.POSITIVE_INFINITY) {
      return fresh ? entry.rows.slice(0, limit) : renderBlock(block, width, limit);
    }
    if (fresh) return entry.rows;
    const rows = renderBlock(block, width);
    stream.cache.set(block.at, { end: block.end, width, rows });
    return rows;
  }
}
