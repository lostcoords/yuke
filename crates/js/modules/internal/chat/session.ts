/** `ChatSession` of the chat: the session that one chat view shows, with its transcript and its pages of history. */

import type { ChatSessionOptions } from "yuke:chat";
import type { EventsPage, SessionHandle, Sessions } from "yuke:plugins";
import type { SessionId, SessionSettings } from "yuke:protocol";
import { Transcript } from "yuke:transcript";

/** The count of saved events that an open gets. Older events come in pages. */
const TAIL = 200;

/** The most saved events of one page of history. */
const PAGE = 100;

/**
 * The session of one chat view, with no terminal interface: its id, its handle, its transcript, and the pages of its
 * history. It holds one handle at a time, and gives no notices: a failure rejects to the caller.
 */
export class ChatSession {
  readonly #sessions: Sessions;
  readonly #signal: AbortSignal;
  readonly #listeners = new Set<() => void>();
  #id: SessionId | undefined;
  #handle: SessionHandle | undefined;
  #transcript = new Transcript();
  // The end of the hold of the current handle.
  #release: AbortController | undefined;
  // The last open, so the next open and `ensure` wait for it.
  #opening: Promise<void> | undefined;
  // The running `ensure`, so a second call shares its first session.
  #ensuring: Promise<SessionHandle | undefined> | undefined;
  #loading = false;
  #complete = false;
  #historyError: unknown;

  constructor(sessions: Sessions, options: ChatSessionOptions) {
    this.#sessions = sessions;
    this.#signal = options.signal;
    this.#id = options.id;
  }

  /** The shown session. It stays after a failed open and after the end of its handle. */
  get id(): SessionId | undefined {
    return this.#id;
  }

  /** The handle of the shown session, until its end, as by a close of another client. */
  get handle(): SessionHandle | undefined {
    return this.#handle;
  }

  /** The transcript of the shown session. Each open and each `leave` gives a new one. */
  get transcript(): Transcript {
    return this.#transcript;
  }

  /** The transcript holds the first saved event. */
  get historyComplete(): boolean {
    return this.#complete;
  }

  /** The failure of a page of history. No other page loads after it, until the next open. */
  get historyError(): unknown {
    return this.#historyError;
  }

