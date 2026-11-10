/**
 * The item of a tool call. Its head line comes from the hints of its tool, and it fills one row. The subject is the
 * argument that the hints name, or the raw arguments of a call without a subject hint. An open call shows a subject
 * that does not fit the head line below it. The body is the live output until a result comes. Then it is the display
 * of the result, or the text of a result without a display, and then the media. A folded call shows the preview of
 * its hints, and a folded failed call shows its first rows. A failure also gives the call its state and its band.
 */

import { diffRows, diffSource } from "yuke:internal/chat/diff";
import { bandedRows, clipped, indented, item, STYLE, shifted, styledRows } from "yuke:internal/chat/rows";
import { elapsed } from "yuke:internal/chat/working";
import type { Entry } from "yuke:transcript";
import { Markdown, measure, type Segment, type TextItem, type TextRow, type TextSection } from "yuke:tui";

type ToolEntry = Extract<Entry, { kind: "tool" }>;

/** The rows of a folded call with the preview `head`, and of each failed call. A plain body wraps only that many lines. */
const HEAD = 10;

/** The rows of a folded call with the preview `tail`. A plain body wraps only that many lines. */
const TAIL = 5;

/** The most UTF-16 units of a subject in the head line. The open call shows the whole subject below the head line. */
const HEAD_SUBJECT = 1000;

/**
 * The duration that the head line of `entry` shows at the time `now`. A duration below one second shows nothing, and
 * so does a clock that moved back.
 */
export function shownDuration(entry: ToolEntry, now: number): string | undefined {
  const ms = entry.startedAt === undefined ? entry.durationMs : now - entry.startedAt;
  return ms === undefined || ms < 1000 ? undefined : elapsed(ms);
}

/** The item of `entry`, with the result of `shownDuration`. An open call shows its whole body. */
export function toolItem(entry: ToolEntry, open: boolean, duration: string | undefined): TextItem {
  const sections = heading(entry, open, duration);
  const body = bodyOf(entry);
  if (body !== undefined) {
    const preview = entry.result?.isError === true ? "head" : entry.hints.preview;
    sections.push({
      key: body.key,
      kind: "text",
      text: body.text,
      render: (width) => {
        if (open) return body.rows(width);
        if (preview === "none") return [];
        return body.plain ? plainPreview(body.text, width, preview) : previewRows(body.rows(width), preview);
      },
    });
  }
  const band = bandOf(entry);
  if (band === undefined) return item(entry.key, ...sections);
  return item(
    entry.key,
    ...sections.map((section) => ({
      ...section,
      render: (width: number) => bandedRows(section.render?.(width) ?? [], width, band),
    })),
  );
}

/** The band behind each row of an unfinished call or a failed call. A call that ended well has none. */
function bandOf(entry: ToolEntry): string | undefined {
  if (entry.status !== "done") return STYLE.toolPending;
  return entry.result?.isError === true ? STYLE.toolFailed : undefined;
}

/**
 * The head line: the title of the hints or the name, the subject argument, a state other than success, and the
 * duration. A running clock takes the place of the state. The end stays, and the rest takes the room that it leaves.
 * An open call shows a subject that the row clips or flattens below the row.
 */
