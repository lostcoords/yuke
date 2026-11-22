/**
 * The listeners of one event, as for `EventTarget`: each add is its own entry, so a remover takes away only its own
 * one, also when the same function is added twice. A call reaches the listeners that were there at its start and are
 * still there. A throw of a listener goes to the caller of `call`.
 */
export class Listeners<A extends readonly unknown[] = []> {
  readonly #entries = new Set<{ readonly listener: (...args: A) => void }>();

  /** Add `listener`, and give the function that removes it. */
  add(listener: (...args: A) => void): () => void {
    const entry = { listener };
    this.#entries.add(entry);
    return () => {
      this.#entries.delete(entry);
    };
  }

  /** Call each listener with `args`, in add order. */
  call(...args: A): void {
    for (const entry of [...this.#entries]) if (this.#entries.has(entry)) entry.listener(...args);
  }
}
