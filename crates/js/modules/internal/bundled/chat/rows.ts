/**
 * The rows of the chat transcript. The module has the style groups, the gap before each item, and the indent of each
 * row. It wraps a text with a style and a link for each range of its source.
 */

import { measure, type Segment, type TextItem, type TextRow, type TextSection, wrap } from "yuke:tui";

/** The style groups of the chat. Each one gets its default look from `STYLES`. */
export const STYLE = {
  user: "chat.user",
  meta: "chat.meta",
  title: "chat.title",
  subject: "chat.subject",
  thought: "chat.thought",
  error: "chat.error",
  hint: "chat.hint",
  diffHeader: "chat.diff.header",
  diffHunk: "chat.diff.hunk",
  diffAdd: "chat.diff.add",
  diffDelete: "chat.diff.delete",
} as const;

/** The default look of each style group. A later `tui.styles.set` of a theme changes it. */
export const STYLES = {
  [STYLE.user]: { fg: "surfaceFg", bg: "surface" },
  [STYLE.meta]: { dim: true },
  [STYLE.title]: { fg: "accent", bold: true },
  [STYLE.subject]: { fg: "strongFg" },
  [STYLE.thought]: { dim: true, italic: true },
  [STYLE.error]: { fg: "danger" },
  [STYLE.hint]: { fg: "accent" },
  [STYLE.diffHeader]: { bold: true },
  [STYLE.diffHunk]: { fg: "accent", dim: true },
  [STYLE.diffAdd]: { bg: "diffAddBg" },
  [STYLE.diffDelete]: { bg: "diffDelBg" },
} as const;

/** The cells at the left of each row. They stay out of a copy. */
export const INDENT: Segment = Object.freeze({ text: " ", copy: false });

/** One empty row before each item, so two items do not touch. It has no source. */
const GAP: TextSection = Object.freeze({
  key: "gap",
  kind: "text",
  text: "",
  render: () => [{ segments: [], join: "\n" }],
});

/** A range of a source text with its style and its link. */
export interface Range {
  readonly from: number;
  readonly to: number;
  readonly style?: string | undefined;
  readonly link?: string | undefined;
}

/** An item of `sections` after the gap row. */
export function item(key: string, ...sections: TextSection[]): TextItem {
  return Object.freeze({ key, sections: [GAP, ...sections] });
}

/** A title line, such as the heading of a thought. */
export function label(text: string, style: string): TextSection {
  return { key: "title", kind: "label", text, render: (width) => styledRows(text, width, style) };
}

/** A section of plain `text` in `style`. */
export function plain(key: string, text: string, style: string | undefined): TextSection {
  return { key, kind: "text", text, render: (width) => styledRows(text, width, style) };
}

/** The rows of `text` at `width`, indented, each segment in `style`. */
export function styledRows(text: string, width: number, style: string | undefined): TextRow[] {
  return rangedRows(text, width, [{ from: 0, to: text.length, style }]);
}

/**
 * The rows of `text` at `width`, indented. `ranges` are in source order and do not overlap. A segment ends at each
 * bound of a range, and it takes the style and the link of its range. Text outside each range has neither.
 */
export function rangedRows(text: string, width: number, ranges: readonly Range[]): TextRow[] {
  const triples = wrap(text, Math.max(1, width - 2));
  const rows: TextRow[] = [];
  for (let at = 0; at < triples.length; at += 3) {
    const from = triples[at] as number;
    const to = triples[at + 1] as number;
    const segments: Segment[] = [INDENT];
    let start = from;
    while (start < to) {
      const range = ranges.find((candidate) => candidate.from <= start && start < candidate.to);
      const next = ranges.find((candidate) => candidate.from > start)?.from ?? to;
      const end = Math.min(to, range === undefined ? next : range.to);
      segments.push({
        text: text.slice(start, end),
        source: { kind: "text", from: start, to: end },
        ...(range?.style === undefined ? {} : { style: range.style }),
        ...(range?.link === undefined ? {} : { link: range.link }),
      });
      start = end;
    }
    rows.push({ segments, join: triples[at + 2] === 1 ? "" : "\n" });
  }
  return rows;
}

/** The rows of a message of the user: the text on a filled band as wide as the pane. */
export function filledRows(text: string, width: number): TextRow[] {
  return styledRows(text, width, STYLE.user).map((row) => {
    const used = row.segments.reduce((cells, segment) => cells + measure(segment.text), 0);
    const fill: Segment = { text: " ".repeat(Math.max(0, width - used)), style: STYLE.user, copy: false };
    return { segments: [{ ...INDENT, style: STYLE.user }, ...row.segments.slice(1), fill], join: row.join };
  });
}

export function indented(row: TextRow): TextRow {
  return { segments: [INDENT, ...row.segments], join: row.join };
}

/** `row` with each source offset `by` units later, for a block inside a longer source. */
export function shifted(row: TextRow, by: number): TextRow {
  if (by === 0) return row;
  const segments = row.segments.map((segment) =>
    segment.source === undefined
      ? segment
      : { ...segment, source: { ...segment.source, from: segment.source.from + by, to: segment.source.to + by } },
  );
  return { segments, join: row.join };
}
