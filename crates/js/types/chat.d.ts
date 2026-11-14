// The declaration of the public module `yuke:chat`.

/**
 * The blocks of a chat, for the bundled chat and for a chat of a plugin.
 *
 * ```ts
 * const chat = new ChatSession(ctx.get("sessions"), { signal: mount.signal, id: saved });
 * chat.addChangeListener(() => tui.requestFrame());
 * if (chat.id !== undefined) chat.open(chat.id).catch((error) => ctx.notify("error", String(error)));
 * ```
 */
declare module "yuke:chat" {
  import type { Frozen, SessionHandle, Sessions } from "yuke:plugins";
  import type {
    Input,
    InputId,
    ModelReference,
    ProviderInfo,
    ReasoningLevel,
    SessionId,
    SessionSettings,
  } from "yuke:protocol";
  import type { Transcript } from "yuke:transcript";
  import type {
    Canvas,
    CanvasStyle,
    CommandItem,
    EditorState,
    Mount,
    OffsetRange,
    Rect,
    TextDocument,
    TextEditor,
    View,
  } from "yuke:tui";

  export interface ChatSessionOptions {
    /** Its abort ends the handle. */
    readonly signal: AbortSignal;
    /** The session to show. Without it, the chat has no session yet. Call `open` to show it. */
    readonly id?: SessionId | undefined;
  }

  /**
   * The session of one chat view, with no terminal interface: its id, its handle, its transcript, and the pages of its
   * history. It holds one handle at a time, and gives no notices: a failure rejects to the caller.
   */
  export class ChatSession {
    constructor(sessions: Sessions, options: ChatSessionOptions);
    /** The shown session. It stays after a failed open and after the end of its handle. */
    get id(): SessionId | undefined;
    /** The handle of the shown session, until its end, as by a close of another client. */
    get handle(): SessionHandle | undefined;
    /** The transcript of the shown session. Each open and each `leave` gives a new one. */
    get transcript(): Transcript;
    /** The transcript holds the first saved event. */
    get historyComplete(): boolean;
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
    /**
     * Show no session: end the hold of the shown session and start an empty transcript. The session itself goes on, and
     * a turn of it keeps running. The next `ensure` creates a session. Without a shown session, it does nothing.
     */
    leave(): void;
    /**
     * Load one page of history: the missing events of a gap first, else the page before the first held event. It does
     * not reject. A failure goes in `historyError`, and no later page loads until the next open.
     */
    loadOlderHistory(): Promise<void>;
    /**
     * Drop the older history from memory, so that the transcript holds the newest events, as after an open. It does
     * nothing until the transcript holds one page more than that, or while a page loads. `loadOlderHistory` loads the
     * dropped events again. Call it while the view shows the newest entries.
     */
    trimHistory(): void;
    /**
     * Call `listener` after each change: an open, an event, the end of the handle, or a page.
     */
    addChangeListener(listener: () => void): () => void;
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
    constructor(chat: ChatSession, editor: TextEditor, options: ChatComposerOptions);
    /** A send, a recall, or an attach has not ended. */
    get busy(): boolean;
    /** The editor shows an older message of the user. */
    get browsing(): boolean;
    /** `olderMessage()` has something to do: a recall, a browse, or an empty editor. */
    get canOlderMessage(): boolean;
    /** The waiting messages of the user in the queue of the session, oldest first. An input of a plugin is not one of them. */
    get waiting(): [InputId, Frozen<Input>][];
    /**
     * Send the draft. The draft of the send is the one after `handle()`, and the editor then empties. A refused input
     * comes back above the newer text, and the promise rejects. An empty draft does nothing. A send before the end of
     * another send or of an attach does nothing.
     */
    send(): Promise<void>;
    /**
     * Recall the newest waiting message into an empty editor, and each next older one above the recalled text. Without a
     * recall, an empty editor or a shown message gets an older message of the user. `"taken"` when a turn took the
     * message first.
     */
    olderMessage(): Promise<"taken" | undefined>;
    /** Show a newer message of the user, or the empty editor after the newest one. */
    newerMessage(): void;
    /**
     * Store `image` in the session of `handle()`, then put it at the caret of that time as `[image N]`. A send gives it
     * as a media block. `undefined` from `handle()` puts nothing, and a failed store rejects.
     */
    attachImage(image: { readonly bytes: Uint8Array; readonly mimeType: string }): Promise<void>;
    /** Put `draft` in the editor, and end a browse. A running recall puts its message above `draft` when it ends. */
    setDraft(draft: EditorState): void;
  }

