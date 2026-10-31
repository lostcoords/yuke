/**
 * `ChatComposer` of `yuke:chat`, and the draft of a composer as the blocks of an input, and back. A paste span keeps
 * its whole text in the draft, so the input gets the text. An image span covers one U+FFFC and becomes a media block.
 */

import type { ChatComposerOptions, ChatSession } from "yuke:chat";
import type { Frozen } from "yuke:plugins";
import type { Block, Input, InputId } from "yuke:protocol";
import type { Entry } from "yuke:transcript";
import type { EditorSpan, EditorState, TextEditor } from "yuke:tui";

/** A paste of more characters than this becomes a span that shows a label. */
const PASTE_SPAN = 300;

/** The character that an image span covers: U+FFFC, the object replacement character. */
const IMAGE = "￼";

export const EMPTY: EditorState = Object.freeze({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });

/** The blocks of `draft`: its text between its images, each image a media block. A draft of white space has none. */
function blocksOf(draft: EditorState): Block[] {
  const blocks: Block[] = [];
  let from = 0;
  const text = (to: number): void => {
    if (to > from) blocks.push({ user_text: draft.text.slice(from, to) });
  };
  for (const span of draft.spans) {
    if (span.kind !== "image") continue;
    text(span.from);
    blocks.push({ media: span.media });
    from = span.to;
  }
  text(draft.text.length);
  const blank = blocks.every((block) => "user_text" in block && block.user_text.trim() === "");
  return blank ? [] : blocks;
}

/** The draft of the blocks of an input, with an image span for each media block. The caret is at the end. */
function draftOf(content: Extract<Entry, { kind: "input" }>["content"]): EditorState {
  let text = "";
  const spans: EditorSpan[] = [];
  for (const block of content) {
    if ("user_text" in block) text += block.user_text;
    else if ("media" in block) {
      spans.push({
        from: text.length,
        to: text.length + 1,
        kind: "image",
        label: `[image ${spans.length + 1}]`,
        media: block.media,
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

export class ChatComposer {
  readonly #chat: ChatSession;
  readonly #editor: TextEditor;
  readonly #options: ChatComposerOptions;
  #sending = false;
  // The key of the shown message of a browse. A browse starts in an empty editor, so its end empties it again.
  #browse: string | undefined;
  // The last recalled waiting input. The next older() recalls an older one, until an edit, a caret move, or setDraft.
  #recalled: InputId | undefined;
  // A recall waits for its removal. Until the removal ends, older() does nothing.
  #recalling = false;
  // The attaches whose store has not ended. A send waits for them, so the image goes with its draft.
  #attaching = 0;

  constructor(chat: ChatSession, editor: TextEditor, options: ChatComposerOptions) {
    this.#chat = chat;
    this.#editor = editor;
    this.#options = options;
    const extension = editor.extend(options.signal);
    // An edit of the shown message ends the browse, so the edited text stays. An edit or a caret move ends a recall.
    extension.onChange((change) => {
      if (change.kind === "edit") this.#browse = undefined;
      if (change.kind === "edit" || change.kind === "selection") this.#recalled = undefined;
    });
    // The label covers the text on the screen only, so a send takes the whole text.
    extension.onPaste((text) => {
      if (text.length <= PASTE_SPAN) return false;
      const selection = editor.selection;
      editor.replace(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head), text, [
        { from: 0, to: text.length, kind: "paste", label: `[Pasted text · ${text.length} chars]` },
      ]);
      return true;
    });
  }

  get busy(): boolean {
    return this.#sending || this.#recalling || this.#attaching > 0;
  }

  get browsing(): boolean {
    return this.#browse !== undefined;
  }

  get canOlder(): boolean {
    const text = this.#editor.state.text;
    return this.#recalling || this.#browse !== undefined || text === "" || this.#recallable() !== undefined;
  }

  get waiting(): [InputId, Frozen<Input>][] {
    return [...this.#chat.transcript.pending]
      .filter((entry) => entry[1].source.kind === "user" && entry[1].kind === "message")
      .sort((a, b) => a[0] - b[0]);
  }

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
      await target.input(blocks);
    } catch (error) {
      if (draft !== undefined) this.setDraft(joined(draft, this.#editor.state));
      throw error;
    } finally {
      this.#sending = false;
    }
  }

  async older(): Promise<"taken" | undefined> {
    if (this.#recalling) return undefined;
    const next = this.#recallable();
    if (next !== undefined) return this.#recall(next[0], next[1]);
    if (this.#browse !== undefined || this.#editor.state.text === "") this.#browseBy(-1);
    return undefined;
  }

  newer(): void {
    this.#browseBy(1);
  }

  async attachImage(image: { readonly bytes: Uint8Array; readonly mime: string }): Promise<void> {
    this.#attaching += 1;
    try {
      const target = await this.#options.handle();
      if (target === undefined || this.#options.signal.aborted) return;
      const blob = await target.putBlob(image.bytes);
      if (this.#options.signal.aborted) return;
      // The image goes where the caret is now, also after an edit during the store.
      const editor = this.#editor;
      const count = editor.state.spans.filter((span) => span.kind === "image").length;
      const selection = editor.selection;
      editor.replace(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head), IMAGE, [
        { from: 0, to: 1, kind: "image", label: `[image ${count + 1}]`, media: { blob, mime: image.mime } },
      ]);
    } finally {
      this.#attaching -= 1;
    }
  }

  setDraft(draft: EditorState): void {
    this.#editor.reset(draft);
    this.#browse = undefined;
    this.#recalled = undefined;
  }

  /**
   * The message that older() recalls. An empty editor recalls the newest one. After a recall, the next older one, also
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
    const at = this.#browse === undefined ? list.length : list.findIndex((entry) => entry.key === this.#browse);
    const next = list[at + step];
    if (next === undefined) {
      if (step === 1 && this.#browse !== undefined) this.setDraft(EMPTY);
      else if (step === -1) void this.#chat.older();
      return;
    }
    this.#editor.reset(draftOf(next.content));
    this.#browse = next.key;
  }
}
