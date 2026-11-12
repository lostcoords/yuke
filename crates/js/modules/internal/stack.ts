/**
 * The values of a single-slot setter: the last added value wins, and its remover brings back the value before it. Each
 * call adds its own entry, so a remover removes only that one, also when two calls add the same value.
 */
export class Stack<T> {
  readonly #entries: { readonly value: T }[] = [];

  /** Add `value` on top, and give the function that removes it. */
  add(value: T): () => void {
    const entry = { value };
    this.#entries.push(entry);
    return () => {
      const index = this.#entries.indexOf(entry);
      if (index !== -1) this.#entries.splice(index, 1);
    };
  }

  /** The newest value for which `accept` is true, or the newest value without `accept`. */
  top(accept?: (value: T) => boolean): T | undefined {
    return this.#entries.findLast((entry) => accept?.(entry.value) ?? true)?.value;
  }

  /** The values, oldest first. */
  values(): T[] {
    return this.#entries.map((entry) => entry.value);
  }
}
