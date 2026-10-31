// The declaration of the public module `yuke:chat`.

/**
 * The blocks of a chat, for the bundled chat and for a chat of a plugin.
 *
 * ```ts
 * const chat = new ChatSession(ctx.get("sessions"), mount.signal, saved);
 * chat.onChange(() => tui.requestFrame());
 * if (chat.id !== undefined) chat.open(chat.id).catch((error) => ctx.notify("error", String(error)));
 * ```
 */
declare module "yuke:chat" {
  import type { Frozen, SessionHandle, Sessions } from "yuke:plugins";
  import type { Input, InputId, SessionId, SessionSettings } from "yuke:protocol";
  import type { Transcript } from "yuke:transcript";
  import type { CommandItem, EditorState, StylePatch, TextDocument, TextEditor, View } from "yuke:tui";

  /**
   * The session of one chat view, with no terminal interface: its id, its handle, its transcript, and the pages of its
   * history. It holds one handle at a time, and gives no notices: a failure rejects to the caller.
   */
  export class ChatSession {
    /** A chat of the session `id`, or of no session yet. The abort of `signal` ends the handle. Call `open` to show `id`. */
    constructor(sessions: Sessions, signal: AbortSignal, id?: SessionId);
    /** The shown session. It stays after a failed open and after the end of its handle. */
    get id(): SessionId | undefined;
    /** The handle of the shown session, until its end, as by a close of another client. */
    get handle(): SessionHandle | undefined;
    /** The transcript of the shown session. Each open gives a new one. */
    get transcript(): Transcript;
    /** The transcript holds the first saved event. */
    get complete(): boolean;
    /** The failure of a page of history. No other page loads after it, until the next open. */
    get historyError(): unknown;
    /**
     * Open the session `id` and show it, in place of the shown one. The shown session stays when the open fails before
     * the snapshot. An end of the handle after the snapshot leaves `id` shown without a handle. One open runs at a time.
     * An open of the shown session with a live handle does nothing.
     */
    open(id: SessionId): Promise<void>;
    /**
     * The handle of the shown session. It opens the session again after the end of its handle. Without a session, it
     * creates one with `settings()`. `undefined` when `settings()` gives `undefined`. A call during another call gets
     * the result of the first call. It rejects with the failure of a running open.
     */
    ensure(settings: () => Promise<SessionSettings | undefined>): Promise<SessionHandle | undefined>;
    /** Load one page of history: the missing events of a gap first, else the page before the first held event. */
    older(): Promise<void>;
    /** Call `listener` after each change: an open, an event, the end of the handle, or a page. */
    onChange(listener: () => void): () => void;
  }

  export interface ChatComposerOptions {
    /** The handle for a send. `undefined` cancels the send, and the draft stays. */
    readonly handle: () => Promise<SessionHandle | undefined>;
    /** Its abort removes the watch of the editor by the composer. */
    readonly signal: AbortSignal;
  }

  /**
   * The behavior of a composer on a `TextEditor`: the send of its draft, the recall of a waiting message, and the
   * history of the messages of the user. It gives no notices: a failure rejects to the caller. One composer owns its
   * editor: two composers on one editor send one draft twice.
   *
   * ```ts
   * const composer = new ChatComposer(chat, editor, { handle: () => chat.ensure(pick), signal: mount.signal });
   * // enter: composer.send()   up: composer.older()   down: composer.newer()
   * ```
   */
  export class ChatComposer {
    constructor(chat: ChatSession, editor: TextEditor, options: ChatComposerOptions);
    /** A send or a recall runs. */
    get busy(): boolean;
    /** The editor shows an older message of the user. */
    get browsing(): boolean;
    /** `older()` has something to do: a recall, a browse, or an empty editor. */
    get canOlder(): boolean;
    /** The waiting messages of the user, oldest first. An input of a plugin is not one of them. */
    get waiting(): [InputId, Frozen<Input>][];
    /**
     * Send the draft. The draft of the send is the one after `handle()`, and the editor then empties. A refused input
     * comes back above the newer text, and the promise rejects. An empty draft or a running send does nothing.
     */
    send(): Promise<void>;
    /**
     * Recall the newest waiting message into an empty editor, and each next older one above the recalled text. Without a
     * recall, an empty editor or a shown message gets an older message of the user. `"taken"` when a turn took the
     * message first.
     */
    older(): Promise<"taken" | undefined>;
    /** Show a newer message of the user, or the empty editor after the newest one. */
    newer(): void;
    /** Put `draft` in the editor, and end a browse. A running recall puts its message above `draft` when it ends. */
    setDraft(draft: EditorState): void;
  }

  export interface ChatQuestionsOptions {
    /** Its abort ends the watch of the chat session. */
    readonly signal: AbortSignal;
    /** Gets the failure of an answer, as after an answer of another client. The question then takes an answer again. */
    readonly failed: (error: unknown) => void;
  }

  /** The view of a question: `view` to place, `focus` to take the keys, and the most rows that it needs. */
  export interface ChatQuestion {
    readonly view: View;
    readonly focus: View;
    readonly rows: number;
  }

