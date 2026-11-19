/**
 * `ChatComposer`, and the draft of a composer as the blocks of an input, and back. A paste span keeps
 * its whole text in the draft, so the input gets the text. An image span covers one U+FFFC and becomes a media block.
 */

import type { ChatSession } from "yuke:internal/chat/session";
import { fitImage } from "yuke:internal/native";
import type { Frozen, SessionHandle } from "yuke:plugins";
import type { Block, Input, InputId } from "yuke:protocol";
import type { Entry } from "yuke:transcript";
import type { EditorSpan, EditorState, TextEditor } from "yuke:tui";

/** A paste of more characters than this becomes a span that shows a label. */
const PASTE_SPAN = 300;

/** The character that an image span covers: U+FFFC, the object replacement character. */
const IMAGE = "￼";

export const EMPTY: EditorState = Object.freeze({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });

/**
 * The blocks of `draft`: its text between its images, each image a media block. The edges of the whole draft trim, and
 * a run of white space alone makes no block.
 */
function blocksOf(draft: EditorState): Block[] {
  const blocks: Block[] = [];
  let from = 0;
  const text = (to: number): void => {
    if (to > from) blocks.push({ kind: "userText", text: draft.text.slice(from, to) });
  };
  for (const span of draft.spans) {
    if (span.kind !== "image") continue;
    text(span.from);
    blocks.push({ kind: "media", ...span.media });
    from = span.to;
  }
  text(draft.text.length);
  // Only the edges of the whole draft trim, so the space between a text and an image stays.
  const first = blocks[0];
  if (first?.kind === "userText") blocks[0] = { kind: "userText", text: first.text.trimStart() };
  const last = blocks.at(-1);
  if (last?.kind === "userText") blocks[blocks.length - 1] = { kind: "userText", text: last.text.trimEnd() };
  return blocks.filter((block) => block.kind !== "userText" || block.text.trim() !== "");
}

/** The draft of the blocks of an input, with an image span for each media block. The caret is at the end. */
function draftOf(content: Extract<Entry, { kind: "input" }>["content"]): EditorState {
  let text = "";
  const spans: EditorSpan[] = [];
  for (const block of content) {
    // QuickJS makes `"" + long` a rope, and the first search of that rope keeps a second copy of the text.
    if (block.kind === "userText") text = text === "" ? block.text : text + block.text;
    else if (block.kind === "media") {
      const { kind, ...media } = block;
      spans.push({
        from: text.length,
        to: text.length + 1,
        kind: "image",
        label: `[image ${spans.length + 1}]`,
        media,
      });
      text += IMAGE;
    }
  }
  return { text, selection: { anchor: text.length, head: text.length }, spans };
}

/** `first` above `second`, a line end between them, each span kept. The caret is at the end. */
function joined(first: EditorState, second: EditorState): EditorState {
  if (second.text === "") return { ...first, selection: { anchor: first.text.length, head: first.text.length } };
  const shift = first.text.length + 1;
  const text = `${first.text}\n${second.text}`;
  const spans = [
    ...first.spans,
    ...second.spans.map((span) => ({ ...span, from: span.from + shift, to: span.to + shift })),
  ];
  return { text, selection: { anchor: text.length, head: text.length }, spans };
}

export interface ChatComposerOptions {
  /** The handle for a send. `undefined` cancels the send, and the draft stays. */
  readonly handle: () => Promise<SessionHandle | undefined>;
  /** Its abort removes the watch of the editor by the composer. An attach that started before it puts nothing. */
  readonly signal: AbortSignal;
}

/**
 * The behavior of a composer on a `TextEditor`: the send of its draft, the recall of a waiting message, and the
 * history of the messages of the user. A paste of more than 300 characters shows a label. A send takes the whole text
 * of that paste. A paste handler that the caller adds later takes a paste first. It gives no notices: a failure
 * rejects to the caller. One composer owns its editor: two composers on one editor send one draft twice.
 *
 * ```ts
 * const composer = new ChatComposer(chat, editor, { handle: () => chat.ensure(pick), signal: mount.signal });
 * // enter: composer.send()   up: composer.olderMessage()   down: composer.newerMessage()
 * ```
 */