function heading(entry: ToolEntry, open: boolean, duration: string | undefined): TextSection[] {
  const name = entry.hints.title ?? (entry.name === "" ? "tool" : entry.name);
  const state = entry.status === "running" && duration !== undefined ? undefined : stateOf(entry);
  const end = [state, duration].map((part) => (part === undefined ? "" : ` · ${part}`)).join("");
  const value = subjectOf(entry);
  // The head line fills one row, so a long subject, such as streamed arguments, costs no more than a short one.
  const source = value === undefined ? name : `${name} ${value.slice(0, HEAD_SUBJECT)}`;
  // Each line end unit becomes one space, so the shown text keeps the offsets of its source.
  const head = source.replaceAll(/[\r\n]/g, " ");
  // The room excludes the indent and the right margin of each row.
  const shownAt = (width: number) => clipped(head, Math.max(1, width - 2 - measure(end)));
  const title: TextSection = {
    key: "title",
    kind: "label",
    text: source + end,
    render: (width) => {
      const shown = shownAt(width);
      // A clipped text does not match its source unit by unit, so it stands for the whole range.
      const kind = shown === head ? "text" : "replacement";
      const from = name.length + 1;
      const segments: Segment[] = [];
      if (shown.length > from) {
        const link = entry.hints.subject === null || entry.hints.subject.kind === "text" ? undefined : value;
        segments.push({ text: name, style: STYLE.title, source: { kind: "text", from: 0, to: name.length } });
        segments.push({ text: " ", source: { kind: "text", from: name.length, to: from } });
        segments.push({ text: shown.slice(from), style: STYLE.subject, link, source: { kind, from, to: head.length } });
      } else {
        segments.push({ text: shown, style: STYLE.title, source: { kind, from: 0, to: head.length } });
      }
      if (end !== "") {
        const to = head.length + end.length;
        segments.push({ text: end, style: STYLE.meta, source: { kind: "text", from: head.length, to } });
      }
      return [indented({ segments, join: "\n" })];
    },
  };
  if (!open || value === undefined) return [title];
  const subject: TextSection = {
    key: "subject",
    kind: "text",
    text: value,
    render: (width) => (shownAt(width) === source ? [] : styledRows(value, width, STYLE.subject)),
  };
  return [title, subject];
}

/** The state of a call that did not end well, or `undefined` for a call that ended well. */
function stateOf(entry: ToolEntry): string | undefined {
  if (entry.status === "streaming") return "…";
  if (entry.status !== "done") return entry.status;
  return entry.result?.isError === true ? "error" : undefined;
}

/**
 * The subject of `entry`: the string argument that its hints name, or its raw arguments when the hints name no subject.
 * Empty arguments give no subject, and so does a missing named string.
 */
function subjectOf(entry: ToolEntry): string | undefined {
  const subject = entry.hints.subject;
  if (subject === null) return entry.arguments === "" || entry.arguments === "{}" ? undefined : entry.arguments;
  try {
    const value: unknown = JSON.parse(entry.arguments);
    const field =
      typeof value === "object" && value !== null ? (value as Record<string, unknown>)[subject.argument] : undefined;
    return typeof field === "string" ? field : undefined;
  } catch {
    // A call can send incomplete JSON before it ends.
    return undefined;
  }
}

/** One block of a body: its source and its rows at a width. */
interface Block {
  readonly text: string;
  readonly rows: (width: number) => TextRow[];
}

/** One body: its section key, its source, and its rows at a width. */
interface Body extends Block {
  readonly key: "output" | "result";
  /** Each block is plain text, so a preview can wrap only the lines that it shows. */
  readonly plain: boolean;
}

/** A block of plain `text` in the style of the output. */
function plainBlock(text: string): Block {
  return { text, rows: (width) => styledRows(text, width, STYLE.toolOutput) };
}

/**
 * The body of `entry`: the live output before a result. After a result, the display, or the text without a display.
 * The media come last. A call without output, display, text, or media has no body.
 */
