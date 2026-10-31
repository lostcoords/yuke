/** This module holds `ChatCommands` of `yuke:chat`: the list of the commands that match a slash word in a composer. */

import type { ChatCommandsOptions } from "yuke:chat";
import { EMPTY } from "yuke:internal/chat/composer";
import { STYLE } from "yuke:internal/chat/rows";
import {
  type Canvas,
  type CommandItem,
  fit,
  fuzzyMatch,
  measure,
  strokeOf,
  type TextEditor,
  type View,
} from "yuke:tui";

/** The most rows of the list. */
const ROWS = 6;

const SELECTED = Object.freeze({ reverse: true });

/** A draft of one slash word, such as `/mod`. */
const SLASH_WORD = /^\/\S*$/;

/** The label of the command `name` in the list: a slash, and the name. A core command shows without its prefix. */
function label(name: string): string {
  return `/${name.startsWith("core:") ? name.slice("core:".length) : name}`;
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
      if (change.kind !== "selection") this.#selected = 0;
      // A cleared or changed draft ends the hide, so the same word typed again shows the list.
      if (editor.state.text !== this.#hidden) this.#hidden = undefined;
    });
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
      const width = Math.max(0, ...matches.map((item) => measure(label(item.name))));
      for (const [at, item] of matches.slice(first, first + canvas.height).entries()) {
        const style = first + at === selected ? SELECTED : undefined;
        const name = label(item.name).padEnd(width);
        const text = `${name}  ${item.description ?? ""}`;
        const cut =
          fit(text, canvas.width - 1) === text.length ? text : `${text.slice(0, fit(text, canvas.width - 2))}…`;
        canvas.text(1, at, cut.slice(0, name.length), style);
        canvas.text(1 + measure(name), at, cut.slice(name.length), style ?? STYLE.meta);
      }
    },
  };

  /** The enabled commands that match the slash word of the draft, the best first. */
  #matches(): readonly CommandItem[] {
    const text = this.#editor.state.text;
    if (!SLASH_WORD.test(text) || text === this.#hidden || !this.#options.enabled()) return [];
    const ranked = this.#options.commands.list().flatMap((item) => {
      const match = item.enabled ? fuzzyMatch(text, label(item.name)) : undefined;
      return match === undefined ? [] : [{ item, score: match.score }];
    });
    // The sort is stable, so equal scores keep the order of the registry.
    return ranked.sort((a, b) => b.score - a.score).map((entry) => entry.item);
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
    const command = matches[Math.min(this.#selected, matches.length - 1)];
    if (stroke !== "enter" || command === undefined) return false;
    const draft = this.#editor.state;
    this.#editor.reset(EMPTY);
    // A command that left the registry runs nothing, so the draft comes back.
    if (!this.#options.commands.run(command.name)) this.#editor.reset(draft);
    return true;
  }
}
