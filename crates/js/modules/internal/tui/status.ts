/**
 * The items of the status bar: plain data that plugins and the core set, by the key `<plugin>:<key>`. The core draws
 * none of them: a bar plugin reads them and draws them.
 */
import { Listeners } from "yuke:internal/listeners";
import type { StatusEntry, StatusItem } from "yuke:tui";

export class StatusItems {
  readonly #items = new Map<string, StatusItem>();
  readonly #listeners = new Listeners();
  readonly #changed: () => void;

  /** `changed` asks for a frame after each change. */
  constructor(changed: () => void) {
    this.#changed = changed;
  }

  /**
   * Set the item `key` to `entry`. The same entry again changes nothing. The remover deletes the item while this call
   * set it, so a later `set` of the key keeps its item.
   */
  set(key: string, entry: StatusEntry): () => void {
    const last = this.#items.get(key);
    const priority = entry.priority ?? 0;
    const style = entry.style === undefined ? {} : { style: entry.style };
    const item: StatusItem = Object.freeze({
      id: key,
      text: entry.text,
      side: entry.side,
      order: entry.order,
      priority,
      ...style,
    });
    this.#items.set(key, item);
    if (
      last === undefined ||
      last.text !== item.text ||
      last.side !== item.side ||
      last.order !== item.order ||
      last.priority !== priority ||
      // A plugin can give an equal style in a new object, as on each update.
      JSON.stringify(last.style) !== JSON.stringify(item.style)
    ) {
      this.#change();
    }
    return () => {
      if (this.#items.get(key) === item) this.delete(key);
    };
  }

  delete(key: string): void {
    if (this.#items.delete(key)) this.#change();
  }

  /** Delete each item of the plugin `owner`, as at its stop. */
  deleteOwned(owner: string): void {
    const prefix = `${owner}:`;
    const owned = [...this.#items.keys()].filter((key) => key.startsWith(prefix));
    for (const key of owned) this.#items.delete(key);
    if (owned.length > 0) this.#change();
  }

  /** Each item. A bar orders them itself. */
  list(): readonly StatusItem[] {
    return [...this.#items.values()];
  }

  /** Give each later change to `listener`, and return the remover. */
  addChangeListener(listener: () => void): () => void {
    return this.#listeners.add(listener);
  }

  #change(): void {
    this.#changed();
    this.#listeners.call();
  }
}
