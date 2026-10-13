/**
 * The cancel signal of one tool call. It aborts when the turn cancels the call, and when the call ends. Work that
 * listens to it, such as a native command, stops with the call.
 */
export class CallSignal {
  #aborted = false;
  #reason: unknown = undefined;
  readonly #listeners = new Set<() => void>();

  /** Whether the signal has aborted. */
  get aborted(): boolean {
    return this.#aborted;
  }

  /** The reason of the abort, a `DOMException` named `AbortError`. */
  get reason(): unknown {
    return this.#reason;
  }

  /** Throw the reason when the signal has aborted. */
  throwIfAborted(): void {
    if (this.#aborted) throw this.#reason;
  }

  /**
   * Call `listener` once at the abort. When the signal has aborted already, the call comes at once. Returns the function
   * that removes the listener.
   */
  onAbort(listener: () => void): () => void {
    if (this.#aborted) {
      notify(listener);
      return () => {};
    }
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  /** Abort the signal with `reason`. A second abort does nothing. */
  abort(reason: unknown): void {
    if (this.#aborted) return;
    this.#aborted = true;
    this.#reason = reason;
    const listeners = [...this.#listeners];
    this.#listeners.clear();
    for (const listener of listeners) notify(listener);
  }
}

/** Call `listener`. A throw does not stop the caller. The runtime reports the throw as a fault. */
function notify(listener: () => void): void {
  try {
    listener();
  } catch (error) {
    reportError(error);
  }
}