function bodyOf(entry: ToolEntry): Body | undefined {
  const result = entry.result;
  const blocks: Block[] = [];
  if (result === undefined) {
    if (entry.output !== "") blocks.push(plainBlock(entry.output));
  } else if (entry.display.length === 0) {
    if (result.content !== "") blocks.push(plainBlock(result.content));
  } else {
    for (const block of entry.display) {
      if (block.kind === "markdown") {
        const markdown = new Markdown(block.text);
        blocks.push({ text: markdown.source(), rows: (width) => markdown.rows(Math.max(1, width - 2)).map(indented) });
      } else {
        const path = block.path;
        const patch = block.patch;
        blocks.push({ text: diffSource(path, patch), rows: (width) => diffRows(path, patch, width) });
      }
    }
  }
  for (const [index, media] of (result?.media ?? []).entries()) {
    blocks.push(plainBlock(`[${media.mime} #${index + 1} · ${size(media.blob.len)}]`));
  }
  if (blocks.length === 0) return undefined;
  // One source for all blocks, with a line end between two, so one preview budget counts all of them.
  const starts: number[] = [];
  let text = "";
  for (const block of blocks) {
    if (text !== "") text += "\n";
    starts.push(text.length);
    text += block.text;
  }
  return {
    key: result === undefined ? "output" : "result",
    plain: entry.display.length === 0,
    text,
    rows: (width) =>
      blocks.flatMap((block, at) => {
        const rows = block.rows(width).map((row) => shifted(row, starts[at] as number));
        // A copy across two blocks gives the line end of the source between them.
        const last = rows.at(-1);
        if (last !== undefined && at < blocks.length - 1) rows[rows.length - 1] = { ...last, join: "\n" };
        return rows;
      }),
  };
}

/** The rows of a folded body with the preview `preview`, and a row that counts the rows it leaves out. */
function previewRows(rows: TextRow[], preview: "head" | "tail"): TextRow[] {
  const keep = preview === "head" ? HEAD : TAIL;
  if (rows.length <= keep) return rows;
  const more = omitted(rows.length - keep, "rows");
  return preview === "head" ? [...rows.slice(0, keep), more] : [more, ...rows.slice(-keep)];
}

/**
 * The rows of a folded plain `text` with the preview `preview`, and a row that counts the lines that it does not show
 * whole. Only the first `HEAD` or the last `TAIL` lines wrap, so a long live output costs no full wrap at each frame.
 */
function plainPreview(text: string, width: number, preview: "head" | "tail"): TextRow[] {
  if (preview === "head") {
    let end = -1;
    for (let line = 0; line < HEAD && end < text.length; line += 1) {
      end = text.indexOf("\n", end + 1);
      if (end === -1) end = text.length;
    }
    // The wrap reads "\r\n" as one line end, so the cut keeps no "\r" without its "\n".
    if (text[end] === "\n" && text[end - 1] === "\r") end -= 1;
    const rows = styledRows(text.slice(0, end), width, STYLE.toolOutput);
    const hidden = lineEnds(rows.slice(HEAD)) + countLineEnds(text, end, text.length);
    return hidden === 0 ? rows : [...rows.slice(0, HEAD), omitted(hidden, "lines")];
  }
  let start = text.length;
  for (let line = 0; line < TAIL && start > 0; line += 1) start = text.lastIndexOf("\n", start - 1);
  const cut = start <= 0 ? 0 : start + 1;
  const rows = styledRows(text.slice(cut), width, STYLE.toolOutput).map((row) => shifted(row, cut));
  const dropped = rows.slice(0, -TAIL);
  // The last dropped row of a line that goes on in the kept rows makes that line not whole.
  const partial = dropped.at(-1)?.join === "" ? 1 : 0;
  const hidden = countLineEnds(text, 0, cut) + lineEnds(dropped) + partial;
  return hidden === 0 ? rows : [omitted(hidden, "lines"), ...rows.slice(-TAIL)];
}

/** The number of `rows` that end a line. */
function lineEnds(rows: readonly TextRow[]): number {
  return rows.filter((row) => row.join === "\n").length;
}

/** The number of line ends in `text` from `from` to `to`. */
function countLineEnds(text: string, from: number, to: number): number {
  let count = 0;
  for (let at = text.indexOf("\n", from); at !== -1 && at < to; at = text.indexOf("\n", at + 1)) count += 1;
  return count;
}

/** A row that says how many rows or lines a preview leaves out. It stays out of a copy. */
function omitted(count: number, unit: "rows" | "lines"): TextRow {
  const segment: Segment = { text: `… ${count} more ${unit}`, style: STYLE.toolOutput, copy: false };
  return { segments: [{ text: " ", copy: false }, segment], join: "\n" };
}

/** The size `bytes` in B, KiB, or MiB. */
function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}
