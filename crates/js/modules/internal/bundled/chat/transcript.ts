/**
 * The document of one chat pane: one item for each entry of the transcript of its session, with the folds of the
 * pane, and one item after them for a failure of the running turn. An item stays the same object while its entry and
 * its fold stay, so the view keeps its rows.
 */

import { filledRows, indented, item, label, plain, STYLE } from "yuke:internal/bundled/chat/rows";
import { toolItem } from "yuke:internal/bundled/chat/tools";
import type { Entry, Status, Transcript } from "yuke:transcript";
import { Markdown, type TextDocument, type TextItem, type TextSection } from "yuke:tui";

/** The key of the item of a failure of the running turn. It comes after the entries. */
const STATUS = "status";

interface Cached {
  readonly entry: Entry;
  readonly open: boolean;
  readonly item: TextItem;
}

export class ChatDocument {
  /** The fold choices of the pane: `true` is open. An entry without a choice has its default. */
  readonly #folds: Map<string, boolean>;
  #cache = new Map<string, Cached>();
  /** The parser of each text entry, by key. A text that grows parses only its last two blocks again. */
  #markdown = new Map<string, Markdown>();
  #status: { readonly status: Status; readonly item: TextItem } | undefined;
  #document: TextDocument;

  /** The document `key` with the fold choices `folds`. */
  constructor(key: string, folds: Iterable<readonly [string, boolean]> = []) {
    this.#folds = new Map(folds);
    this.#document = Object.freeze({ key, items: [] });
  }

  /** The fold choices, for the snapshot of the pane. */
  get folds(): [string, boolean][] {
    return [...this.#folds];
  }

  /** Open or fold the entry `key`, a tool or a thought with text. Return `false` when that entry has no fold. */
  toggle(transcript: Transcript, key: string): boolean {
    const entry = transcript.entries.find((candidate) => candidate.key === key);
    if (entry === undefined || !(entry.kind === "tool" || (entry.kind === "reasoning" && entry.text !== ""))) {
      return false;
    }
    this.#folds.set(key, !this.#open(entry));
    return true;
  }

  /** Open each loaded tool when one of them is folded. Otherwise, fold each one. A later tool starts folded. */
  toggleTools(transcript: Transcript): void {
    const tools = transcript.entries.filter((entry) => entry.kind === "tool");
    const open = tools.some((entry) => !this.#open(entry));
    for (const entry of tools) this.#folds.set(entry.key, open);
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
      this.#document = Object.freeze({ key: this.#document.key, items });
    }
    return this.#document;
  }

  /** The fold of `entry`: its choice. Without a choice, a thought and a tool are folded, and the rest is open. */
  #open(entry: Entry): boolean {
    return this.#folds.get(entry.key) ?? (entry.kind !== "reasoning" && entry.kind !== "tool");
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
      return toolItem(entry, open);
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

/** The item of a failure of the running turn. */
function statusItem(status: Status): TextItem {
  const text =
    status.kind === "retry_scheduled"
      ? `retry in ${Math.ceil(status.afterMs / 1000)} s: ${status.error}`
      : `round failed: ${status.error}`;
  return item(STATUS, label(text, STYLE.error));
}

/** The text of the blocks of an input, with a label for each media block. */
export function inputText(content: Extract<Entry, { kind: "input" }>["content"]): string {
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