  export interface ChatQuestionsOptions {
    /** Its abort ends the watch of the chat session. */
    readonly signal: AbortSignal;
    /** Gets the failure of an answer, as after an answer of another client. The question then takes an answer again. */
    readonly onError: (error: unknown) => void;
  }

  /** The view of a request, which takes the keys, and the most rows that it needs. */
  export interface ChatQuestion {
    readonly view: View;
    readonly rows: number;
  }

  /**
   * The first open request of a plugin in a chat session, as a view with one page per question. Up and Down move,
   * Space ticks, Enter answers and goes to the next page, and the last Enter sends. Left or Shift+Tab goes back. A
   * question without options and with `other` is a field, and `secret` masks that field. The owner binds the cancel key to `cancel()`. A caller places
   * the view, as the chat does in the place of the composer. A view answers once, and a refused answer can come again. The others wait in order. A request of an
   * ended handle shows after the next open.
   *
   * ```ts
   * const questions = new ChatQuestions(chat, { signal: mount.signal, onError: (error) => ctx.notify("error", String(error)) });
   * place(questions.current); // a request that is open already
   * questions.addChangeListener(() => place(questions.current));
   * ```
   */
  export class ChatQuestions {
    constructor(chat: ChatSession, options: ChatQuestionsOptions);
    /** The view of the first open request, or `undefined` without one. */
    get current(): ChatQuestion | undefined;
    /** Answer the shown request with a cancel. */
    cancel(): void;
    /** Call `listener` after each change of `current`. */
    addChangeListener(listener: () => void): () => void;
  }

  /** What a completion provider reads: the draft of a composer and the folder of its session. */
  export interface CompletionContext {
    /** The text of the draft. */
    readonly text: string;
    /** The caret in `text`, in UTF-16 units. */
    readonly caret: number;
    /** The folder of the session of the pane, else of its next session. */
    readonly cwd: string;
    /** It aborts when the draft or the caret changes, or the list ends. */
    readonly signal: AbortSignal;
  }

  /** One row of a completion list. */
  export interface CompletionItem {
    /** The left column. */
    readonly label: string;
    /** The dim text after the label. */
    readonly detail?: string | undefined;
    /** The parts of `label` that match, in a strong style. `fuzzyMatch` gives them. */
    readonly ranges?: readonly OffsetRange[] | undefined;
    /** Tab writes this text in place of `from` to `to` of the list. Enter writes it too when the item has no `run`. */
    readonly insert: string;
    /** Enter empties the draft and calls this. A `false` answer brings the draft back. */
    readonly run?: (() => boolean) | undefined;
  }

  /** The completions of the text from `from` to `to`, the best first. */
  export interface CompletionList {
    readonly from: number;
    /** The end of the text that an insert replaces. The default is the caret. */
    readonly to?: number | undefined;
    readonly items: readonly CompletionItem[];
  }

  /**
   * A source of completions for the draft of a composer. `complete` reads the text before the caret and gives a list,
   * or `undefined` or no items when the text is not its own. A list that it gives at once shows in the same frame.
   */
  export interface CompletionProvider {
    readonly complete: (context: CompletionContext) => CompletionList | undefined | Promise<CompletionList | undefined>;
  }

  /** The commands to list and run. `tui.commands` fits. */
  export interface SlashCommands {
    readonly list: () => readonly CommandItem[];
    readonly run: (name: string, args?: string) => boolean;
  }

  /**
   * The completions of the enabled commands with a `slash` word that match a draft of one word, such as `/mod`, the
   * best first. A draft with more text, such as `/mode fast`, matches only the word `mode` of a command with an
   * `argumentHint`, and Enter gives it `"fast"`. Tab writes the selected word, with a space when the command takes
   * text. Enter runs the command. The bundled chat adds this provider for `tui.commands`.
   */
  export function slashCompletions(commands: SlashCommands): CompletionProvider;

