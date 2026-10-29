/**
 * The document of one chat pane: one item for each entry of the transcript of its session, with the folds of the
 * pane, and one item after them for a failure of the running turn. An item stays the same object while its entry and
 * its fold stay, so the view keeps its rows.
 */

import type { Entry, Status, Transcript } from "yuke:transcript";
import {
  Markdown,
  measure,
  type Segment,
  type TextDocument,
  type TextItem,
  type TextRow,
  type TextSection,
  wrap,
} from "yuke:tui";

/** The style groups of the chat. Each one gets its default look from `STYLES`. */
export const STYLE = {
  user: "chat.user",
  meta: "chat.meta",
  title: "chat.title",
  thought: "chat.thought",
  error: "chat.error",
  hint: "chat.hint",
} as const;

/** The default look of each style group. A later `tui.styles.set` of a theme changes it. */
export const STYLES = {
  [STYLE.user]: { fg: "surfaceFg", bg: "surface" },
  [STYLE.meta]: { dim: true },
  [STYLE.title]: { fg: "accent", bold: true },
  [STYLE.thought]: { dim: true, italic: true },
  [STYLE.error]: { fg: "danger" },
  [STYLE.hint]: { fg: "accent" },
} as const;

/** The cells at the left of each row. They stay out of a copy. */
const INDENT: Segment = Object.freeze({ text: " ", copy: false });

/** One empty row before each item, so two items do not touch. It has no source. */
const GAP: TextSection = Object.freeze({
  key: "gap",
  kind: "text",
  text: "",
  render: () => [{ segments: [], join: "\n" }],
});

/** The key of the item of a failure of the running turn. It comes after the entries. */
const STATUS = "status";

interface Cached {
  readonly entry: Entry;
  readonly open: boolean;
  readonly item: TextItem;
}

export class ChatDocument {
  readonly #key: string;
  /** The fold choices of the pane: `true` is open. An entry without a choice has its default. */
  readonly #folds: Map<string, boolean>;
  #cache = new Map<string, Cached>();
  /** The parser of each text entry, by key. A text that grows parses only its last two blocks again. */
  #markdown = new Map<string, Markdown>();
  #status: { readonly status: Status; readonly item: TextItem } | undefined;
  #document: TextDocument;

  /** The document `key` with the fold choices `folds`. */
  constructor(key: string, folds: Iterable<readonly [string, boolean]> = []) {
    this.#key = key;
    this.#folds = new Map(folds);
    this.#document = Object.freeze({ key, items: [] });
  }

