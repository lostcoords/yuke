/**
 * The item of a tool call. Its head line comes from the hints of its tool. An open call also shows its arguments. The
 * body is the live output until a result comes, then the result: its display blocks, or its text. A folded call shows
 * the preview of its hints.
 */

import { diffRows, diffSource } from "yuke:internal/chat/diff";
import { indented, item, plain, type Range, rangedRows, STYLE, shifted } from "yuke:internal/chat/rows";
import type { Entry } from "yuke:transcript";
import { Markdown, type Segment, type TextItem, type TextRow, type TextSection } from "yuke:tui";

type ToolEntry = Extract<Entry, { kind: "tool" }>;

/** The rows of a folded call with the preview `head`, and of each failed call. */
const HEAD = 10;

/** The rows of a folded call with the preview `tail`. */
const TAIL = 5;

/** The item of `entry`. An open call shows arguments that are not empty, and its whole body. */
export function toolItem(entry: ToolEntry, open: boolean): TextItem {
  const sections: TextSection[] = [title(entry)];
  if (open && entry.arguments !== "" && entry.arguments !== "{}") {
    sections.push(plain("arguments", entry.arguments, STYLE.meta));
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
  return item(entry.key, ...sections);
}

/** The head line: the title of the hints or the name, the subject argument, and a state other than success. */
function title(entry: ToolEntry): TextSection {
  const name = entry.hints.title ?? (entry.name === "" ? "tool" : entry.name);
  const ranges: Range[] = [{ from: 0, to: name.length, style: STYLE.title }];
  let text = name;
  const subject = entry.hints.subject;
  const value = subject === null ? undefined : argument(entry.arguments, subject.argument);
  if (subject !== null && value !== undefined) {
    const link = subject.kind === "text" ? undefined : value;
    ranges.push({ from: text.length + 1, to: text.length + 1 + value.length, style: STYLE.subject, link });
    text += ` ${value}`;
  }
  const state = stateOf(entry);
  if (state !== undefined) {
    ranges.push({ from: text.length, to: text.length + state.length + 3, style: STYLE.meta });
    text += ` · ${state}`;
  }
  return { key: "title", kind: "label", text, render: (width) => rangedRows(text, width, ranges) };
}

/** The state of a call that did not end well, or `undefined` for a call that ended well. */
function stateOf(entry: ToolEntry): string | undefined {
  if (entry.status === "streaming") return "…";
  if (entry.status !== "done") return entry.status;
  return entry.result?.isError === true ? "error" : undefined;
}

/** The string argument `name` of the JSON `text`. A call that still streams has no complete JSON yet. */
export function argument(text: string, name: string): string | undefined {
  try {
    const value: unknown = JSON.parse(text);
    if (typeof value !== "object" || value === null) return undefined;
    const field = (value as Record<string, unknown>)[name];
    return typeof field === "string" ? field : undefined;
  } catch {
    return undefined;
  }
}

/** One body: its section key, its source, and its rows at a width. */
interface Body {
  readonly key: "output" | "result";
  readonly text: string;
  readonly rows: (width: number) => TextRow[];
}

/** The body of `entry`: the live output before a result, else the result. A call without either has none. */
function bodyOf(entry: ToolEntry): Body | undefined {
  const result = entry.result;
  if (result === undefined) {
    if (entry.output === "") return undefined;
    const output = entry.output;
    return {
      key: "output",
      text: output,
      rows: (width) => rangedRows(output, width, [{ from: 0, to: output.length }]),
    };
  }
  const blocks: { readonly text: string; readonly rows: (width: number) => TextRow[] }[] = [];
  if (result.isError || entry.display.length === 0) {
    const content = result.content;
    const style = result.isError ? STYLE.error : undefined;
    if (content !== "")
      blocks.push({
        text: content,
        rows: (width) => rangedRows(content, width, [{ from: 0, to: content.length, style }]),
      });
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
  for (const [index, media] of (result.media ?? []).entries()) {
    const text = `[${media.mime} #${index + 1} · ${size(media.blob.len)}]`;
    blocks.push({ text, rows: (width) => rangedRows(text, width, [{ from: 0, to: text.length, style: STYLE.meta }]) });
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
    key: "result",
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
  const segment: Segment = { text: `… ${count} more rows`, style: STYLE.meta, copy: false };
  return { segments: [{ text: " ", copy: false }, segment], join: "\n" };
}

/** The size `bytes` in B, KiB, or MiB. */
function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}