  export interface ChatCompletionsOptions {
    /** The providers to ask, the first one first. The first list with an item shows. */
    readonly providers: () => readonly CompletionProvider[];
    /** The folder of `CompletionContext.cwd`. */
    readonly cwd: () => string;
    /** Its abort removes the watch of the editor and aborts the open ask. */
    readonly signal: AbortSignal;
    /** While this gives `false`, the list shows nothing and takes no key. */
    readonly enabled: () => boolean;
    /** Called when a list comes later than the change of the draft, so the owner asks for a frame. */
    readonly onChange: () => void;
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
   *   cwd: () => folder,
   *   signal: mount.signal,
   *   enabled: () => true,
   *   onChange: () => tui.requestFrame(),
   *   onError: (error) => ctx.notify("error", String(error)),
   * });
   * // in layout: { view: completions.view, rect: { column: 0, row: editorRow - completions.rows, width, height: completions.rows } }
   * ```
   */
  export class ChatCompletions {
    constructor(editor: TextEditor, options: ChatCompletionsOptions);
    /** The count of rows that the list needs now: at most 6, and 0 without a list. */
    get rows(): number;
    /** The view of the list. A place with fewer rows than `rows` scrolls the list to the selected item. */
    readonly view: View;
  }

  /** What `ChatWorking.text` shows. */
  export interface ChatWorkingTextOptions {
    /** The key of the interrupt hint. */
    readonly cancelKey?: string | undefined;
    /** The key of the background hint. The hint shows when a tool call has waited for a job for two seconds. */
    readonly backgroundKey?: string | undefined;
    /** The columns of the text. A long phase is clipped. A narrow row drops the background hint, then the interrupt hint. */
    readonly width?: number | undefined;
  }

  export interface ChatWorkingOptions {
    /** Its abort ends the watch of the chat session. */
    readonly signal: AbortSignal;
    /** The clock in milliseconds, as `() => tui.now()`. */
    readonly now: () => number;
  }

  /**
   * The activity row of an active turn shows a spinner, a phase label, elapsed time, and a retry countdown.
   * The default label is `Working…`, including during tool calls, without tool names or arguments.
   * The time counts from the first active state that this instance observes with a live handle, not from tool start.
   * Another session or the end of the handle stops the count. This block asks for no frame: while `active`, the owner draws
   * again each `frameMs`.
   *
   * ```ts
   * const working = new ChatWorking(chat, { signal: mount.signal, now: () => tui.now() });
   * let stop: (() => void) | undefined;
   * const tick = () => {
   *   stop?.();
   *   stop = working.active && !mount.signal.aborted ? tui.addTimer(working.frameMs, tick) : undefined;
   * };
   * working.addChangeListener(tick);
   * tick();
   * const row = working.text({ cancelKey: "esc" }); // in draw
   * if (row !== undefined) canvas.text(0, 0, `${row.spinner} ${row.text}`);
   * ```
   */
  export class ChatWorking {
    constructor(chat: ChatSession, options: ChatWorkingOptions);
    /** A turn of the shown session runs. */
    get active(): boolean;
    /** The time of one frame of the spinner, in milliseconds. */
    get frameMs(): number;
    /** The spinner and the text now, or `undefined` while no turn runs. */
    text(options?: ChatWorkingTextOptions): { readonly spinner: string; readonly text: string } | undefined;
    /** Call `listener` after each change of `active`. */
    addChangeListener(listener: () => void): () => void;
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
  export class ChatDocument {
    /** The document `id` with the fold choices `folds`: `true` is open. */
    constructor(id: string, folds?: Iterable<readonly [string, boolean]>);
    /** The fold choices, for a saved state. */
    get folds(): [string, boolean][];
    /** Open or fold the entry `id`, a tool or a thought with text. `false` when that entry has no fold. */
    toggle(transcript: Transcript, id: string): boolean;
    /** Open each loaded tool when one of them is folded. Otherwise, fold each one. A later tool starts folded. */
    toggleTools(transcript: Transcript): void;
    /** The document of `transcript`. The same document object comes back while no item changed. */
    project(transcript: Transcript): TextDocument;
  }

  /** The presentation of a transcript in one chat pane. `ChatDocument` is the default presentation. */
  export interface ChatPresentation {
    /** The fold choices that the pane saves. `true` is open. */
    readonly folds: readonly (readonly [string, boolean])[];
    /**
     * Open or fold the item `id`, which can be a group of this presentation. Give `false` when that item has no fold.
     * After `true`, the pane shows the first `label` section of the item, if the item has one.
     */
    readonly toggle: (transcript: Transcript, id: string) => boolean;
    /** Open or fold all tools. */
    readonly toggleTools: (transcript: Transcript) => void;
    /**
     * The document of `transcript`. Keep each item id across updates. Keep the object of each unchanged item.
     * The pane also calls this function once a second while a tool runs, so a duration can advance.
     */
    readonly project: (transcript: Transcript) => TextDocument;
  }

  /** What a chat pane gives the factory of `setPresentation`. */
  export interface ChatPresentationOptions {
    /** The id of the document. Pass it on, and do not read a meaning from it. */
    readonly id: string;
    /** The saved fold choices. */
    readonly folds: readonly (readonly [string, boolean])[] | undefined;
    /** This signal aborts when the pane shows another session, replaces the presentation, or closes. */
    readonly signal: AbortSignal;
    /** Ask the pane to project the transcript again, after the state of the presentation changes. */
    readonly requestUpdate: () => void;
  }

  /** One row of `composerRows`. The chat cuts a longer text to the width and ends it with `…`. */
  export interface ComposerRow {
    readonly text: string;
    readonly style?: CanvasStyle | undefined;
  }

  /** The side of the composer where a view shows. */
  export type ComposerPlace = "above" | "below";

  /** A chat pane. Each field reads the current state. */
  export interface ChatPane {
    readonly view: View;
    /** The editor of the drafts of the pane. A key handler or a decoration of a plugin goes here. */
    readonly composer: TextEditor;
    readonly session: SessionId | undefined;
    readonly transcript: Transcript;
    /** A turn of the session runs. */
    readonly running: boolean;
  }

  /** A view that says how many whole rows it wants at `width`. A `TextEditor` fits. Each layout calls it, so keep it cheap. */
  export interface ComposerView extends View {
    readonly heightFor: (width: number) => number;
  }

  /**
   * A view of plain text rows, for `addComposerView`. Each layout and draw calls `source`, so keep it cheap. With less
   * room, the first rows show.
   */
  export function composerRows(source: (width: number) => readonly ComposerRow[]): ComposerView;

  /** The whole cells around the input of a chat pane. A missing side has no cells. */
  export interface Insets {
    readonly top?: number | undefined;
    readonly right?: number | undefined;
    readonly bottom?: number | undefined;
    readonly left?: number | undefined;
  }

  /** The chat pane that a frame gets at each layout. */
  export interface ComposerContext extends ChatPane {
    /** The width of the pane. */
    readonly width: number;
    /** The view in the input area: the composer, a question, or the row of a read-only session. */
    readonly kind: "composer" | "question" | "readOnly";
  }

  /** The chat pane that a frame gets at each draw. */
  export interface ComposerFrameContext extends ComposerContext {
    /** The input view or a view inside it has the focus. */
    readonly focused: boolean;
    /** The rect of the input view on the canvas. */
    readonly inputRect: Rect;
  }

  /**
   * The look of the area around the input of a chat pane. The default frame is one rule above the input and one below.
   *
   * ```ts
   * chat.setComposerFrame({
   *   inset: () => ({ left: 1 }),
   *   draw: (canvas, pane) => {
   *     for (let row = 0; row < canvas.height; row += 1) canvas.text(0, row, "┃", { fg: pane.focused ? "accent" : "fg" });
   *   },
   * });
   * ```
   */
  export interface ComposerFrame {
    /**
     * The cells around the input. The pane calls this function at each layout, so keep it cheap. In a short pane, the
     * rows below the input go first, then the rows above it.
     */
    readonly inset: (pane: ComposerContext) => Insets;
    /** The `View.style` of the frame: it fills the input and the insets, and it is the base of the input styles. */
    readonly style?: CanvasStyle | undefined;
    /** Draw before the input. The canvas covers the input and its insets. */
    readonly draw: (canvas: Canvas, pane: ComposerFrameContext) => void;
  }

  /** What a chat pane shows in place of the composer, for a session that the pane only shows. */
  export interface ChatReadOnly {
    /** The row in place of the composer. The chat adds the key that goes back. */
    readonly text: string;
    /** The session that the pane shows again at that key. */
    readonly back: SessionId;
  }

  /** The model and the reasoning level of a chat. */
  export interface ChatModelChoice {
    readonly model: ModelReference;
    readonly reasoning: ReasoningLevel;
  }

  /** What a model picker reads. */
  export interface ChatModelPickerContext {
    /** The ready providers and their models. */
    readonly providers: readonly ProviderInfo[];
    /** The settings of the session of the pane, or `undefined` for a pane without a session. */
    readonly current: Frozen<SessionSettings> | undefined;
    /** The saved choice for a new session, or `undefined` before the first choice. */
    readonly saved: ChatModelChoice | undefined;
    /** It aborts when the pane closes. */
    readonly signal: AbortSignal;
  }

  /** A model picker. `undefined` cancels the choice. */
  export type ChatModelPicker = (context: ChatModelPickerContext) => Promise<ChatModelChoice | undefined>;

  /**
   * The service `chat` of the chat plugin: which chat pane shows which session. Without the terminal interface, no
   * pane exists.
   */
  export interface ChatService {
    /**
     * Show the session `id` in the focused chat pane, or in a new chat pane when the focused pane is no chat pane. The
     * pane keeps its draft for its old session. A pane without a session carries its draft to `id`. It rejects when the
     * open fails or the pane is busy, as with a send.
     */
    readonly show: (id: SessionId) => Promise<void>;
    /** The session of the chat pane `view`, or `undefined` for a pane without a session or no chat pane. */
    readonly session: (view: View) => SessionId | undefined;
    /**
     * The folder of the chat pane `view`: the folder of its session, else the folder of its next session. `undefined`
     * for no chat pane.
     */
    readonly folder: (view: View) => string | undefined;
    /**
     * Show no session in the focused chat pane, as `/new` does. The session before keeps its work. `options.cwd` is
     * the folder of the next session. Without it, the next session starts in the folder of the session before. A busy
     * pane does nothing. It throws when the focused pane is no chat pane.
     */
    readonly newSession: (options?: { readonly cwd?: string | undefined }) => void;
    /**
     * Create the session of the focused chat pane, or open it again after the end of its handle, and give its id. It
     * sends no message, and the draft and the attachments stay. `undefined` after a cancel of the model choice. It
     * rejects when the focused pane is no chat pane or is busy.
     */
    readonly ensureSession: () => Promise<SessionId | undefined>;
    /**
     * Let the user choose the model and the reasoning of the focused chat pane, with `picker` or the picker of
     * `setModelPicker`. The chat checks the choice against the ready providers, saves it for new sessions, and saves it
     * in the session of the pane. A busy pane does nothing. It rejects when the focused pane is no chat pane.
     */
    readonly chooseModel: (picker?: ChatModelPicker) => Promise<void>;
    /**
     * Replace the model picker of each chat pane: of `/model`, and of the first message without a saved choice. The
     * last call wins, and the returned function brings back the picker before it.
     */
    readonly setModelPicker: (picker: ChatModelPicker) => () => void;
    /**
     * Call `listener` after a chat pane moves to another session or to no session. It gets no call for a pane that starts on a session,
     * or for a close.
     */
    readonly addChangeListener: (listener: (view: View) => void) => () => void;
    /**
     * Call `watch` once for each chat pane, now and later. Its `signal` aborts when the pane closes or the returned
     * function runs, so a plugin ends its work on that pane there. A throw of `watch` gives a notice.
     *
     * ```ts
     * chat.addPaneWatcher((pane, signal) => pane.composer.extend(signal).addKeyHandler(onKey, "beforeKeymap"));
     * ```
     */
    readonly addPaneWatcher: (watch: (pane: ChatPane, signal: AbortSignal) => void) => () => void;
    /**
     * Add a source of completions for the composer of each chat pane. The newest provider is asked first, so a plugin
     * can take the place of an older one. The bundled chat adds the slash commands of `tui.commands`.
     *
     * ```ts
     * chat.addCompletionProvider({
     *   complete: (context) => {
     *     const word = /(?:^|\s)#(\w*)$/.exec(context.text.slice(0, context.caret));
     *     if (word === null) return undefined;
     *     return { from: context.caret - word[1].length - 1, items: tags.map((tag) => ({ label: `#${tag}`, insert: `#${tag} ` })) };
     *   },
     * });
     * ```
     */
    readonly addCompletionProvider: (provider: CompletionProvider) => () => void;
    /**
     * Add a view on one side of the composer of each chat pane. `create` runs once per pane, at a layout. A close of the
     * pane or the returned function ends `mount`. A view that closes `mount` stays closed in that pane. After a change of
     * its data, a plugin calls `tui.requestFrame()`.
     *
     * - `above`: The view shows below the transcript and above the waiting messages, the working row, and the command list.
     *   The views share the free rows, at most half the rows above the frame of the input.
     * - `below`: The view shows on the last rows of the pane, and the composer moves up. The views share at most half the
     *   pane height.
     *
     * The views show in add order. Each gets its height or the rows that remain, and a view reads its place in
     * `canvas.height`. A height of 0 places no view.
     *
     * ```ts
     * chat.addComposerView("below", (mount, pane) =>
     *   composerRows(() => (open(pane.session) ? [{ text: `${count(pane.session)} questions`, style: { fg: "accent" } }] : [])),
     * );
     * ```
     */
    readonly addComposerView: (
      place: ComposerPlace,
      create: (mount: Mount, pane: ChatPane) => ComposerView,
    ) => () => void;
    /**
     * Add a source of read-only sessions for each chat pane. `source` gets the session of a pane at each layout and each
     * key, so a source must be cheap and synchronous. For a session with an answer, the pane shows a row in place of the
     * composer. The pane sends no message, shows no question, and does not cancel the turn. Its transcript still scrolls,
     * and the key of `chat:interrupt` shows the session `back`. The first source in add order that answers for a session
     * wins, and the returned function removes only this source. A client of `yuke --rpc` can still send input to the
     * session.
     *
     * ```ts
     * chat.addReadOnly((session) => (isChild(session) ? { text: "A child session", back: parentOf(session) } : undefined));
     * ```
     */
    readonly addReadOnly: (source: (session: SessionId) => ChatReadOnly | undefined) => () => void;
    /**
     * Replace the frame around the input of each chat pane. The last call wins, and the returned function brings
     * back the frame before it.
     */
    readonly setComposerFrame: (frame: ComposerFrame) => () => void;
    /**
     * Replace the presentation of the transcript in each chat pane. A pane calls `factory` each time that it creates a
     * presentation, also for one session. The last call wins, and the returned function brings back the factory
     * before it.
     *
     * ```ts
     * chat.setPresentation((options) => new GroupedTools(options.id, options.folds));
     * ```
     */
    readonly setPresentation: (factory: (options: ChatPresentationOptions) => ChatPresentation) => () => void;
    /**
     * Replace the view that each chat pane shows while its transcript is empty: a pane without a session, or a session
     * without history, while no message waits and no turn runs. The view draws over the transcript area, and it reads
     * its size from the canvas. `create` runs once per pane, when the pane first shows the view. The last call wins,
     * and the returned function brings back the view before it. The default shows the icon, the version, the model,
     * the folder, and the way to start. Terminal.app shows the lines without the icon. The option `emptyView: false` of
     * the chat turns the header off.
     *
     * ```ts
     * chat.setEmptyView(() => ({ draw: (canvas) => canvas.text(1, 1, "Ask me anything.") }));
     * ```
     */
    readonly setEmptyView: (create: (mount: Mount, pane: ChatPane) => View) => () => void;
  }
}
