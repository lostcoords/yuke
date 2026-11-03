/**
 * The item of a tool call. Its head line comes from the hints of its tool, and it fills one row. An open call also
 * shows the subject that the head line changes, and its other arguments. The body is the live output until a result
 * comes, then the result: its display blocks or its text, then its media. A folded call shows the preview of its hints.
 */

import { diffRows, diffSource } from "yuke:internal/chat/diff";
import { bandedRows, clipped, indented, item, plain, STYLE, shifted, styledRows } from "yuke:internal/chat/rows";
import { elapsed } from "yuke:internal/chat/working";
import type { Entry } from "yuke:transcript";
import { Markdown, measure, type Segment, type TextItem, type TextRow, type TextSection } from "yuke:tui";

type ToolEntry = Extract<Entry, { kind: "tool" }>;

/** The rows of a folded call with the preview `head`, and of each failed call. */
const HEAD = 10;

/** The rows of a folded call with the preview `tail`. */
const TAIL = 5;

/**
 * The duration that the head line of `entry` shows at the time `now`. A duration below one second shows nothing, and
 * so does a clock that moved back.
 */
export function shownDuration(entry: ToolEntry, now: number): string | undefined {
  const ms = entry.startedAt === undefined ? entry.durationMs : now - entry.startedAt;
  return ms === undefined || ms < 1000 ? undefined : elapsed(ms);
}

/**
 * The item of `entry`, with the result of `shownDuration`. An open call shows arguments that are not empty, and its
 * whole body.
 */
export function toolItem(entry: ToolEntry, open: boolean, duration: string | undefined): TextItem {
  const sections = heading(entry, open, duration);
  if (open) {
    const others = otherArguments(entry);
    if (others !== "" && others !== "{}") sections.push(plain("arguments", others, STYLE.toolOutput));
  }
  const body = bodyOf(entry);
  if (body !== undefined) {
    const preview = entry.result?.isError === true ? "head" : entry.hints.preview;
    sections.push({
      key: body.key,
      kind: "text",
      text: body.text,
      render: (width) => {
        if (open) return body.rows(width);
        return preview === "none" ? [] : previewRows(body.rows(width), preview);
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
  const source = value === undefined ? name : `${name} ${value}`;
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
        const link = entry.hints.subject?.kind === "text" ? undefined : value;
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

/** The fields of the arguments of `entry`. Incomplete JSON has none. */
function fieldsOf(entry: ToolEntry): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(entry.arguments);
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

/** The string argument that the hints of `entry` name as the subject. */
export function subjectOf(entry: ToolEntry): string | undefined {
  const subject = entry.hints.subject;
  if (subject === null) return undefined;
  const field = fieldsOf(entry)?.[subject.argument];
  return typeof field === "string" ? field : undefined;
}

/** The arguments of `entry` without its subject, as JSON. A call without a subject keeps its text as it came. */
function otherArguments(entry: ToolEntry): string {
  const subject = entry.hints.subject?.argument;
  const fields = fieldsOf(entry);
  if (subject === undefined || typeof fields?.[subject] !== "string") return entry.arguments;
  return JSON.stringify(Object.fromEntries(Object.entries(fields).filter((field) => field[0] !== subject)));
}

/** One block of a body: its source and its rows at a width. */
interface Block {
  readonly text: string;
  readonly rows: (width: number) => TextRow[];
}

/** One body: its section key, its source, and its rows at a width. */
interface Body extends Block {
  readonly key: "output" | "result";
}

/** A block of plain `text` in `style`. */
function plainBlock(text: string, style: string): Block {
  return { text, rows: (width) => styledRows(text, width, style) };
}

/** The body of `entry`: the live output before a result, else the result. A call without either has none. */
function bodyOf(entry: ToolEntry): Body | undefined {
  const result = entry.result;
  const blocks: Block[] = [];
  if (result === undefined) {
    if (entry.output !== "") blocks.push(plainBlock(entry.output, STYLE.toolOutput));
  } else if (result.isError || entry.display.length === 0) {
    if (result.content !== "")
      blocks.push(plainBlock(result.content, result.isError ? STYLE.toolError : STYLE.toolOutput));
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
    blocks.push(plainBlock(`[${media.mime} #${index + 1} · ${size(media.blob.len)}]`, STYLE.toolOutput));
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
  const more = omitted(rows.length - keep);
  return preview === "head" ? [...rows.slice(0, keep), more] : [more, ...rows.slice(-keep)];
}

/** A row that says how many rows a preview leaves out. It stays out of a copy. */
function omitted(count: number): TextRow {
  const segment: Segment = { text: `… ${count} more rows`, style: STYLE.toolOutput, copy: false };
  return { segments: [{ text: " ", copy: false }, segment], join: "\n" };
}

/** The size `bytes` in B, KiB, or MiB. */
function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}
