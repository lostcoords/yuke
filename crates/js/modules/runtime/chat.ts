/** The code of the public module `yuke:chat`. Its declaration is `types/chat.d.ts`, and the check at the end compares the two. */

import { ChatCommands } from "yuke:internal/chat/commands";
import { ChatComposer } from "yuke:internal/chat/composer";
import { ChatDocument } from "yuke:internal/chat/document";
import { ChatQuestions } from "yuke:internal/chat/questions";
import { STYLES as chatStyles } from "yuke:internal/chat/rows";
import { ChatWorking } from "yuke:internal/chat/working";
import type { EventsPage, SessionHandle, Sessions } from "yuke:plugins";

export { ChatCommands, ChatComposer, ChatDocument, ChatQuestions, ChatWorking, chatStyles };

import type { SessionId, SessionSettings } from "yuke:protocol";
import { Transcript } from "yuke:transcript";

/** The count of saved events that an open gets. Older events come in pages. */
const TAIL = 200;

/** The most saved events of one page of history. */
const PAGE = 100;

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

  constructor(sessions: Sessions, signal: AbortSignal, id?: SessionId) {
    this.#sessions = sessions;
    this.#signal = signal;
    this.#id = id;
  }

  get id(): SessionId | undefined {
    return this.#id;
  }

  get handle(): SessionHandle | undefined {
    return this.#handle;
  }

  get transcript(): Transcript {
    return this.#transcript;
  }

  get complete(): boolean {
    return this.#complete;
  }

  get historyError(): unknown {
    return this.#historyError;
  }

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
          event: (event) => {
            if (!current) {
              current = true;
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
            transcript.apply(event);
            this.#changed();
            if (transcript.gap !== undefined) void this.older();
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

  async older(): Promise<void> {
    const id = this.#id;
    // Before a snapshot, the transcript has no first event and no gap, so no page loads.
    if (id === undefined || this.#loading || this.#historyError !== undefined) return;
    const transcript = this.#transcript;
    const gap = transcript.gap;
    const first = transcript.first;
    let page: EventsPage;
    if (gap !== undefined) page = { ...gap, limit: Math.min(PAGE, gap.limit) };
    else if (this.#complete || first === undefined) return;
    else page = { before: first, limit: PAGE };
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
      if (gap === undefined && transcript.first === first) this.#complete = true;
    }
    this.#changed();
  }

  onChange(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  #changed(): void {
    for (const listener of this.#listeners) listener();
  }
}

// The check against `types/chat.d.ts` keeps this code and the declarations of the authors in step.
const declared = {
  ChatSession,
  ChatCommands,
  ChatComposer,
  ChatDocument,
  ChatQuestions,
  ChatWorking,
  chatStyles,
} satisfies typeof import("yuke:chat");
void declared;