  /**
   * The first open question of a plugin in a chat session, as a view: a confirm takes `y` or `n`, a select is a picker,
   * and an input is a field that masks a secret. The chat places the view, as in the place of the composer or in a
   * modal. A view answers once, and a refused answer can come again. The others wait in order. A question of an ended
   * handle shows after the next open.
   *
   * ```ts
   * const questions = new ChatQuestions(chat, { signal: mount.signal, failed: (error) => ctx.notify("error", String(error)) });
   * place(questions.current); // a question that is open already
   * questions.onChange(() => place(questions.current));
   * ```
   */
  export class ChatQuestions {
    constructor(chat: ChatSession, options: ChatQuestionsOptions);
    /** The view of the first open question, or `undefined` without one. */
    get current(): ChatQuestion | undefined;
    /** Answer the shown question with a cancel. */
    cancel(): void;
    /** Call `listener` after each change of `current`. */
    onChange(listener: () => void): () => void;
  }

  export interface ChatCommandsOptions {
    /** The commands to list and run. `tui.commands` fits. */
    readonly commands: { readonly list: () => readonly CommandItem[]; readonly run: (name: string) => boolean };
    /** Its abort removes the watch of the editor. */
    readonly signal: AbortSignal;
    /** While this gives `false`, the list shows nothing and takes no key. */
    readonly enabled: () => boolean;
  }

  /**
   * A list of the enabled commands that match a draft of one slash word, such as `/mod`. The list shows above a
   * composer. Up and Down move the selection. Enter runs the selected command and empties the editor. Esc hides the list
   * until the next edit. A draft with no match stays a message.
   *
   * ```ts
   * const commands = new ChatCommands(editor, { commands: tui.commands, signal: mount.signal, enabled: () => true });
   * // in layout: { view: commands.view, rect: { column: 0, row: editorRow - commands.rows, width, height: commands.rows } }
   * ```
   */
  export class ChatCommands {
    constructor(editor: TextEditor, options: ChatCommandsOptions);
    /** The count of rows that the list needs now: at most 6, and 0 without a match. */
    get rows(): number;
    /** The view of the list. A place with fewer rows than `rows` scrolls the list to the selected command. */
    readonly view: View;
  }

  export interface ChatWorkingOptions {
    /** Its abort ends the watch of the chat session. */
    readonly signal: AbortSignal;
    /** The clock in milliseconds, as `() => tui.now()`. */
    readonly now: () => number;
  }

  /**
   * The working row of a running turn: a spinner, the phase, the elapsed time, and a retry countdown. The time counts
   * from the first running state with a live handle. Another session or the end of the handle stops the count. The chat
   * draws the text again each `frameMs` while `active`.
   *
   * ```ts
   * const working = new ChatWorking(chat, { signal: mount.signal, now: () => tui.now() });
   * const row = working.text("esc"); // in draw
   * if (row !== undefined) canvas.text(0, 0, `${row.spinner} ${row.text}`);
   * ```
   */
  export class ChatWorking {
    constructor(chat: ChatSession, options: ChatWorkingOptions);
    /** A turn of the shown session runs. */
    get active(): boolean;
    /** The time of one frame of the spinner, in milliseconds. */
    get frameMs(): number;
    /** The spinner and the text now, with `cancelKey` as the interrupt hint, or `undefined` while no turn runs. */
    text(cancelKey?: string): { readonly spinner: string; readonly text: string } | undefined;
    /** Call `listener` after each change of `active`. */
    onChange(listener: () => void): () => void;
  }

  /**
   * The default look of the style groups that `ChatDocument` draws with, such as `chat.user` and `chat.title`. A chat
   * without the bundled chat sets them: `for (const [name, style] of Object.entries(chatStyles)) tui.styles.set(name, style)`.
   */
  export const chatStyles: Readonly<Record<string, StylePatch>>;

  /**
   * The default look of a conversation, as a text document for a `TextView`: user messages, Markdown answers, thoughts
   * and tool calls that fold, diffs, and the failure of a running turn. Thoughts and tools start folded.
   *
   * ```ts
   * const document = new ChatDocument(`session:${id}`);
   * const view = new TextView({ document: document.project(chat.transcript) });
   * chat.onChange(() => view.setDocument(document.project(chat.transcript)));
   * ```
   */
  export class ChatDocument {
    /** The document `key` with the fold choices `folds`: `true` is open. */
    constructor(key: string, folds?: Iterable<readonly [string, boolean]>);
    /** The fold choices, for a saved state. */
    get folds(): [string, boolean][];
    /** Open or fold the entry `key`, a tool or a thought with text. `false` when that entry has no fold. */
    toggle(transcript: Transcript, key: string): boolean;
    /** Open each loaded tool when one of them is folded. Otherwise, fold each one. A later tool starts folded. */
    toggleTools(transcript: Transcript): void;
    /** The document of `transcript`. The same document object comes back while no item changed. */
    project(transcript: Transcript): TextDocument;
  }

  /**
   * The service `chat` of the chat plugin: which chat pane shows which session. Without the terminal interface, no
   * pane exists.
   */
  export interface ChatService {
    /**
     * Show the session `id` in the focused chat pane, or in a new chat pane when the focused pane is no chat pane. The
     * pane keeps its draft for its old session. It rejects when the open fails or the pane is busy, as with a send.
     */
    readonly show: (id: SessionId) => Promise<void>;
    /** The session of the chat pane `view`, or `undefined` for a pane without a session or no chat pane. */
    readonly session: (view: View) => SessionId | undefined;
    /** Call `listener` after each change of the session of a chat pane. A throw removes the listener and reports it. */
    readonly onChange: (listener: (view: View) => void) => () => void;
  }
}
