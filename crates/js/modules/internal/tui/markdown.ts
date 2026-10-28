/**
 * Markdown to styled rows. A stream parses again only its last two blocks, and each closed
 * block keeps its rows for its newest width. A segment with a source range maps back to its source; a layout segment,
 * such as a space between words, has none. A link keeps its brackets and its target, so the user can copy the target.
 * The style groups are `markdown.*`, and a plugin sets their look.
 */
import { termGraphemes, termMeasure } from "yuke:internal/native";

/** Printable ASCII: each character is one cell and one grapheme, so its width needs no native call. */
const ASCII = /^[\x20-\x7e]*$/;

/** The width of `text` in cells. */
function widthOf(text: string): number {
  return ASCII.test(text) ? text.length : termMeasure(text);
}

/** One styled piece of a row. */
export interface Segment {
  text: string;
  /** The style group. */
  style: string;
  /** The source range of the piece, when it has one. */
  src?: number;
  srcEnd?: number;
  /** The piece stands for markup that it does not show, such as a list mark. */
  mark?: boolean;
  /** The target of the link that the piece belongs to. */
  link?: string;
}

/** One row of the rendered text. `width` is its width in cells, when the renderer counted it. */
export interface Row {
  segments: Segment[];
  width?: number;
}

/** The kind and the source range of one block. */
export interface BlockSummary {
  readonly kind: Block["kind"];
  readonly at: number;
  readonly end: number;
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
  raw: string;
  /** The last block can still grow while a stream appends, so it has no cache. */
  open?: boolean;
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
    | { kind: "code"; lang: string; lines: string[]; lineAt: number[] }
    | { kind: "quote"; text: string; runs: SourceRun[]; markAt: number; markEnd: number }
    | { kind: "hr" }
    | { kind: "list"; ordered: boolean; items: ListItem[] }
    | { kind: "table"; columns: number; rows: InlineSource[][]; align: Align[]; sepAt: number; sepEnd: number }
  );

/** The fields of a parsed block, without the fields of `BlockBase` that `segment` adds. */
type Parsed = Block extends infer B ? (B extends Block ? Omit<B, keyof BlockBase> : never) : never;

interface Fence {
  marker: string;
  length: number;
  indent: number;
  lang: string;
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
  return { marker, length: marks.length, indent: (m[1] as string).length, lang: info.trim() };
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
    // Each line but the last ends in "\n", so the source slice is the joined lines.
    const end = start(last) - 1;
    blocks.push({ ...parsed, at, end, raw: text.slice(at - base, end - base) } as Block);
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
      push({ kind: "code", lang: fence.lang, lines: body, lineAt: bodyAt }, i, to);
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
      push({ kind: "hr" }, i, i + 1);
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
      push({ kind: "list", ordered, items }, i, j);
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
      const rows: InlineSource[][] = [];
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

  // The last block can still grow while a stream appends, so it never enters the cache.
  const last = blocks.at(-1);
  if (last !== undefined) last.open = true;
  return blocks;
}

