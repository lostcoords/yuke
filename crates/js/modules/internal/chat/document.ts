/**
 * `ChatDocument`: one item for each entry of a transcript, with its folds, and one item after them for a
 * failure of the running turn. An input without content and a tool search that does not fail have no item. An item
 * stays the same object while its entry, its fold, and its shown duration stay, so the view keeps its rows.
 */

import type { ChatPresentation } from "yuke:chat";
import { filledRows, indented, item, label, plain, STYLE } from "yuke:internal/chat/rows";
import { shownDuration, toolItem } from "yuke:internal/chat/tools";
import { sourceName } from "yuke:internal/source-name";
import type { Entry, ReasoningEntry, Transcript, TurnFailure } from "yuke:transcript";
import { Markdown, type TextDocument, type TextItem, type TextSection } from "yuke:tui";

/** The id of the item of a failure of the running turn. It comes after the entries. */
const FAILURE = "failure";

/** The tool of the engine that loads deferred tools. */
const SEARCH_TOOL_NAME = "tool_search";

interface Cached {
  readonly entry: Entry;
  readonly open: boolean;
  /** The duration that the head line of a tool shows. */
  readonly duration: string | undefined;
  readonly item: TextItem;
  /** The parser of a text entry. A text that grows parses only its last two blocks again. */
  readonly markdown: Markdown | undefined;
}

/**
 * The default look of a conversation, as a text document for a `TextView`: user messages, Markdown answers, thoughts
 * and tool calls that fold, diffs, and the failure of a running turn. Thoughts and tools start folded. The head line
 * of a running tool shows its duration at the last `project` call. One document serves one session: fold choices go by
 * entry id, so make a new document when the session changes.
 *
 * ```ts
 * const document = new ChatDocument(`session:${id}`);
 * const view = new TextView({ document: document.project(chat.transcript) });
 * chat.addChangeListener(() => view.setDocument(document.project(chat.transcript)));
 * ```
 */
export class ChatDocument implements ChatPresentation {
  /** The fold choices of the pane: `true` is open. An entry without a choice has its default. */
  readonly #folds: Map<string, boolean>;
  #cache = new Map<string, Cached>();
  #failure: { readonly failure: TurnFailure; readonly item: TextItem } | undefined;
  #document: TextDocument;

  /** The document `id` with the fold choices `folds`: `true` is open. */
  constructor(id: string, folds: Iterable<readonly [string, boolean]> = []) {
    this.#folds = new Map(folds);
    this.#document = Object.freeze({ id, items: [] });
  }

