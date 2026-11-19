// The declaration of the public module `yuke:chat`.

/**
 * The types of the chat plugin: the service `chat` of `ctx.get("chat")`, and the types that it takes and gives. The
 * module has no values.
 *
 * ```ts
 * const chat = ctx.get("chat");
 * chat?.addPaneWatcher((pane, signal) => pane.composer.extend(signal).addKeyHandler(onKey, "beforeKeymap"));
 * ```
 */
declare module "yuke:chat" {
  import type { SessionId } from "yuke:protocol";
  import type { Transcript } from "yuke:transcript";
  import type { Canvas, CanvasStyle, Mount, OffsetRange, Rect, TextDocument, TextEditor, View } from "yuke:tui";

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
     * chat.addComposerView("below", (mount, pane) => ({
     *   heightFor: () => 1,
     *   draw: (canvas) => canvas.text(0, 0, `${count(pane.session)} questions`, { fg: "accent" }),
     * }));
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
