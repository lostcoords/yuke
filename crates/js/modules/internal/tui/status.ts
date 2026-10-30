/**
 * The items of the status bar: plain data that plugins and the core set, by the key `<plugin>:<key>`. The core draws
 * none of them: a bar plugin reads them and draws them.
 */
import type { Disposer, StatusEntry, StatusItem } from "yuke:tui";

export class StatusItems {
  readonly #items = new Map<string, StatusItem>();
  /** Each listener registration is its own entry, so a disposer removes only its own one. */
  readonly #listeners = new Set<{ readonly listener: () => void }>();
  readonly #changed: () => void;

  /** `changed` asks for a frame after each change. */
  constructor(changed: () => void) {
    this.#changed = changed;
  }

  /** Set the item `key` to `entry`. The same entry again changes nothing. */
  set(key: string, entry: StatusEntry): void {
    const last = this.#items.get(key);
    const priority = entry.priority ?? 0;
    if (
      last !== undefined &&
      last.text === entry.text &&
      last.side === entry.side &&
      last.order === entry.order &&
      last.priority === priority &&
      // A plugin can give an equal style in a new object, as on each update.
      JSON.stringify(last.style) === JSON.stringify(entry.style)
    ) {
      return;
    }
    const style = entry.style === undefined ? {} : { style: entry.style };
    this.#items.set(
      key,
      Object.freeze({ key, text: entry.text, side: entry.side, order: entry.order, priority, ...style }),
    );
    this.#change();
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

  /** Give each later change to `listener`, and return the disposer. */
  on(listener: () => void): Disposer {
    const entry = { listener };
    this.#listeners.add(entry);
    return () => {
      this.#listeners.delete(entry);
    };
  }

  #change(): void {
    this.#changed();
    for (const entry of [...this.#listeners]) {
      try {
        entry.listener();
      } catch (error) {
        // The fault comes back as a notice, and a notice can change an item, so a listener that stays could loop.
        this.#listeners.delete(entry);
        reportError(error);
      }
    }
  }
}