  /** The fold choices, for the snapshot of the pane. */
  get folds(): [string, boolean][] {
    return [...this.#folds];
  }

  /** Open or fold the entry `key`. `false` when the entry has no fold. */
  toggle(transcript: Transcript, key: string): boolean {
    const entry = transcript.entries.find((candidate) => candidate.key === key);
    if (entry?.kind !== "reasoning" || entry.text === "") return false;
    this.#folds.set(key, !this.#open(entry));
    return true;
  }

  /** The document of `transcript`. The same document object comes back while no item changed. */
  project(transcript: Transcript): TextDocument {
    const cache = new Map<string, Cached>();
    const markdown = new Map<string, Markdown>();
    const items: TextItem[] = [];
    for (const entry of transcript.entries) {
      const open = this.#open(entry);
      let cached = this.#cache.get(entry.key);
      if (entry.kind === "text") {
        const parser = this.#markdown.get(entry.key) ?? new Markdown();
        markdown.set(entry.key, parser);
        if (cached?.entry !== entry) parser.setText(entry.text);
      }
      if (cached?.entry !== entry || cached.open !== open) {
        cached = { entry, open, item: itemOf(entry, open, markdown.get(entry.key)) };
      }
      cache.set(entry.key, cached);
      items.push(cached.item);
    }
    const status = transcript.status;
    if (status !== undefined) {
      if (this.#status?.status !== status) this.#status = { status, item: statusItem(status) };
      items.push(this.#status.item);
    } else this.#status = undefined;
    this.#cache = cache;
    this.#markdown = markdown;
    const before = this.#document.items;
    if (before.length !== items.length || before.some((item, at) => item !== items[at])) {
      this.#document = Object.freeze({ key: this.#key, items });
    }
    return this.#document;
  }

  /** The fold of `entry`: its choice, else open for each entry but reasoning. */
  #open(entry: Entry): boolean {
    return this.#folds.get(entry.key) ?? entry.kind !== "reasoning";
  }
}

/** The item of `entry`. A text entry needs `markdown`, which holds its text. */
function itemOf(entry: Entry, open: boolean, markdown: Markdown | undefined): TextItem {
  switch (entry.kind) {
    case "input": {
      const text = inputText(entry.content);
      if (entry.source.kind === "user" && entry.inputKind === "message") {
        return item(entry.key, { key: "text", kind: "text", text, render: (width) => filledRows(text, width) });
      }
      const sender = entry.source.kind === "plugin" ? entry.source.name : "you";
      const title = entry.inputKind === "notification" ? `notification · ${sender}` : `message · ${sender}`;
      return item(entry.key, label(title, STYLE.meta), plain("text", text, undefined));
    }
    case "text": {
      const parser = markdown as Markdown;
      const body: TextSection = {
        key: "text",
        kind: "text",
        text: parser.source(),
        render: (width) => parser.rows(Math.max(1, width - 2)).map(indented),
      };
      return entry.refusal ? item(entry.key, label("refused", STYLE.error), body) : item(entry.key, body);
    }
    case "reasoning": {
      const title = label(entry.draft ? "thinking" : "thought", STYLE.title);
      if (entry.text === "") return item(entry.key, title);
      const body = plain("text", entry.text, STYLE.thought);
      return item(entry.key, title, open ? body : { ...body, render: () => [] });
    }
    case "tool":
      return item(entry.key, label(`${entry.name === "" ? "tool" : entry.name} · ${toolStatus(entry)}`, STYLE.title));
    case "compaction":
      return item(entry.key, label("context replaced", STYLE.meta));
    case "end": {
      const end = entry.end;
      if ("failed" in end) return item(entry.key, label(`failed: ${end.failed}`, STYLE.error));
      if (end.outcome === "stopped" || end.outcome === "cancelled") {
        return item(entry.key, label(end.outcome, STYLE.meta));
      }
      // A completed turn shows no row.
      return { key: entry.key, sections: [] };
    }
  }
}

function toolStatus(entry: Extract<Entry, { kind: "tool" }>): string {
  if (entry.status !== "done") return entry.status;
  return entry.result?.isError === true ? "error" : "done";
}

/** The item of a failure of the running turn. */
function statusItem(status: Status): TextItem {
  const text =
    status.kind === "retry_scheduled"
      ? `retry in ${Math.ceil(status.afterMs / 1000)} s: ${status.error}`
      : `round failed: ${status.error}`;
  return item(STATUS, label(text, STYLE.error));
}

/** An item of `sections` after the gap row. */
function item(key: string, ...sections: TextSection[]): TextItem {
  return Object.freeze({ key, sections: [GAP, ...sections] });
}

/** A title line, such as the heading of a thought. */
function label(text: string, style: string): TextSection {
  return { key: "title", kind: "label", text, render: (width) => styledRows(text, width, style) };
}

/** A section of plain `text` in `style`. */
function plain(key: string, text: string, style: string | undefined): TextSection {
  return { key, kind: "text", text, render: (width) => styledRows(text, width, style) };
}

/** The text of the blocks of an input, with a label for each media block. */
function inputText(content: Extract<Entry, { kind: "input" }>["content"]): string {
  let image = 0;
  return content
    .map((block) => {
      if ("user_text" in block) return block.user_text;
      if ("media" in block) {
        if (block.media.mime.startsWith("image/")) {
          image += 1;
          return `[image ${image}]`;
        }
        return `[${block.media.mime}]`;
      }
      return "";
    })
    .join("");
}

/** The rows of `text` at `width`, indented, each segment in `style`. */
function styledRows(text: string, width: number, style: string | undefined): TextRow[] {
  const inner = Math.max(1, width - 2);
  const triples = wrap(text, inner);
  const rows: TextRow[] = [];
  for (let at = 0; at < triples.length; at += 3) {
    const from = triples[at] as number;
    const to = triples[at + 1] as number;
    const segment: Segment = {
      text: text.slice(from, to),
      source: { kind: "text", from, to },
      ...(style === undefined ? {} : { style }),
    };
    rows.push({ segments: [INDENT, segment], join: triples[at + 2] === 1 ? "" : "\n" });
  }
  return rows;
}

/** The rows of a message of the user: the text on a filled band as wide as the pane. */
function filledRows(text: string, width: number): TextRow[] {
  return styledRows(text, width, STYLE.user).map((row) => {
    const used = row.segments.reduce((cells, segment) => cells + measure(segment.text), 0);
    const fill: Segment = { text: " ".repeat(Math.max(0, width - used)), style: STYLE.user, copy: false };
    return { segments: [{ ...INDENT, style: STYLE.user }, ...row.segments.slice(1), fill], join: row.join };
  });
}

function indented(row: TextRow): TextRow {
  return { segments: [INDENT, ...row.segments], join: row.join };
}