/** The cells of a table row. `base` is the source offset of the line, so a cell keeps its runs. */
function splitTableRow(line: string, base: number): InlineSource[] {
  let start = line.length - line.trimStart().length;
  let stop = start + line.trim().length;
  if (line[start] === "|") start++;
  if (stop > start && line[stop - 1] === "|" && !isEscaped(line, stop - 1)) stop--;
  const cells: InlineSource[] = [];
  let from = start;
  for (let i = start; i <= stop; i++) {
    if (i === stop || (line[i] === "|" && !isEscaped(line, i))) {
      cells.push(tableCell(line, from, i, base));
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
const INLINE_MARKERS = new Set(["\\", "`", "[", "*", "_"]);

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
  text: string;
  at: number;
  len: number;
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
function scanDelimiters(cps: readonly string[], i: number, marker: string) {
  let count = 0;
  while (cps[i + count] === marker) count++;
  const before = i === 0 ? " " : (cps[i - 1] as string);
  const after = cps[i + count] ?? " ";
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

/** The closing backtick run of exactly `n`, so a shorter run inside stays literal. */
function closeCodeSpan(cps: readonly string[], start: number, n: number): number {
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

/** A `[label](target)` at `open`: the index of `]` and of the last `)`, or `undefined`. A target holds no space. */
function scanLink(cps: readonly string[], open: number): { close: number; end: number } | undefined {
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
  if (close < 0 || cps[close + 1] !== "(") return undefined;
  let paren = 1;
  for (let j = close + 2; j < cps.length; j++) {
    const c = cps[j] as string;
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
  const cps = Array.from(text);
  // The parser walks code points, but a piece range is UTF-16, so it keeps both indexes.
  const units: number[] = [];
  let unit = 0;
  for (const cp of cps) {
    units.push(unit);
    unit += cp.length;
  }
  units.push(unit);
  const at = (k: number): number => units[k] as number;
  const span = (from: number, to: number): { at: number; len: number } => ({ at: at(from), len: at(to) - at(from) });
  const nodes: InlineNode[] = [];
  const delimiters: number[] = [];

  let i = 0;
  while (i < cps.length) {
    const c = cps[i] as string;
    if (c === "\\" && i + 1 < cps.length && ESCAPABLE.includes(cps[i + 1] as string)) {
      nodes.push({ kind: "text", text: cps[i + 1] as string, ...span(i, i + 2) });
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
        let code = cps
          .slice(from, to)
          .join("")
          .replace(/[\r\n]/g, " ");
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
      const found = scanLink(cps, i);
      if (found !== undefined) {
        const link = cps.slice(found.close + 2, found.end).join("");
        nodes.push({ kind: "styled", text: "[", style: STYLE.link, link, ...span(i, i + 1) });
        // The label is a verbatim slice of the parent, so a range inside it shifts by the label offset.
        const shift = at(i + 1);
        for (const piece of parseInline(cps.slice(i + 1, found.close).join(""), baseStyle)) {
          if (piece.text === "") continue;
          // An unstyled piece stays text, so an emphasis around the link reaches it.
          if (piece.style === baseStyle)
            nodes.push({ kind: "text", text: piece.text, at: shift + piece.at, len: piece.len, link });
          else
            nodes.push({
              kind: "styled",
              text: piece.text,
              style: piece.style,
              at: shift + piece.at,
              len: piece.len,
              link,
            });
        }
        const target = cps.slice(found.close, found.end + 1).join("");
        nodes.push({ kind: "styled", text: target, style: STYLE.link, link, ...span(found.close, found.end + 1) });
        i = found.end + 1;
        continue;
      }
    }
    if (c === "*" || c === "_") {
      const d = scanDelimiters(cps, i, c);
      nodes.push({
        kind: "delimiter",
        text: c.repeat(d.count),
        ...span(i, i + d.count),
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
    let j = i + 1;
    while (j < cps.length && !INLINE_MARKERS.has(cps[j] as string)) j++;
    nodes.push({ kind: "text", text: cps.slice(i, j).join(""), ...span(i, j) });
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

/** The pieces on source offsets. Markup, such as an escape, can make a piece not linear. */
function resolveSegments(pieces: readonly Piece[], runs: readonly SourceRun[]): Segment[] {
  const withLink = (segment: Segment, link: string | undefined): Segment =>
    link === undefined ? segment : { ...segment, link };
  if (runs.length === 0) return pieces.map((p) => withLink({ text: p.text, style: p.style }, p.link));
  const out: Segment[] = [];
  for (const p of pieces) {
    if (p.text.length === 0) out.push({ text: "", style: p.style });
    else if (p.len !== p.text.length) {
      out.push(
        withLink(
          { text: p.text, style: p.style, src: srcAt(runs, p.at, false), srcEnd: srcAt(runs, p.at + p.len - 1, true) },
          p.link,
        ),
      );
    } else {
      let k = 0;
      while (k < p.text.length) {
        const r = runFor(runs, p.at + k);
        const take = Math.min(p.text.length - k, Math.max(1, r.at + r.len - (p.at + k)));
        const src = r.src + (p.at + k - r.at);
        out.push(withLink({ text: p.text.slice(k, k + take), style: p.style, src, srcEnd: src + take }, p.link));
        k += take;
      }
    }
  }
  return out;
}

/** One source character for each shown character, so an offset survives a slice. A mark and an escape are not linear. */
function isLinear(segment: Segment): boolean {
  return (
    segment.src !== undefined &&
    segment.mark !== true &&
    (segment.srcEnd as number) - segment.src === segment.text.length
  );
}

/** A slice of a resolved segment. A segment that is not linear keeps its whole source span. */
function sliceSegment(segment: Segment, from: number, to: number): Segment {
  const out: Segment = { text: segment.text.slice(from, to), style: segment.style };
  if (segment.link !== undefined) out.link = segment.link;
  if (segment.src === undefined) return out;
  if (!isLinear(segment)) {
    out.src = segment.src;
    out.srcEnd = segment.srcEnd as number;
    if (segment.mark === true) out.mark = true;
    return out;
  }
  out.src = segment.src + from;
  out.srcEnd = segment.src + to;
  return out;
}

/** Whether two neighbours join: their style and link match, and their text and source stay contiguous. */
function segmentsJoin(a: Segment, b: Segment): boolean {
  if (a.style !== b.style || a.link !== b.link) return false;
  if (a.src === undefined && b.src === undefined) return true;
  return a.srcEnd === b.src && isLinear(a) && isLinear(b);
}

interface Word {
  pieces: Segment[];
  width: number;
  /** The space before the word, with the style and the link of the blank run that it stands for. */
  space: Segment | undefined;
}

interface WrapOptions {
  limit?: number;
  firstPrefix?: Segment;
  restPrefix?: Segment;
  emptyStyle?: string;
}

/** The rows of `segments` wrapped at `width`, at most `limit`. A word wider than the row breaks between graphemes. */
function wrapSegments(segments: readonly Segment[], width: number, options: WrapOptions = {}): Row[] {
  const limit = options.limit ?? Number.POSITIVE_INFINITY;
  if (limit === 0) return [];
  const first = options.firstPrefix;
  const rest = options.restPrefix;
  const firstWidth = first === undefined ? 0 : widthOf(first.text);
  const restWidth = rest === undefined ? 0 : widthOf(rest.text);
  const rows: Row[] = [];
  const available = (): number => Math.max(1, width - (rows.length === 0 ? firstWidth : restWidth));
  const spaceWidth = 1;
  let line: Segment[] = [];
  let lineWidth = 0;

  const emit = (): boolean => {
    if (rows.length >= limit) return false;
    const prefix = rows.length === 0 ? first : rest;
    const segs = prefix === undefined ? line.slice() : [prefix, ...line];
    const rowWidth = lineWidth + (rows.length === 0 ? firstWidth : restWidth);
    rows.push({
      segments: segs.length > 0 ? segs : [{ text: "", style: options.emptyStyle ?? STYLE.text }],
      width: rowWidth,
    });
    line = [];
    lineWidth = 0;
    return rows.length < limit;
  };

  for (const word of segmentsToWords(segments)) {
    if (rows.length >= limit) break;
    if (line.length > 0 && lineWidth + spaceWidth + word.width > available() && !emit()) break;
    if (word.width > available()) {
      if (line.length > 0 && !emit()) break;
      const broken = hardBreak(word.pieces, available(), limit - rows.length + 1);
      for (let i = 0; i < broken.length; i++) {
        const piece = broken[i] as Row;
        line = piece.segments;
        lineWidth = piece.width ?? 0;
        if (i + 1 < broken.length && !emit()) break;
      }
      if (rows.length >= limit) break;
      continue;
    }
    if (line.length > 0) {
      line.push({ ...(word.space ?? { text: " ", style: STYLE.text }) });
      lineWidth += spaceWidth;
    }
    line.push(...word.pieces);
    lineWidth += word.width;
  }
  if (rows.length < limit) emit();
  return rows;
}

/** A blank run or a word, so a wrap walks a segment in runs and not in characters. */
const RUNS = /[ \t\n]+|[^ \t\n]+/g;

/** The words of `segments`, split at each blank run with their source offsets. A wrap puts one space between words. */
function segmentsToWords(segments: readonly Segment[]): Word[] {
  const words: Word[] = [];
  let current: Word | undefined;
  let space: Segment | undefined;
  for (const segment of segments) {
    for (const m of segment.text.matchAll(RUNS)) {
      const run = m[0];
      if (run[0] === " " || run[0] === "\t" || run[0] === "\n") {
        if (current !== undefined) words.push(current);
        current = undefined;
        space = { text: " ", style: segment.style };
        if (segment.link !== undefined) space.link = segment.link;
        continue;
      }
      if (current === undefined) {
        current = { pieces: [], width: 0, space };
        space = undefined;
      }
      const piece = sliceSegment(segment, m.index, m.index + run.length);
      current.pieces.push(piece);
      current.width += widthOf(piece.text);
    }
  }
  if (current !== undefined) words.push(current);
  return words;
}

/** `pieces` broken into rows of `width` cells between graphemes, at most `limit` rows. A wider grapheme stays whole. */
function hardBreak(pieces: readonly Segment[], width: number, limit: number): Row[] {
  const out: Row[] = [];
  let segments: Segment[] = [];
  let lineWidth = 0;
  const emit = (): boolean => {
    if (out.length >= limit) return false;
    if (segments.length > 0) out.push({ segments, width: lineWidth });
    segments = [];
    lineWidth = 0;
    return out.length < limit;
  };
  const append = (segment: Segment, cells: number): void => {
    const last = segments.at(-1);
    if (last !== undefined && segmentsJoin(last, segment)) {
      last.text += segment.text;
      if (last.src !== undefined) last.srcEnd = segment.srcEnd as number;
    } else segments.push(segment);
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
function columnWidths(cells: readonly Segment[][][], available: number): number[] {
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
  return { segments: [{ text, style }] };
}

/** The rows of `block` at `width`, at most `limit`. A mark carries the span of the markup that it hides. */
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
          [{ text, style: STYLE.codeBlock, src: at, srcEnd: at + text.length }],
          width,
          limit - rows.length,
        );
        if (parts.length === 0) rows.push(plainRow("", STYLE.codeBlock));
        for (const part of parts) {
          if (rows.length >= limit) break;
          rows.push({ segments: part.segments });
        }
      }
      if (rows.length === 0 && limit > 0) rows.push(plainRow("", STYLE.codeBlock));
      return rows;
    }
    case "quote": {
      const bar: Segment = { text: "▏ ", style: STYLE.quote, src: block.markAt, srcEnd: block.markEnd, mark: true };
      const segments = resolveSegments(parseInline(block.text, STYLE.quote), block.runs);
      return wrapSegments(segments, width, {
        firstPrefix: bar,
        restPrefix: { text: "▏ ", style: STYLE.quote },
        emptyStyle: STYLE.quote,
        limit,
      });
    }
    case "hr": {
      const rule: Segment = {
        text: "─".repeat(Math.max(1, width)),
        style: STYLE.rule,
        src: block.at,
        srcEnd: block.end,
        mark: true,
      };
      return limit > 0 ? [{ segments: [rule] }] : [];
    }
    case "list": {
      const rows: Row[] = [];
      for (const item of block.items) {
        if (rows.length >= limit) break;
        const pad = "  ".repeat(item.indent);
        const mark: Segment = {
          text: `${pad}${item.marker} `,
          style: STYLE.listMark,
          src: item.markAt,
          srcEnd: item.markEnd,
          mark: true,
        };
        const segments = resolveSegments(parseInline(item.text), item.runs);
        const restPrefix: Segment = { text: `${pad}  `, style: STYLE.listMark };
        rows.push(...wrapSegments(segments, width, { firstPrefix: mark, restPrefix, limit: limit - rows.length }));
      }
      return rows;
    }
    case "table": {
      // Cells line up in columns. The widest column shrinks first, and a long cell wraps inside its own column.
      const cells = block.rows.map((source) => {
        const row = source.slice(0, block.columns);
        while (row.length < block.columns) row.push({ text: "", runs: [] });
        return row.map((cell) => resolveSegments(parseInline(cell.text), cell.runs));
      });
      const gap = widthOf(TABLE_GAP);
      const widths = columnWidths(cells, Math.max(1, width - gap * (block.columns - 1)));
      const rows: Row[] = [];
      for (let r = 0; r < cells.length && rows.length < limit; r++) {
        const row = cells[r] as Segment[][];
        const lines = row.map((segments, c) =>
          wrapSegments(segments, widths[c] as number, { limit: limit - rows.length }),
        );
        const height = Math.max(...lines.map((l) => l.length));
        for (let k = 0; k < height && rows.length < limit; k++) {
          const segments: Segment[] = [];
          for (let c = 0; c < row.length; c++) {
            if (c > 0) segments.push({ text: TABLE_GAP, style: STYLE.tableBorder });
            const cell = lines[c]?.[k];
            const pad = (widths[c] as number) - (cell?.width ?? 0);
            const align = block.align[c] ?? "left";
            const before = align === "right" ? pad : align === "center" ? Math.floor(pad / 2) : 0;
            // The last column has no padding after its text, so a copied row ends at its text.
            const after = c + 1 < row.length ? pad - before : 0;
            if (before > 0) segments.push({ text: " ".repeat(before), style: STYLE.text });
            if (cell !== undefined) segments.push(...cell.segments);
            if (after > 0) segments.push({ text: " ".repeat(after), style: STYLE.text });
          }
          rows.push({ segments });
        }
        if (r === 0 && rows.length < limit) {
          const rule = widths.map((w) => "─".repeat(w)).join("─┼─");
          rows.push({
            segments: [{ text: rule, style: STYLE.tableBorder, src: block.sepAt, srcEnd: block.sepEnd, mark: true }],
          });
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
  raw: string;
  width: number;
  rows: Row[];
}

/**
 * A Markdown text as styled rows. A text that extends the old one parses again only its last two blocks, and another
 * text parses from the start. A segment offset indexes `source()`.
 */
export class Markdown {
  #source: string | undefined;
  /** The source text that the last parse read, so an append never slices the whole source. */
  #tail = "";
  /** The raw input ended in "\r", so a "\n" at the start of the next fragment belongs to that line break. */
  #carriageReturn = false;
  /** The raw input has no "\r", so the source is that input itself. */
  #raw = true;
  readonly #blocks: Block[] = [];
  readonly #cache = new Map<number, CacheEntry>();

  /** Replace the source, and return `true` when it changed. A text that extends the old one keeps its first blocks. */
  setText(text: string): boolean {
    this.#carriageReturn = text.endsWith("\r");
    this.#raw = !text.includes("\r");
    const source = normalized(text);
    if (source === this.#source) return false;
    if (this.#source === undefined || !source.startsWith(this.#source)) {
      this.#cache.clear();
      this.#blocks.length = 0;
    }
    this.#source = source;
    this.#parse(source);
    return true;
  }

  /** Add `fragment` at the end of the source. `text` is the whole raw input after the append. */
  append(fragment: string, text: string): void {
    const raw = this.#carriageReturn && fragment.startsWith("\n") ? fragment.slice(1) : fragment;
    if (fragment !== "") this.#carriageReturn = raw.endsWith("\r");
    if (raw === "") return;
    this.#raw = this.#raw && !raw.includes("\r");
    const added = this.#raw ? raw : normalized(raw);
    this.#source = this.#raw ? text : (this.#source ?? "") + added;
    this.#parse(this.#tail + added);
  }

  /** The source after the line break change. Each segment offset indexes this text. */
  source(): string {
    return this.#source ?? "";
  }

  /** The kind and the source range of each block, in order. */
  blocks(): BlockSummary[] {
    return this.#blocks.map((b) => ({ kind: b.kind, at: b.at, end: b.end }));
  }

  /**
   * The rows at `width`, at most `limit`, with an empty row between two blocks. The cache shares the rows, so a caller
   * must not change them.
   */
  rows(width: number, limit = Number.POSITIVE_INFINITY): readonly Row[] {
    const most = Number.isFinite(limit) ? Math.max(0, Math.floor(limit)) : Number.POSITIVE_INFINITY;
    const out: Row[] = [];
    for (const [index, block] of this.#blocks.entries()) {
      if (index > 0 && out.length < most) out.push(plainRow(""));
      for (const row of this.#blockRows(block, width, most - out.length)) {
        if (out.length >= most) break;
        out.push(row);
      }
      if (out.length >= most) break;
    }
    return out;
  }

  /** Parse again from the block before the last one. `text` is the end of the source, which holds it already. */
  #parse(text: string): void {
    const source = this.#source ?? "";
    const at = source.length - text.length;
    const keep = Math.max(0, this.#blocks.length - 2);
    const from = keep > 0 ? (this.#blocks[keep] as Block).at : 0;
    // A tail of fewer than two blocks starts before `at`, so only then the parse slices the whole source.
    const tail = from >= at ? text.slice(from - at) : source.slice(from);
    const blocks = segment(tail, from);
    this.#blocks.length = keep;
    this.#blocks.push(...blocks);
    this.#tail = tail;
  }

  /** The rows of `block`. The cache keys on the block offset, and `raw` tells a change under one offset. */
  #blockRows(block: Block, width: number, limit: number): Row[] {
    if (block.open === true) return renderBlock(block, width, limit);
    const entry = this.#cache.get(block.at);
    const fresh = entry !== undefined && entry.raw === block.raw && entry.width === width;
    if (limit !== Number.POSITIVE_INFINITY)
      return fresh ? entry.rows.slice(0, limit) : renderBlock(block, width, limit);
    if (fresh) return entry.rows;
    const rows = renderBlock(block, width);
    this.#cache.set(block.at, { raw: block.raw, width, rows });
    return rows;
  }
}
