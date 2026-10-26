/**
 * The notices of the host and the faults of the plugins. The core draws none: a listener, such as the toasts, shows
 * them. The history serves a listener that starts late.
 */
import type { NoticeLevel } from "yuke:plugins";
import type { Notice } from "yuke:tui";

/** The notices that the history keeps. */
const HISTORY = 100;

export class Notices {
  readonly #entries: Notice[] = [];
  readonly #listeners: ((notice: Notice) => void)[] = [];

  /**
   * Add a notice and give it to each listener. A notice with the level, source, and text of the last one raises its
   * count.
   */
  add(level: NoticeLevel, source: string, text: string): void {
    const last = this.#entries.at(-1);
    let notice: Notice;
    if (last !== undefined && last.level === level && last.source === source && last.text === text) {
      notice = Object.freeze({ ...last, count: last.count + 1 });
      this.#entries[this.#entries.length - 1] = notice;
    } else {
      notice = Object.freeze({ level, source, text, count: 1 });
      this.#entries.push(notice);
      if (this.#entries.length > HISTORY) this.#entries.shift();
    }
    for (const listener of [...this.#listeners]) {
      try {
        listener(notice);
      } catch (error) {
        // The fault comes back as a notice, so a listener that stays would throw on it again and again.
        this.#remove(listener);
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
    if (typeof listener !== "function") throw new TypeError("a notice listener is a function");
    // A wrapper makes each registration its own, so a disposer removes only its own one.
    const registered = (notice: Notice): void => listener(notice);
    this.#listeners.push(registered);
    return () => this.#remove(registered);
  }

  #remove(listener: (notice: Notice) => void): void {
    const at = this.#listeners.indexOf(listener);
    if (at >= 0) this.#listeners.splice(at, 1);
  }
}
