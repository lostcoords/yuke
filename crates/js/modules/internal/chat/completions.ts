/** This module holds `ChatCompletions`: the list of the completions of the draft of a composer. */

import type { CompletionContext, CompletionItem, CompletionList, CompletionProvider } from "yuke:chat";
import { EMPTY } from "yuke:internal/chat/composer";
import { clipped, STYLE } from "yuke:internal/chat/rows";
import { type Canvas, measure, strokeOf, type TextEditor, type View } from "yuke:tui";

/** The most rows of the list. */
const ROWS = 6;

export interface ChatCompletionsOptions {
  /** The providers to ask, the first one first. The first list with an item shows. */
  readonly providers: () => readonly CompletionProvider[];
  /** The folder of `CompletionContext.folder`. */
  readonly folder: () => string;
  /** Its abort removes the watch of the editor and aborts the open ask. */
  readonly signal: AbortSignal;
  /** While this gives `false`, the list shows nothing and takes no key. */
  readonly enabled: () => boolean;
  /** Gets the throw or the rejection of a provider. The ask then goes on to the next provider. */
  readonly onError: (error: unknown) => void;
}

/**
 * The list of the completions of the draft of a composer. Each change of the draft or of the caret asks the
 * providers again and aborts the ask before it. While an ask waits, the list shows nothing. Up and Down move the
 * selection. Tab writes the selected item. Enter runs it, or writes it when it has no `run`. Esc hides the list until
 * the next edit. A draft without a list stays a message, so Enter sends it.
 *
 * ```ts
 * const completions = new ChatCompletions(editor, {
 *   providers: () => providers,
 *   folder: () => sessionFolder,
 *   signal: mount.signal,
 *   enabled: () => true,
 *   onError: (error) => ctx.notify("error", String(error)),
 * });
 * completions.addChangeListener(() => tui.requestFrame());
 * // in layout: { view: completions.view, rect: { column: 0, row: editorRow - completions.rows, width, height: completions.rows } }
 * ```
 */
export class ChatCompletions {
  readonly #editor: TextEditor;
  readonly #options: ChatCompletionsOptions;
  readonly #listeners = new Set<() => void>();
  /** The list of the last answer, or `undefined` while no provider gave one. */
  #list: CompletionList | undefined;
  #ask: AbortController | undefined;
  /** The draft that Esc hid the list for. */
  #hidden: string | undefined;
  #selected = 0;

  constructor(editor: TextEditor, options: ChatCompletionsOptions) {
    this.#editor = editor;
    this.#options = options;
    const extension = editor.extend(options.signal);
    // The keys of the list come before the keymap of the chat, and a draft without a list stays a message.
    extension.addKeyHandler((event) => this.#key(strokeOf(event)), "beforeKeymap");
    extension.addChangeListener(() => this.#start());
    options.signal.addEventListener("abort", () => this.#ask?.abort(), { once: true });
    this.#start();
  }

  /** The count of rows that the list needs now: at most 6, and 0 without a list. */
  get rows(): number {
    return Math.min(ROWS, this.#items().length);
  }

  /** Call `listener` when a list comes later than the change of the draft, so the owner asks for a frame. */
  addChangeListener(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** The view of the list. A place with fewer rows than `rows` scrolls the list to the selected item. */
  readonly view: View = {
    draw: (canvas: Canvas): void => {
      const items = this.#items();
      const selected = Math.min(this.#selected, items.length - 1);
      // The list scrolls so the selected item stays in sight.
      const first = Math.max(0, selected - canvas.height + 1);
      const width = Math.max(0, ...items.map((item) => measure(item.label)));
      for (const [at, item] of items.slice(first, first + canvas.height).entries()) {
        const style = first + at === selected ? STYLE.selected : undefined;
        if (style !== undefined) canvas.fill(0, at, canvas.width, 1, style);
        const label = item.label.padEnd(width);
        const cut = clipped(item.detail === undefined ? label : `${label}  ${item.detail}`, canvas.width - 1);
        const shown = cut.slice(0, label.length);
        canvas.text(1, at, shown, style);
        for (const range of item.ranges ?? []) {
          const to = Math.min(range.to, shown.length);
          const match = style === undefined ? STYLE.match : [style, STYLE.match];
          if (range.from < to)
            canvas.text(1 + measure(shown.slice(0, range.from)), at, shown.slice(range.from, to), match);
        }
        canvas.text(1 + measure(label), at, cut.slice(label.length), style ?? STYLE.meta);
      }
    },
  };

  /** The items that show now. */
  #items(): readonly CompletionItem[] {
    if (this.#list === undefined || this.#editor.state.text === this.#hidden || !this.#options.enabled()) return [];
    return this.#list.items;
  }

  /** Ask the providers for the draft now, and abort the ask before it. */
  #start(): void {
    this.#ask?.abort();
    const ask = new AbortController();
    this.#ask = ask;
    this.#list = undefined;
    this.#selected = 0;
    // A changed draft ends the hide, so the same text typed again shows the list.
    if (this.#editor.state.text !== this.#hidden) this.#hidden = undefined;
    const context: CompletionContext = {
      text: this.#editor.state.text,
      caret: this.#editor.caret,
      folder: this.#options.folder(),
      signal: AbortSignal.any([ask.signal, this.#options.signal]),
    };
    this.#next(this.#options.providers(), 0, context);
  }

  /** Ask the providers from `index` on until one gives an item. A late list shows when its ask is still current. */
  #next(providers: readonly CompletionProvider[], index: number, context: CompletionContext): void {
    for (let at = index; at < providers.length; at += 1) {
      let answer: ReturnType<CompletionProvider["complete"]>;
      try {
        answer = (providers[at] as CompletionProvider).complete(context);
      } catch (error) {
        this.#options.onError(error);
        continue;
      }
      if (answer instanceof Promise) {
        answer.then(
          (list) => {
            if (context.signal.aborted) return;
            if (list === undefined || list.items.length === 0) {
              this.#next(providers, at + 1, context);
              return;
            }
            this.#list = list;
            for (const listener of [...this.#listeners]) listener();
          },
          (error: unknown) => {
            if (context.signal.aborted) return;
            this.#options.onError(error);
            this.#next(providers, at + 1, context);
          },
        );
        return;
      }
      if (answer !== undefined && answer.items.length > 0) {
        this.#list = answer;
        return;
      }
    }
  }

  #key(stroke: string): boolean {
    const items = this.#items();
    const list = this.#list;
    if (items.length === 0 || list === undefined) return false;
    if (stroke === "up" || stroke === "down") {
      const next = Math.min(this.#selected, items.length - 1) + (stroke === "up" ? -1 : 1);
      this.#selected = Math.max(0, Math.min(items.length - 1, next));
      return true;
    }
    if (stroke === "esc") {
      this.#hidden = this.#editor.state.text;
      return true;
    }
    if (stroke !== "tab" && stroke !== "enter") return false;
    const item = items[Math.min(this.#selected, items.length - 1)] as CompletionItem;
    if (stroke === "tab" || item.run === undefined) {
      this.#editor.replace(list.from, list.to ?? this.#editor.caret, item.insert);
      return true;
    }
    const draft = this.#editor.state;
    this.#editor.reset(EMPTY);
    // A run that gives `false` leaves the draft. Enter stays here, so the draft is not sent.
    if (!item.run()) this.#editor.reset(draft);
    return true;
  }
}
