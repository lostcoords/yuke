/**
 * The values of a single-slot setter: the last added value wins, and its remover brings back the value before it. Each
 * call adds its own entry, so a remover removes only that one, also when two calls add the same value.
 */
export class Stack<T> {
  readonly #entries: { readonly value: T }[] = [];

  /** Add `value` on top, and give the function that removes it. The remover gives `true` when it removed the top value. */
  add(value: T): () => boolean {
    const entry = { value };
    this.#entries.push(entry);
    return () => {
      const index = this.#entries.indexOf(entry);
      if (index === -1) return false;
      this.#entries.splice(index, 1);
      return index === this.#entries.length;
    };
  }

  /** The newest value for which `accept` is true, or the newest value without `accept`. */
  top(accept?: (value: T) => boolean): T | undefined {
    return this.#entries.findLast((entry) => accept?.(entry.value) ?? true)?.value;
  }
}
