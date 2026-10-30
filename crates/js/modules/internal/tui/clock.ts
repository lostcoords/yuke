/** The timers of the terminal interface: the event loop at run time, and a manual clock in a frame test. */

/** Call `callback` once after `delay` milliseconds. The returned function cancels the call. */
export type After = (delay: number, callback: () => void) => () => void;

/** A clock that moves only through `advance`. */
export class ManualClock {
  #now = 0;
  #order = 0;
  readonly #timers = new Set<{ readonly due: number; readonly order: number; readonly callback: () => void }>();

  readonly after: After = (delay, callback) => {
    // As the timers of the runtime, a fraction rounds down and a negative delay counts as 0.
    const timer = { due: this.#now + Math.max(0, Math.floor(delay)), order: this.#order++, callback };
    this.#timers.add(timer);
    return () => {
      this.#timers.delete(timer);
    };
  };

  /** Move the time by `ms`, and run each due callback in time order. A due timer that a callback adds runs too. */
  advance(ms: number): void {
    const end = this.#now + ms;
    for (;;) {
      let next: { readonly due: number; readonly order: number; readonly callback: () => void } | undefined;
      for (const timer of this.#timers) {
        if (timer.due > end) continue;
        if (next === undefined || timer.due < next.due || (timer.due === next.due && timer.order < next.order)) {
          next = timer;
        }
      }
      if (next === undefined) break;
      this.#timers.delete(next);
      this.#now = next.due;
      next.callback();
    }
    this.#now = end;
  }
}
