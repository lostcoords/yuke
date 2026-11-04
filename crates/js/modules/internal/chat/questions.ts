/**
 * This module holds `ChatQuestions` of `yuke:chat` and the view of a request of a plugin. The view shows one question
 * at a time: a head row with the plugin, the header, and the counts, then the question and its options. A question
 * without options is a one-line field, and it masks a secret.
 */

import type { ChatQuestionsOptions, ChatSession } from "yuke:chat";
import { callEach } from "yuke:internal/chat/listeners";
import { clipped, STYLE } from "yuke:internal/chat/rows";
import { sourceName } from "yuke:internal/source-name";
import type { Frozen } from "yuke:plugins";
import type { InteractionId, InteractionResponse, Question, QuestionAnswer } from "yuke:protocol";
import type { Interaction } from "yuke:transcript";
import {
  type Canvas,
  type Cursor,
  type KeyEvent,
  type Placement,
  type Size,
  strokeOf,
  TextEditor,
  type View,
} from "yuke:tui";

/** The most option rows that show at once. A longer list scrolls. */
const LIST_ROWS = 8;

/** The columns before the label of an option: the cursor mark and its space. */
const INDENT = 2;

/** The text of an empty field beside options. */
const OTHER = "Type your own answer…";

/** The keys that move between rows and pages. A field gets each other key. */
const PAGE_KEYS = new Set(["shift+tab", "up", "down", "enter"]);

/** The view of one request, and the most rows that it needs. The view takes the keys. */
interface Asked {
  readonly view: View;
  readonly rows: number;
}

/** One question of a request and its draft answer. */
interface Page {
  readonly question: Frozen<Question>;
  /** The row of the cursor: an option, or the field row after the options. */
  cursor: number;
  /** The ticked labels of a question with `multiple`. */
  readonly ticked: Set<string>;
  /** The field of a question with `other`. */
  readonly field: TextEditor | undefined;
  answer: QuestionAnswer | undefined;
}

