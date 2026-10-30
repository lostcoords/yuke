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
  import type { SessionHandle, Sessions } from "yuke:plugins";
  import type { SessionId, SessionSettings } from "yuke:protocol";
  import type { Transcript } from "yuke:transcript";
  import type { StylePatch, TextDocument, View } from "yuke:tui";

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