  /**
   * Open the session `id` and show it, in place of the shown one. The shown session stays when the open fails before
   * the snapshot. An end of the handle after the snapshot leaves `id` shown without a handle. One open runs at a time.
   * An open of the shown session with a live handle does nothing.
   */
  open(id: SessionId): Promise<void> {
    const previous = this.#opening;
    const next = (async () => {
      // One open at a time, so the last one wins. The failure of an earlier open belongs to its caller. Without an
      // earlier open, the request goes out at once.
      if (previous !== undefined) {
        await previous.then(
          () => {},
          () => {},
        );
      }
      if (this.#signal.aborted) throw this.#signal.reason;
      if (id === this.#id && this.#handle !== undefined) return;
      // The end of the owner ends the hold at once, also during the open.
      const release = new AbortController();
      const end = (): void => release.abort();
      this.#signal.addEventListener("abort", end, { once: true });
      release.signal.addEventListener("abort", () => this.#signal.removeEventListener("abort", end), { once: true });
      // The target fills its own transcript. The snapshot comes only after a successful open, so the pane shows the
      // target from its snapshot on, and a failure before it leaves the shown session as it is.
      const transcript = new Transcript();
      let current = false;
      let handle: SessionHandle;
      try {
        handle = await this.#sessions.open(id, {
          tail: TAIL,
          signal: release.signal,
          onEvent: (event) => {
            if (!current) {
              current = true;
              this.#show(id, transcript, release);
            }
            transcript.apply(event);
            this.#changed();
            if (transcript.missingEvents !== undefined) void this.loadOlderHistory();
          },
        });
      } catch (error) {
        release.abort();
        // An end after the snapshot, as by a close of another client, leaves the target shown without a handle.
        if (!current || this.#signal.aborted) throw error;
        return;
      }
      if (release.signal.aborted) throw this.#signal.reason;
      this.#handle = handle;
      handle.signal.addEventListener(
        "abort",
        () => {
          release.abort();
          // A later open ends the handle too, and then the shown handle is another one.
          if (this.#handle !== handle) return;
          this.#handle = undefined;
          if (!this.#signal.aborted) this.#changed();
        },
        { once: true },
      );
      this.#changed();
    })();
    this.#opening = next;
    const done = (): void => {
      if (this.#opening === next) this.#opening = undefined;
    };
    next.then(done, done);
    return next;
  }

  /**
   * The handle of the shown session. It opens the session again after the end of its handle. Without a session, it
   * creates one with `settings()`. `undefined` when `settings()` gives `undefined`. A call during another call gets
   * the result of the first call. It rejects with the failure of a running open.
   */
  ensure(settings: () => Promise<SessionSettings | undefined>): Promise<SessionHandle | undefined> {
    if (this.#ensuring !== undefined) return this.#ensuring;
    const next = (async () => {
      while (this.#opening !== undefined) await this.#opening;
      if (this.#signal.aborted) throw this.#signal.reason;
      if (this.#handle !== undefined) return this.#handle;
      if (this.#id === undefined) {
        const chosen = await settings();
        if (chosen === undefined || this.#signal.aborted) return undefined;
        const id = await this.#sessions.create(chosen);
        if (this.#signal.aborted) return undefined;
        await this.open(id);
      } else await this.open(this.#id);
      if (this.#handle === undefined) throw new Error(`the session ${this.#id} closed`);
      return this.#handle;
    })();
    this.#ensuring = next;
    const done = (): void => {
      if (this.#ensuring === next) this.#ensuring = undefined;
    };
    next.then(done, done);
    return next;
  }

  /**
   * Show no session: end the hold of the shown session and start an empty transcript. The session itself goes on, and
   * a turn of it keeps running. The next `ensure` creates a session. Without a shown session, it does nothing.
   */
  leave(): void {
    if (this.#id === undefined) return;
    this.#show(undefined, new Transcript(), undefined);
    this.#changed();
  }

  /**
   * Load one page of history: the missing events of a gap first, else the page before the first held event. It does
   * not reject. A failure goes in `historyError`, and no later page loads until the next open.
   */
  async loadOlderHistory(): Promise<void> {
    const id = this.#id;
    // Before a snapshot, the transcript has no first event and no missing events, so no page loads.
    if (id === undefined || this.#loading || this.#historyError !== undefined) return;
    const transcript = this.#transcript;
    const missing = transcript.missingEvents;
    const firstEventNumber = transcript.firstEventNumber;
    let page: EventsPage;
    if (missing !== undefined) page = { ...missing, limit: Math.min(PAGE, missing.limit) };
    else if (this.#complete || firstEventNumber === undefined) return;
    else page = { before: firstEventNumber, limit: PAGE };
    this.#loading = true;
    let failure: { readonly error: unknown } | undefined;
    let events: Awaited<ReturnType<Sessions["events"]>> = [];
    try {
      events = await this.#sessions.events(id, page);
    } catch (error) {
      failure = { error };
    }
    // A later open or the end of the owner makes the page stale.
    if (this.#transcript !== transcript || this.#signal.aborted) return;
    this.#loading = false;
    if (failure !== undefined) this.#historyError = failure.error;
    else {
      transcript.insert(events);
      // A page that adds nothing older ends the history, so a load never repeats it.
      if (missing === undefined && transcript.firstEventNumber === firstEventNumber) this.#complete = true;
    }
    this.#changed();
  }

  /**
   * Drop the older history from memory, so that the transcript holds the newest events, as after an open. It does
   * nothing until the transcript holds one page more than that, or while a page loads. `loadOlderHistory` loads the
   * dropped events again. Call it while the view shows the newest entries.
   */
  trimHistory(): void {
    const transcript = this.#transcript;
    // A page that loads now would add the dropped events again. The slack of one page keeps a trim rare.
    if (this.#loading || transcript.eventCount <= TAIL + PAGE) return;
    transcript.trim(TAIL);
    this.#complete = false;
    this.#changed();
  }

  /**
   * Call `listener` after each change: an open, an event, the end of the handle, or a page.
   */
  addChangeListener(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** Switch to `id`, or to no session, and its transcript, and end the hold of the session before. */
  #show(id: SessionId | undefined, transcript: Transcript, release: AbortController | undefined): void {
    const old = this.#release;
    this.#id = id;
    this.#handle = undefined;
    this.#transcript = transcript;
    this.#release = release;
    this.#loading = false;
    this.#complete = false;
    this.#historyError = undefined;
    old?.abort();
  }

  #changed(): void {
    for (const listener of this.#listeners) listener();
  }
}
