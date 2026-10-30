/**
 * The notices of the host and the faults of the plugins. The core draws none: a listener, such as the toasts, shows
 * them. The history serves a listener that starts late.
 */
import type { NoticeLevel } from "yuke:plugins";
import type { SessionId } from "yuke:protocol";
import type { Notice } from "yuke:tui";

/** The notices that the history keeps. */
const HISTORY = 100;

export class Notices {
  readonly #entries: Notice[] = [];
  /** Each registration is its own entry, so a disposer removes only its own one. */
  readonly #listeners = new Set<{ readonly listener: (notice: Notice) => void }>();

  /**
   * Add a notice and give it to each listener. A notice with the level, source, text, and session of the last one
   * raises its count.
   */
  add(level: NoticeLevel, source: string, text: string, sessionId?: SessionId): void {
    const last = this.#entries.at(-1);
    let notice: Notice;
    if (
      last !== undefined &&
      last.level === level &&
      last.source === source &&
      last.text === text &&
      last.sessionId === sessionId
    ) {
      notice = Object.freeze({ ...last, count: last.count + 1 });
      this.#entries[this.#entries.length - 1] = notice;
    } else {
      notice = Object.freeze({ level, source, text, ...(sessionId === undefined ? {} : { sessionId }), count: 1 });
      this.#entries.push(notice);
      if (this.#entries.length > HISTORY) this.#entries.shift();
    }
    for (const entry of [...this.#listeners]) {
      try {
        entry.listener(notice);
      } catch (error) {
        // The fault comes back as a notice, so a listener that stays would throw on it again and again.
        this.#listeners.delete(entry);
        reportError(error);
      }
    }
  }

  /** The kept notices, the oldest first. */
  list(): readonly Notice[] {
    return [...this.#entries];
  }

  /** Give each later notice to `listener`, and return the disposer. */
  on(listener: (notice: Notice) => void): () => void {
    const entry = { listener };
    this.#listeners.add(entry);
    return () => {
      this.#listeners.delete(entry);
    };
  }
}
