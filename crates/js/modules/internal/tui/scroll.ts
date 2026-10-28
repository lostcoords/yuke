/**
 * `ScrollList` of `yuke:tui`: items rendered to rows, scrolled by display rows. Each item object keeps its rows for one
 * width, and prefix heights find the first visible item. The top item and its row offset stay across a prepend, an
 * update, and a resize. A list that follows the tail stays at the bottom.
 */
import { registerHost, type WidgetHost } from "yuke:internal/tui/widgets";
import type { Canvas, Disposer, MouseEvent, Placement, ScrollListOptions, ScrollState, Size, TextRow } from "yuke:tui";

/** A wheel step moves this many rows. */
const WHEEL_ROWS = 3;

interface Entry<T> {
  readonly item: T;
  readonly key: string;
  readonly rows: readonly TextRow[];
}

/** The first visible item and the row of it at the top of the view. */
interface Anchor {
  readonly key: string;
  readonly row: number;
}

export class ScrollList<T extends object> {
  readonly #key: (item: T) => string;
  readonly #render: (item: T, width: number) => readonly TextRow[];
  readonly #requestOlder: (() => void | Promise<void>) | undefined;
  readonly #cache = new WeakMap<T, { readonly width: number; readonly rows: readonly TextRow[] }>();
  readonly #listeners = new Set<(state: ScrollState) => void>();
  #items: readonly T[] = [];
  #entries: Entry<T>[] = [];
  /** The rows before each entry, and the total at the end. */
  #prefix: number[] = [0];
  #index = new Map<string, number>();
  #size: Size = { width: 0, height: 0 };
  #top = 0;
  #following: boolean;
  #changedBelow = false;
  #host: WidgetHost | undefined;
  /** A top visit or an item update at the top allows one call of `requestOlder`. */
  #olderAllowed = false;
  #olderPending = false;

  constructor(options: ScrollListOptions<T>) {
    if (typeof options !== "object" || options === null) throw new TypeError("scroll list options are an object");
    if (typeof options.key !== "function" || typeof options.render !== "function") {
      throw new TypeError("a scroll list takes a key function and a render function");
    }
    if (options.requestOlder !== undefined && typeof options.requestOlder !== "function") {
      throw new TypeError("requestOlder is a function");
    }
    this.#key = options.key;
    this.#render = options.render;
    this.#requestOlder = options.requestOlder;
    this.#following = options.followTail === true;
    registerHost(this, (host) => {
      this.#host = host;
      // The first layout runs before the host comes, so a request that it allowed starts now.
      this.#askOlder();
    });
    if (options.items !== undefined) this.setItems(options.items);
  }

  get items(): readonly T[] {
    return this.#items;
  }

  get state(): ScrollState {
    return {
      top: this.#top,
      height: this.#size.height,
      total: this.#total(),
      following: this.#following,
      changedBelow: this.#changedBelow,
    };
  }