export class ChatComposer {
  readonly #chat: ChatSession;
  readonly #editor: TextEditor;
  readonly #options: ChatComposerOptions;
  #sending = false;
  // The key of the shown message of a browse. A browse starts in an empty editor, so its end empties it again.
  #browse: string | undefined;
  // The last recalled waiting input. The next olderMessage() recalls an older one, until an edit, a caret move, or setDraft.
  #recalled: InputId | undefined;
  // A recall waits for its removal. Until the removal ends, olderMessage() does nothing.
  #recalling = false;
  // The attaches whose store has not ended. A send waits for them, so the image goes with its draft.
  #attaching = 0;

  constructor(chat: ChatSession, editor: TextEditor, options: ChatComposerOptions) {
    this.#chat = chat;
    this.#editor = editor;
    this.#options = options;
    const extension = editor.extend(options.signal);
    // An edit of the shown message ends the browse, so the edited text stays. An edit or a caret move ends a recall.
    extension.addChangeListener((change) => {
      if (change.kind === "edit") this.#browse = undefined;
      if (change.kind === "edit" || change.kind === "selection") this.#recalled = undefined;
    });
    // The label covers the text on the screen only, so a send takes the whole text.
    extension.addPasteHandler((event) => {
      if (event.text.length <= PASTE_SPAN) return false;
      const selection = editor.selection;
      editor.replace(
        Math.min(selection.anchor, selection.head),
        Math.max(selection.anchor, selection.head),
        event.text,
        [{ from: 0, to: event.text.length, kind: "paste", label: `[Pasted text · ${event.text.length} chars]` }],
      );
      return true;
    });
  }

  /** A send, a recall, or an attach has not ended. */
  get busy(): boolean {
    return this.#sending || this.#recalling || this.#attaching > 0;
  }

  /** The editor shows an older message of the user. */
  get browsing(): boolean {
    return this.#browse !== undefined;
  }

  /** `olderMessage()` has something to do: a recall, a browse, or an empty editor. */
  get canOlderMessage(): boolean {
    const text = this.#editor.state.text;
    return this.#recalling || this.#browse !== undefined || text === "" || this.#recallable() !== undefined;
  }

