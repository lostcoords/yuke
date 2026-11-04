/** This module holds `ChatCommands` of `yuke:chat`: the list of the commands that match a slash word in a composer. */

import type { ChatCommandsOptions } from "yuke:chat";
import { EMPTY } from "yuke:internal/chat/composer";
import { clipped, STYLE } from "yuke:internal/chat/rows";
import {
  type Canvas,
  type CommandItem,
  type EditorChange,
  fuzzyMatch,
  measure,
  strokeOf,
  type TextEditor,
  type TextExtension,
  type View,
} from "yuke:tui";

/** The most rows of the list. */
const ROWS = 6;

/** A draft of one slash word, such as `/mod`, and the text after it. */
const SLASH_DRAFT = /^(\/\S*)(\s[\s\S]*)?$/;

/** Enter on the slash word `word` runs `item`: text after the word needs a command that takes text. */
function runsCommand(item: CommandItem, word: string, hasText: boolean): boolean {
  return item.enabled && `/${item.slash}` === word && (!hasText || item.argumentHint !== undefined);
}

/** The left column of the list: the slash word and the hint of its text. */
function heading(item: CommandItem): string {
  return item.argumentHint === undefined ? `/${item.slash}` : `/${item.slash} ${item.argumentHint}`;
}

export class ChatCommands {
  readonly #editor: TextEditor;
  readonly #options: ChatCommandsOptions;
  // The draft that Esc hid the list for, and the place of the selection in the matches.
  #hidden: string | undefined;
  #selected = 0;

  constructor(editor: TextEditor, options: ChatCommandsOptions) {
    this.#editor = editor;
    this.#options = options;
    const extension = editor.extend(options.signal);
    // The keys of the list come before the keymap of the chat, and a draft with no match stays a message.
    extension.onKey((event) => this.#key(strokeOf(event)), "beforeKeymap");
    extension.onChange((change) => {
      if (change.kind !== "selection") {
        this.#selected = 0;
        this.#mark(extension);
      }
      // A cleared or changed draft ends the hide, so the same word typed again shows the list.
      if (editor.state.text !== this.#hidden) this.#hidden = undefined;
    });
    this.#mark(extension);
  }

  get rows(): number {
    return Math.min(ROWS, this.#matches().length);
  }

  readonly view: View = {
    draw: (canvas: Canvas): void => {
      const matches = this.#matches();
      const selected = Math.min(this.#selected, matches.length - 1);
      // The list scrolls so the selected command stays in sight.
      const first = Math.max(0, selected - canvas.height + 1);
      const width = Math.max(0, ...matches.map((item) => measure(heading(item))));
      for (const [at, item] of matches.slice(first, first + canvas.height).entries()) {
        const style = first + at === selected ? STYLE.selected : undefined;
        if (style !== undefined) canvas.fill(0, at, canvas.width, 1, style);
        const name = heading(item).padEnd(width);
        const text = `${name}  ${item.description ?? ""}`;
        const cut = clipped(text, canvas.width - 1);
        canvas.text(1, at, cut.slice(0, name.length), style);
        canvas.text(1 + measure(name), at, cut.slice(name.length), style ?? STYLE.meta);
      }
    },
  };

  /** The enabled commands that match the slash word of the draft, the best first. */
  #matches(): readonly CommandItem[] {
    const text = this.#editor.state.text;
    const draft = SLASH_DRAFT.exec(text);
    if (draft === null || text === this.#hidden || !this.#options.enabled()) return [];
    const word = draft[1] as string;
    const items = this.#options.commands.list().filter((item) => item.enabled && item.slash !== undefined);
    // Text after the word needs a command with a hint. Otherwise the draft stays a message.
    if (draft[2] !== undefined) return items.filter((item) => runsCommand(item, word, true));
    const ranked = items.flatMap((item) => {
      const match = fuzzyMatch(word, `/${item.slash}`);
      return match === undefined ? [] : [{ item, score: match.score }];
    });
    // The sort is stable, so equal scores keep the order of the registry.
    return ranked.sort((a, b) => b.score - a.score).map((entry) => entry.item);
  }

  /** Mark the word of a draft that Enter runs as a command, so a user sees it before the key. */
  #mark(extension: TextExtension<number, EditorChange>): void {
    const draft = SLASH_DRAFT.exec(this.#editor.state.text);
    const word = draft?.[1];
    const known =
      word !== undefined &&
      this.#options.commands.list().some((item) => runsCommand(item, word, draft?.[2] !== undefined));
    extension.setDecorations(known ? [{ range: { anchor: 0, head: word.length }, style: STYLE.command }] : []);
  }

  #key(stroke: string): boolean {
    const matches = this.#matches();
    if (matches.length === 0) return false;
    if (stroke === "up" || stroke === "down") {
      const next = Math.min(this.#selected, matches.length - 1) + (stroke === "up" ? -1 : 1);
      this.#selected = Math.max(0, Math.min(matches.length - 1, next));
      return true;
    }
    if (stroke === "esc") {
      this.#hidden = this.#editor.state.text;
      return true;
    }
    const command = matches[Math.min(this.#selected, matches.length - 1)] as CommandItem;
    if (stroke === "tab") {
      // Text after the word stays, so Tab only completes a draft of one word.
      if (SLASH_DRAFT.exec(this.#editor.state.text)?.[2] !== undefined) return true;
      const text = command.argumentHint === undefined ? `/${command.slash}` : `/${command.slash} `;
      this.#editor.reset({ text, spans: [], selection: { anchor: text.length, head: text.length } });
      return true;
    }
    if (stroke !== "enter") return false;
    const draft = this.#editor.state;
    this.#editor.reset(EMPTY);
    // A removed command or a run that gives `false` leaves the draft. Enter stays here, so the draft is not sent.
    const args = SLASH_DRAFT.exec(draft.text)?.[2]?.trim() || undefined;
    if (!this.#options.commands.run(command.name, args)) this.#editor.reset(draft);
    return true;
  }
}