  /** The fold choices, for a saved state. */
  get folds(): [string, boolean][] {
    return [...this.#folds];
  }

  /** Open or fold the entry `id`, a tool or a thought with text. `false` when that entry has no fold. */
  toggle(transcript: Transcript, id: string): boolean {
    const entry = transcript.entries.find((candidate) => candidate.id === id);
    if (entry === undefined || !(entry.kind === "tool" || (entry.kind === "reasoning" && hasText(entry)))) {
      return false;
    }
    this.#folds.set(id, !this.#open(entry));
    return true;
  }

  /** Open each loaded tool when one of them is folded. Otherwise, fold each one. A later tool starts folded. */
  toggleTools(transcript: Transcript): void {
    const tools = transcript.entries.filter((entry) => entry.kind === "tool" && shown(entry));
    const open = tools.some((entry) => !this.#open(entry));
    for (const entry of tools) this.#folds.set(entry.id, open);
  }

  /** The document of `transcript`. The same document object comes back while no item changed. */
  project(transcript: Transcript): TextDocument {
    const cache = new Map<string, Cached>();
    const items: TextItem[] = [];
    const now = Date.now();
    for (const entry of transcript.entries) {
      if (!shown(entry)) continue;
      const open = this.#open(entry);
      const duration = entry.kind === "tool" ? shownDuration(entry, now) : undefined;
      let cached = this.#cache.get(entry.id);
      if (cached?.entry !== entry || cached.open !== open || cached.duration !== duration) {
        // A text entry has no fold and no duration, so only a new entry brings it here.
        let markdown: Markdown | undefined;
        if (entry.kind === "text") {
          markdown = cached?.markdown ?? new Markdown();
          markdown.setText(entry.text);
        }
        cached = { entry, open, duration, item: itemOf(entry, open, markdown, duration), markdown };
      }
      cache.set(entry.id, cached);
      items.push(cached.item);
    }
    const failure = transcript.failure;
    if (failure !== undefined) {
      if (this.#failure?.failure !== failure) this.#failure = { failure, item: failureItem(failure) };
      items.push(this.#failure.item);
    } else this.#failure = undefined;
    this.#cache = cache;
    const before = this.#document.items;
    if (before.length !== items.length || before.some((item, at) => item !== items[at])) {
      this.#document = Object.freeze({ id: this.#document.id, items });
    }
    return this.#document;
  }

  /** The fold of `entry`: its choice. Without a choice, a thought and a tool are folded, and the rest is open. */
  #open(entry: Entry): boolean {
    return this.#folds.get(entry.id) ?? (entry.kind !== "reasoning" && entry.kind !== "tool");
  }
}

/**
 * Whether the document has an item for `entry`. A hidden input has no content, so it never shows. A tool search only
 * prepares the calls after it, so only a failed search shows.
 */
function shown(entry: Entry): boolean {
  if (entry.kind === "input") return entry.content.length > 0;
  return !(entry.kind === "tool" && entry.name === SEARCH_TOOL_NAME && entry.result?.isError !== true);
}

/** The item of `entry`. A text entry needs `markdown`, which holds its text. */
function itemOf(entry: Entry, open: boolean, markdown: Markdown | undefined, duration: string | undefined): TextItem {
  switch (entry.kind) {
    case "input": {
      const text = inputText(entry.content);
      if (entry.source.kind === "user" && entry.inputKind === "message") {
        return item(entry.id, { id: "text", kind: "text", text, render: (width) => filledRows(text, width) });
      }
      const sender = entry.source.kind === "plugin" ? sourceName(entry.source.name) : "you";
      const kind = { message: "Message", record: "Record", notification: "Notification" }[entry.inputKind];
      const title = `${kind} · ${sender}`;
      return item(entry.id, label(title, STYLE.meta), plain("text", text, undefined));
    }
    case "text": {
      const parser = markdown as Markdown;
      const body: TextSection = {
        id: "text",
        kind: "text",
        text: parser.source(),
        render: (width) => parser.rows(Math.max(1, width - 2)).map(indented),
      };
      return entry.refusal ? item(entry.id, label("Refused", STYLE.error), body) : item(entry.id, body);
    }
    case "reasoning": {
      // An encrypted thought streams no text. The working row still shows the reasoning phase.
      if (!hasText(entry)) return { id: entry.id, sections: [] };
      const title = label(entry.draft ? "Thinking" : "Thought", STYLE.title);
      const body = plain("text", entry.text, STYLE.thought);
      return item(entry.id, title, open ? body : { ...body, render: () => [] });
    }
    case "tool":
      return toolItem(entry, open, duration);
    case "compaction":
      return item(entry.id, label("Context replaced", STYLE.meta));
    case "end": {
      const end = entry.end;
      if (end.kind === "failed") return item(entry.id, label(`Failed: ${end.error}`, STYLE.error));
      if (end.kind === "stopped") return item(entry.id, label("Stopped", STYLE.meta));
      if (end.kind === "cancelled")
        return item(entry.id, label("Interrupted · tell yuke what to do instead", STYLE.meta));
      // A completed turn shows no row.
      return { id: entry.id, sections: [] };
    }
  }
}

/** Whether the thought `entry` has text other than white space. Without that text, the thought draws no rows. */
function hasText(entry: ReasoningEntry): boolean {
  return entry.text.trim() !== "";
}

/** The item of a failure of the running turn. */
function failureItem(failure: TurnFailure): TextItem {
  const text =
    failure.kind === "retryScheduled"
      ? `Retrying in ${Math.ceil(failure.afterMs / 1000)}s: ${failure.error}`
      : `Round failed: ${failure.error}`;
  return item(FAILURE, label(text, STYLE.error));
}

/** The text of the blocks of an input, with a label for each media block. */
export function inputText(content: Extract<Entry, { kind: "input" }>["content"]): string {
  let image = 0;
  return content
    .map((block) => {
      if (block.kind === "userText") return block.text;
      if (block.kind === "media") {
        if (block.mimeType.startsWith("image/")) {
          image += 1;
          return `[image ${image}]`;
        }
        return `[${block.mimeType}]`;
      }
      return "";
    })
    .join("");
}