  /** The waiting messages of the user in the queue of the session, oldest first. An input of a plugin is not one of them. */
  get waiting(): [InputId, Frozen<Input>][] {
    return [...this.#chat.transcript.pending]
      .filter((entry) => entry[1].source.kind === "user" && entry[1].kind === "message")
      .sort((a, b) => a[0] - b[0]);
  }

  /**
   * Send the draft. The draft of the send is the one after `handle()`, and the editor then empties. A refused input
   * comes back above the newer text, and the promise rejects. An empty draft does nothing. A send before the end of
   * another send or of an attach does nothing.
   */
  async send(): Promise<void> {
    if (this.#sending || this.#attaching > 0 || blocksOf(this.#editor.state).length === 0) return;
    this.#sending = true;
    let draft: EditorState | undefined;
    try {
      const target = await this.#options.handle();
      if (target === undefined || this.#options.signal.aborted) return;
      // The draft of the send is the one after the setup, so text typed meanwhile goes with it.
      draft = this.#editor.state;
      const blocks = blocksOf(draft);
      if (blocks.length === 0) return;
      this.setDraft(EMPTY);
      await target.sendMessage({ content: blocks });
    } catch (error) {
      if (draft !== undefined) this.setDraft(joined(draft, this.#editor.state));
      throw error;
    } finally {
      this.#sending = false;
    }
  }

  /**
   * Recall the newest waiting message into an empty editor, and each next older one above the recalled text. Without a
   * recall, an empty editor or a shown message gets an older message of the user. `"taken"` when a turn took the
   * message first.
   */
  async olderMessage(): Promise<"taken" | undefined> {
    if (this.#recalling) return undefined;
    const next = this.#recallable();
    if (next !== undefined) return this.#recall(next[0], next[1]);
    if (this.#browse !== undefined || this.#editor.state.text === "") this.#browseBy(-1);
    return undefined;
  }

  /** Show a newer message of the user, or the empty editor after the newest one. */
  newerMessage(): void {
    this.#browseBy(1);
  }

  /**
   * Store `image` in the session of `handle()`, then put it at the caret of that time as `[image N]`. A send gives it
   * as a media block. `undefined` from `handle()` puts nothing, and a failed store rejects.
   */
  async attachImage(image: { readonly bytes: Uint8Array; readonly mimeType: string }): Promise<void> {
    this.#attaching += 1;
    try {
      const target = await this.#options.handle();
      if (target === undefined || this.#options.signal.aborted) return;
      // The session stores and sends only the scaled image.
      const fitted = await fitImage(image.bytes, image.mimeType);
      // A pane that closed during the scale stores nothing.
      if (this.#options.signal.aborted) return;
      const blob = await target.putBlob(fitted.bytes);
      if (this.#options.signal.aborted) return;
      // The image goes where the caret is now, also after an edit during the store.
      const editor = this.#editor;
      const count = editor.state.spans.filter((span) => span.kind === "image").length;
      const selection = editor.selection;
      editor.replace(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head), IMAGE, [
        { from: 0, to: 1, kind: "image", label: `[image ${count + 1}]`, media: { blob, mimeType: fitted.mimeType } },
      ]);
    } finally {
      this.#attaching -= 1;
    }
  }

  /** Put `draft` in the editor, and end a browse. A running recall puts its message above `draft` when it ends. */
  setDraft(draft: EditorState): void {
    this.#editor.reset(draft);
    this.#browse = undefined;
    this.#recalled = undefined;
  }

  /**
   * The message that olderMessage() recalls. An empty editor recalls the newest one. After a recall, the next older one, also
   * after a recall that came too late.
   */
  #recallable(): [InputId, Frozen<Input>] | undefined {
    const before = this.#recalled;
    // A browse starts only when no message is recallable, and new messages wait after the recalled one.
    if (before === undefined && this.#editor.state.text !== "") return undefined;
    return this.waiting.findLast((entry) => before === undefined || entry[0] < before);
  }

  /** Take the waiting message `id` back into the editor, above its text. A message that a turn took stays sent. */
  async #recall(id: InputId, input: Frozen<Input>): Promise<"taken" | undefined> {
    const target = this.#chat.handle;
    if (target === undefined) return undefined;
    this.#recalling = true;
    this.#recalled = id;
    try {
      const removed = await target.removeInput(id);
      if (this.#options.signal.aborted) return undefined;
      if (!removed) return "taken";
      this.#editor.reset(joined(draftOf(input.content), this.#editor.state));
      return undefined;
    } finally {
      this.#recalling = false;
    }
  }

  /** Show an older (-1) or a newer (1) message of the user, or the empty editor after the newest one. */
  #browseBy(step: -1 | 1): void {
    // The messages of the user in the transcript, oldest first.
    const list = this.#chat.transcript.entries.filter(
      (entry): entry is Extract<Entry, { kind: "input" }> =>
        entry.kind === "input" && entry.source.kind === "user" && entry.inputKind === "message",
    );
    const at = this.#browse === undefined ? list.length : list.findIndex((entry) => entry.id === this.#browse);
    const next = list[at + step];
    if (next === undefined) {
      if (step === 1 && this.#browse !== undefined) this.setDraft(EMPTY);
      else if (step === -1) void this.#chat.loadOlderHistory();
      return;
    }
    this.#editor.reset(draftOf(next.content));
    this.#browse = next.id;
  }
}
