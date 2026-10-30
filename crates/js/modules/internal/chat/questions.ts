/**
 * This module holds `ChatQuestions` of `yuke:chat` and the view of a question of a plugin. The view has a header row
 * with the plugin, the title, and the count of open questions. The answer widget comes below it. A confirm takes `y`
 * or `n`. A select is a picker. An input is a one-line field, and it masks a secret.
 */

import type { ChatQuestionsOptions, ChatSession } from "yuke:chat";
import { STYLE } from "yuke:internal/chat/rows";
import type { InteractionId, InteractionResponse } from "yuke:protocol";
import type { Question } from "yuke:transcript";
import { type Canvas, Picker, type Placement, type Size, strokeOf, TextEditor, type View } from "yuke:tui";

/** The most options of a select that show at once. */
const SELECT_ROWS = 8;

/** A view of one question, the view inside it that takes the keys, and the rows that it needs at most. */
export interface Asked {
  readonly view: View;
  readonly focus: View;
  readonly rows: number;
}

/** The view of `question`. `count` gives the open questions of the session now, and `answer` gets the response. */
export function ask(question: Question, count: () => number, answer: (response: InteractionResponse) => void): Asked {
  const request = question.request;
  let body: View | undefined;
  let focus: View | undefined;
  let rows = 2;
  if (request.kind === "select") {
    const picker = new Picker<{ readonly option: string }>({
      items: request.options.map((option) => ({ option })),
      key: (item) => item.option,
      label: (item) => item.option,
      choose: (item) => answer({ kind: "select", value: item.option }),
      cancel: () => answer({ kind: "canceled" }),
    });
    body = picker;
    focus = picker.input;
    rows = 2 + Math.min(request.options.length, SELECT_ROWS);
  } else if (request.kind === "input") {
    focus = body = new TextEditor({
      multiline: false,
      mask: request.secret,
      placeholder: request.placeholder ?? "",
      submit: (state) => answer({ kind: "input", value: state.text }),
    });
  } else if (request.message !== "") rows = 3;
  const view: View = {
    contexts: ["question"],
    focusable: true,
    // A modal gives its first focus to this view, and the view gives it to the field.
    ...(focus === undefined ? {} : { initialFocus: focus }),
    layout: (size: Size): readonly Placement[] =>
      body === undefined
        ? []
        : [{ view: body, rect: { column: 0, row: 1, width: size.width, height: size.height - 1 } }],
    draw(canvas: Canvas): void {
      const open = count();
      let column = canvas.text(1, 0, `${question.source} · `, STYLE.meta);
      column = canvas.text(column, 0, request.title, STYLE.title);
      if (open > 1) canvas.text(column, 0, ` · 1 of ${open}`, STYLE.meta);
      if (request.kind !== "confirm") return;
      if (request.message !== "") canvas.text(1, 1, request.message, STYLE.meta);
      canvas.text(1, canvas.height - 1, "y yes · n no · Esc cancel", STYLE.hint);
    },
    // A confirm has no default answer, so Enter does nothing.
    key(event): boolean {
      if (request.kind !== "confirm") return false;
      const stroke = strokeOf(event);
      if (stroke !== "y" && stroke !== "n") return false;
      answer({ kind: "confirm", value: stroke === "y" });
      return true;
    },
  };
  return { view, focus: focus ?? view, rows };
}

export class ChatQuestions {
  readonly #chat: ChatSession;
  readonly #options: ChatQuestionsOptions;
  readonly #listeners = new Set<() => void>();
  // The first open question and its view. The others wait in order. A sent answer waits for the close.
  #current: { readonly id: InteractionId; readonly asked: Asked; answered: boolean } | undefined;

  constructor(chat: ChatSession, options: ChatQuestionsOptions) {
    this.#chat = chat;
    this.#options = options;
    const stop = chat.onChange(() => this.#sync());
    options.signal.addEventListener("abort", stop, { once: true });
    this.#sync();
  }

  get current(): Asked | undefined {
    return this.#current?.asked;
  }

  cancel(): void {
    this.#answer({ kind: "canceled" });
  }

  onChange(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** Answer the shown question once. A failed answer, as after an answer of another client, goes to `failed`. */
  #answer(response: InteractionResponse): void {
    const current = this.#current;
    const handle = this.#chat.handle;
    if (current === undefined || current.answered || handle === undefined) return;
    current.answered = true;
    try {
      handle.respond(current.id, response);
    } catch (error) {
      current.answered = false;
      this.#options.failed(error);
    }
  }

  /** Take the first open question. The questions of an ended handle show again after the next open. */
  #sync(): void {
    const transcript = this.#chat.transcript;
    const head = this.#chat.handle === undefined ? undefined : transcript.questions.entries().next().value;
    if (head?.[0] === this.#current?.id) return;
    this.#current =
      head === undefined
        ? undefined
        : {
            id: head[0],
            asked: ask(
              head[1],
              () => transcript.questions.size,
              (response) => this.#answer(response),
            ),
            answered: false,
          };
    for (const listener of this.#listeners) listener();
  }
}