  /**
   * Replace the items. An item object that stays keeps its rows. An item that is new or replaced below a view that does
   * not follow the tail sets `changedBelow`.
   */
  setItems(items: readonly T[]): void {
    if (!Array.isArray(items)) throw new TypeError("scroll list items are an array");
    const keys = new Set<string>();
    const keyed = items.map((item) => {
      if (typeof item !== "object" || item === null) throw new TypeError("a scroll list item is an object");
      const key = this.#key(item);
      if (typeof key !== "string") throw new TypeError("a scroll list key is a string");
      if (keys.has(key)) throw new TypeError(`two scroll list items have the key ${key}`);
      keys.add(key);
      return { item, key };
    });
    const before = this.#items;
    if (before.length === items.length && before.every((item, at) => item === items[at])) return;
    const old = new Set(before);
    this.#relayout(keyed, this.#size.width);
    if (!this.#following && before.length > 0 && this.#size.height > 0) {
      const bottom = this.#top + this.#size.height;
      const below = this.#entries.some(
        (entry, at) => !old.has(entry.item) && entry.rows.length > 0 && (this.#prefix[at + 1] as number) > bottom,
      );
      if (below) this.#changedBelow = true;
    }
    if (this.#top === 0) this.#olderAllowed = true;
    this.#changed();
  }

  scrollBy(rows: number): void {
    if (!Number.isInteger(rows)) throw new TypeError("a scroll step is a whole number of rows");
    this.#moveTo(this.#top + rows);
  }

  scrollTo(row: number): void {
    if (!Number.isInteger(row)) throw new TypeError("a scroll row is a whole number");
    this.#moveTo(row);
  }

  /** Go to the bottom and follow the tail. */
  followTail(): void {
    this.#moveTo(this.#last());
  }

  /** Scroll the least to show row `row` of the item `key`. `false` when it cannot show. */
  ensureVisible(key: string, row = 0): boolean {
    const at = this.#index.get(key);
    if (at === undefined || this.#size.height <= 0) return false;
    const height = (this.#entries[at] as Entry<T>).rows.length;
    if (!Number.isInteger(row) || row < 0 || row >= height) return false;
    const target = (this.#prefix[at] as number) + row;
    if (target < this.#top) this.#moveTo(target);
    else if (target >= this.#top + this.#size.height) this.#moveTo(target - this.#size.height + 1);
    return true;
  }

  /** Give each later change of the state to `listener`, until `signal` aborts. */
  onChange(listener: (state: ScrollState) => void, signal: AbortSignal): Disposer {
    if (typeof listener !== "function") throw new TypeError("a scroll listener is a function");
    if (signal.aborted) return () => {};
    // A wrapper makes each registration its own, so a disposer removes only its own one.
    const registered = (state: ScrollState): void => listener(state);
    const dispose = (): void => {
      this.#listeners.delete(registered);
      signal.removeEventListener("abort", dispose);
    };
    this.#listeners.add(registered);
    signal.addEventListener("abort", dispose, { once: true });
    return dispose;
  }

  layout(size: Size): readonly Placement[] {
    if (size.width !== this.#size.width || size.height !== this.#size.height) {
      const widthChanged = size.width !== this.#size.width;
      const first = this.#size.height <= 0 && size.height > 0;
      if (widthChanged) this.#relayout(this.#entries, size.width, size);
      else {
        this.#size = { width: size.width, height: size.height };
        this.#top = this.#following ? this.#last() : Math.min(this.#top, this.#last());
      }
      if (first && this.#top === 0) this.#olderAllowed = true;
      this.#emit();
    }
    this.#askOlder();
    return [];
  }

  draw(canvas: Canvas, _focused: boolean): void {
    let at = this.#entryAt(this.#top);
    if (at < 0) return;
    let row = this.#top - (this.#prefix[at] as number);
    for (let line = 0; line < canvas.height && at < this.#entries.length; line += 1) {
      const rows = (this.#entries[at] as Entry<T>).rows;
      if (row >= rows.length) {
        at += 1;
        row = 0;
        line -= 1;
        continue;
      }
      let column = 0;
      for (const segment of (rows[row] as TextRow).segments) {
        column = canvas.text(column, line, segment.text, segment.style);
      }
      row += 1;
    }
  }

  mouse(event: MouseEvent): boolean {
    if (event.button !== "wheel_up" && event.button !== "wheel_down") return false;
    this.scrollBy(event.button === "wheel_up" ? -WHEEL_ROWS : WHEEL_ROWS);
    return true;
  }

  /**
   * Render `keyed` at `width` and keep the anchor: the top item at its row, or the next item that stays, or the last
   * row of the item before it. A list that follows the tail goes to the bottom. A render that throws changes nothing.
   */
  #relayout(
    keyed: readonly { readonly item: T; readonly key: string }[],
    width: number,
    size: Size = this.#size,
  ): void {
    const entries = keyed.map((entry): Entry<T> => {
      const cached = this.#cache.get(entry.item);
      if (cached !== undefined && cached.width === width)
        return { item: entry.item, key: entry.key, rows: cached.rows };
      const rows = width > 0 ? this.#render(entry.item, width) : [];
      if (!Array.isArray(rows)) throw new TypeError("a scroll list render gives an array of rows");
      if (width > 0) this.#cache.set(entry.item, { width, rows });
      return { item: entry.item, key: entry.key, rows };
    });
    const anchor = this.#anchor();
    const order = this.#entries.map((entry) => entry.key);
    this.#items = entries.map((entry) => entry.item);
    this.#entries = entries;
    this.#prefix = [0];
    for (const entry of entries) this.#prefix.push((this.#prefix.at(-1) as number) + entry.rows.length);
    this.#index = new Map(entries.map((entry, at) => [entry.key, at]));
    this.#size = { width: size.width, height: size.height };
    this.#top = this.#following ? this.#last() : this.#anchored(anchor, order);
  }

  /** The anchor of the view now, or `undefined` before a layout or without rows. */
  #anchor(): Anchor | undefined {
    const at = this.#entryAt(this.#top);
    if (at < 0 || this.#size.height <= 0) return undefined;
    return { key: (this.#entries[at] as Entry<T>).key, row: this.#top - (this.#prefix[at] as number) };
  }

  /** The top row for `anchor` in the new entries. `order` holds the keys before the change. */
  #anchored(anchor: Anchor | undefined, order: readonly string[]): number {
    if (anchor === undefined) return Math.min(this.#top, this.#last());
    const rowOf = (key: string, row: number): number | undefined => {
      const at = this.#index.get(key);
      if (at === undefined) return undefined;
      const height = (this.#entries[at] as Entry<T>).rows.length;
      if (height === 0) return undefined;
      return (this.#prefix[at] as number) + Math.min(row, height - 1);
    };
    const old = order.indexOf(anchor.key);
    let top = rowOf(anchor.key, anchor.row);
    for (let at = old + 1; top === undefined && at < order.length; at += 1) top = rowOf(order[at] as string, 0);
    for (let at = old - 1; top === undefined && at >= 0; at -= 1)
      top = rowOf(order[at] as string, Number.MAX_SAFE_INTEGER);
    return Math.max(0, Math.min(top ?? 0, this.#last()));
  }

  #moveTo(row: number): void {
    const top = Math.max(0, Math.min(row, this.#last()));
    const following = top === this.#last();
    if (top === this.#top && following === this.#following) return;
    if (top === 0 && this.#top !== 0) this.#olderAllowed = true;
    this.#top = top;
    this.#following = following;
    if (following) this.#changedBelow = false;
    this.#changed();
  }

  /** Call `requestOlder` once when the view shows the top, unless a call still runs. */
  #askOlder(): void {
    const request = this.#requestOlder;
    if (request === undefined || !this.#olderAllowed || this.#olderPending) return;
    if (this.#top !== 0 || this.#size.height <= 0 || this.#host === undefined) return;
    this.#olderAllowed = false;
    this.#olderPending = true;
    const settle = (): void => {
      this.#olderPending = false;
      this.#askOlder();
    };
    // A promise job runs the call after the layout, and a throw and a rejection end the same way.
    Promise.resolve()
      .then(() => request())
      .then(settle, (error: unknown) => {
        settle();
        reportError(error);
      });
  }

  /** The index of the entry that holds the display row `row`, or -1 without rows. */
  #entryAt(row: number): number {
    if (this.#total() === 0) return -1;
    let low = 0;
    let high = this.#entries.length - 1;
    while (low < high) {
      const middle = Math.floor((low + high + 1) / 2);
      if ((this.#prefix[middle] as number) <= row) low = middle;
      else high = middle - 1;
    }
    return low;
  }

  #total(): number {
    return this.#prefix.at(-1) as number;
  }

  /** The top row that shows the last row at the bottom of the view. */
  #last(): number {
    return Math.max(0, this.#total() - this.#size.height);
  }

  #changed(): void {
    this.#host?.requestFrame();
    this.#emit();
    this.#askOlder();
  }

  #emit(): void {
    const state = this.state;
    for (const listener of [...this.#listeners]) {
      try {
        listener(state);
      } catch (error) {
        this.#listeners.delete(listener);
        reportError(error);
      }
    }
  }
}