/** The view of `interaction`. `count` gives the open requests of the session now, and `answer` gets the response. */
function ask(interaction: Interaction, count: () => number, answer: (response: InteractionResponse) => void): Asked {
  const pages: Page[] = interaction.request.questions.map((question) => ({
    question,
    cursor: 0,
    ticked: new Set(),
    field:
      question.other === true
        ? new TextEditor({
            multiline: false,
            mask: question.secret === true,
            placeholder: question.options.length > 0 ? OTHER : "",
          })
        : undefined,
    answer: undefined,
  }));
  // A press on a field leaves the focus on the view, so the view keeps the page keys.
  for (const each of pages) if (each.field !== undefined) each.field.focusOnPress = false;
  let current = 0;
  // A request has at least one question.
  const page = (): Page => pages[current] as Page;
  const onField = (shown: Page): boolean => shown.field !== undefined && shown.cursor === shown.question.options.length;

  /** Keep the answer of the shown page, then go to the next page. The last page sends the answers. */
  const commit = (shown: Page, result: QuestionAnswer): void => {
    shown.answer = result;
    if (current < pages.length - 1) {
      current += 1;
      return;
    }
    const answers = pages.map((each) => each.answer);
    // Each page before the last has an answer, because Enter is the only way forward.
    answer({ kind: "questions", answers: answers as QuestionAnswer[] });
  };
  /** Answer the shown page at Enter, from its cursor, its ticks, and its field. */
  const enter = (shown: Page): void => {
    const question = shown.question;
    const id = question.id;
    const text = shown.field?.state.text ?? "";
    // A field without options takes any text, and a field beside options needs one.
    const typed = shown.field === undefined || (text === "" && question.options.length > 0) ? undefined : text;
    if (question.multiple === true) {
      const values = question.options.map((option) => option.label).filter((label) => shown.ticked.has(label));
      if (values.length === 0 && typed === undefined) return;
      commit(shown, typed === undefined ? { id, values } : { id, values, other: typed });
      return;
    }
    if (onField(shown)) {
      if (typed !== undefined) commit(shown, { id, values: [], other: typed });
      return;
    }
    const option = question.options[shown.cursor];
    if (option !== undefined) commit(shown, { id, values: [option.label] });
  };
  /** The field of the cursor row. It gets the typed keys. */
  const typing = (): TextEditor | undefined => (onField(page()) ? page().field : undefined);
  // The view keeps the focus and passes the typed keys to the field. A new page then needs no focus change.
  const key = (event: KeyEvent): boolean => {
    const shown = page();
    const stroke = strokeOf(event);
    const field = typing();
    if (field !== undefined && !PAGE_KEYS.has(stroke)) return field.key(event);
    switch (stroke) {
      case "left":
      case "shift+tab":
        current = Math.max(0, current - 1);
        return true;
      case "up":
      case "down": {
        const last = shown.question.options.length - (shown.field === undefined ? 1 : 0);
        shown.cursor = Math.min(last, Math.max(0, shown.cursor + (stroke === "up" ? -1 : 1)));
        return true;
      }
      case "space": {
        const label = shown.question.multiple === true ? shown.question.options[shown.cursor]?.label : undefined;
        if (label !== undefined && !shown.ticked.delete(label)) shown.ticked.add(label);
        return true;
      }
      case "enter":
        enter(shown);
        return true;
      default:
        return false;
    }
  };

  /** The rows of the shown page: the question lines, then the list rows. */
  const lines = (shown: Page): readonly string[] => shown.question.question.split("\n");
  const listRows = (shown: Page): number => shown.question.options.length + (shown.field === undefined ? 0 : 1);
  /** The first list row that shows, so that the cursor stays inside `room` rows. */
  const top = (shown: Page, room: number): number =>
    Math.max(0, Math.min(shown.cursor - room + 1, listRows(shown) - room));
  /**
   * The rows of the shown page in `size`: the count of question lines, the first list row, and the list row count. The
   * list gets its rows first, so a tall question keeps its options in view.
   */
  const list = (shown: Page, size: Size): { readonly text: number; readonly row: number; readonly rows: number } => {
    const room = Math.max(0, size.height - 2);
    // With two free rows or more, the question keeps one, so the options never show without their question.
    const text = Math.min(lines(shown).length, Math.max(0, Math.min(1, room - 1), room - listRows(shown)));
    const rows = Math.min(listRows(shown), room - text);
    return { text, row: 1 + text, rows };
  };
  const hint = (shown: Page): string => {
    const parts = [
      ...(shown.question.options.length > 0 ? ["↑↓ choose"] : []),
      ...(shown.question.multiple === true ? ["space tick"] : []),
      current < pages.length - 1 ? "enter next" : "enter send",
      // A field takes Left, so its page names the other key.
      ...(current > 0 ? [onField(shown) ? "shift+tab back" : "← back"] : []),
      "esc cancel",
    ];
    return parts.join(" · ");
  };

  // The screen row of the field in the view, from the last layout.
  let fieldRow: number | undefined;
  const view: View = {
    contexts: ["question"],
    focusable: true,
    layout(size: Size): readonly Placement[] {
      const shown = page();
      const field = typing();
      fieldRow = undefined;
      if (field === undefined) return [];
      const { row, rows } = list(shown, size);
      const at = shown.cursor - top(shown, rows);
      if (at < 0 || at >= rows) return [];
      fieldRow = row + at;
      return [{ view: field, rect: { column: INDENT, row: fieldRow, width: size.width - INDENT, height: 1 } }];
    },
    paste: (text: string): boolean => typing()?.paste(text) ?? false,
    cursor(): Cursor | undefined {
      const at = fieldRow === undefined ? undefined : typing()?.cursor();
      return at === undefined || fieldRow === undefined
        ? undefined
        : { ...at, column: at.column + INDENT, row: at.row + fieldRow };
    },
    draw(canvas: Canvas): void {
      const shown = page();
      const open = count();
      let column = canvas.text(1, 0, `${sourceName(interaction.source)} · `, STYLE.meta);
      column = canvas.text(column, 0, shown.question.header, STYLE.title);
      if (pages.length > 1) column = canvas.text(column, 0, ` · ${current + 1}/${pages.length}`, STYLE.meta);
      if (open > 1) canvas.text(column, 0, ` · 1 of ${open}`, STYLE.meta);
      canvas.text(1, canvas.height - 1, hint(shown), STYLE.hint);
      const all = lines(shown);
      const { text, row, rows } = list(shown, canvas);
      for (let index = 0; index < text; index += 1) {
        // The last row of a cut question counts the lines that do not show. A single row shows the first line.
        const cut = index === text - 1 && text < all.length && text > 1;
        const line = cut ? `… ${all.length - index} more lines` : (all[index] ?? "");
        canvas.text(1, index + 1, clipped(line, canvas.width - 1), cut ? STYLE.meta : undefined);
      }
      const first = top(shown, rows);
      for (let at = 0; at < rows; at += 1) {
        const index = first + at;
        const option = shown.question.options[index];
        const marked = index === shown.cursor;
        canvas.text(0, row + at, marked ? "❯" : " ", STYLE.title);
        if (option === undefined) {
          // The field row. The field draws itself while the cursor is on it.
          if (!marked) {
            const text = shown.field?.state.text ?? "";
            const label = text === "" ? OTHER : shown.question.secret === true ? "••••" : text;
            canvas.text(INDENT, row + at, clipped(label, canvas.width - INDENT), STYLE.meta);
          }
          continue;
        }
        const tick = shown.question.multiple === true ? (shown.ticked.has(option.label) ? "[x] " : "[ ] ") : "";
        const after = canvas.text(INDENT, row + at, `${tick}${option.label}`, marked ? STYLE.subject : undefined);
        if (option.description) {
          canvas.text(after, row + at, `  ${clipped(option.description, canvas.width - after - 2)}`, STYLE.meta);
        }
      }
    },
    key,
  };
  const rows = Math.max(...pages.map((each) => 2 + lines(each).length + Math.min(listRows(each), LIST_ROWS)));
  return { view, rows };
}

export class ChatQuestions {
  readonly #chat: ChatSession;
  readonly #options: ChatQuestionsOptions;
  readonly #listeners = new Set<() => void>();
  // The first open request and its view. The other requests wait in order. A sent answer waits for the close.
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

  /** Answer the shown request once. A failed answer, as after an answer of another client, goes to `onError`. */
  #answer(response: InteractionResponse): void {
    const current = this.#current;
    const handle = this.#chat.handle;
    if (current === undefined || current.answered || handle === undefined) return;
    current.answered = true;
    try {
      handle.respond(current.id, response);
    } catch (error) {
      current.answered = false;
      this.#options.onError(error);
    }
  }

  /** Take the first open request. The requests of an ended handle show again after the next open. */
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
    callEach(this.#listeners);
  }
}
