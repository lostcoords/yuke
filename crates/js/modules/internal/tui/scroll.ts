/**
 * `ScrollList` of `yuke:tui`: items rendered to rows, scrolled by display rows. Each item object keeps its height for
 * one width, and prefix heights find the first visible item. Only recent items keep their rows. The top item and its
 * row offset stay across a prepend, an update, and a resize. A list that follows the tail stays at the bottom.
 */
import { registerHost, type WidgetHost } from "yuke:internal/tui/widgets";
import type { Canvas, MouseEvent, Placement, ScrollListOptions, ScrollState, Size, TextRow, View } from "yuke:tui";

/** A wheel step moves this many rows. */
const WHEEL_ROWS = 3;

/** The rendered rows that a list keeps outside its view, so a long list costs little more than its heights. */
const KEPT_ROWS = 2000;

interface Entry<T> {
  readonly item: T;
  readonly key: string;
  readonly height: number;
}

interface Rendered {
  readonly key: string;
  readonly rows: readonly TextRow[];
}

/** The first visible item and the row of it at the top of the view. */
interface Anchor {
  readonly id: string;
  readonly row: number;
}

export class ScrollList<T extends object> implements View {
  readonly #key: (item: T) => string;
  readonly #render: (item: T, width: number) => readonly TextRow[];
  readonly #onTopReached: (() => void | Promise<void>) | undefined;
  readonly #heights = new WeakMap<T, { readonly width: number; readonly height: number }>();
  /** The oldest render comes first. */
  readonly #rendered = new Map<T, Rendered>();
  #renderedRows = 0;
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
  /** A top visit or an item update at the top allows one call of `onTopReached`. */
  #olderAllowed = false;
  #olderPending = false;

  constructor(options: ScrollListOptions<T>) {
    this.#key = options.id;
    this.#render = options.render;
    this.#onTopReached = options.onTopReached;
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
      anchor: this.#anchor(),
    };
  }

  /**
   * Replace the items. An item object that stays keeps its height at one width. An item that is new or replaced below a view that does
   * not follow the tail sets `changedBelow`.
   */
  setItems(items: readonly T[]): void {
    const keys = new Set<string>();
    const keyed = items.map((item) => {
      const key = this.#key(item);
      if (keys.has(key)) throw new TypeError(`two scroll list items have the id ${key}`);
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
        (entry, at) => !old.has(entry.item) && entry.height > 0 && (this.#prefix[at + 1] as number) > bottom,
      );
      if (below) this.#changedBelow = true;
    }
    if (this.#top === 0) this.#olderAllowed = true;
    this.#changed();
  }

  scrollBy(rows: number): void {
    this.#moveTo(this.#top + rows);
  }

  scrollTo(row: number): void {
    this.#moveTo(row);
  }

  /** Go to the bottom and follow the tail. */
  followTail(): void {
    this.#moveTo(this.#last());
  }

  /** Put row `row` of the item `id` at the top, as far as the rows below allow. `false` when the item has no such row. */
  scrollToItem(id: string, row = 0): boolean {
    const at = this.#index.get(id);
    if (at === undefined || !Number.isInteger(row) || row < 0) return false;
    if (row >= (this.#entries[at] as Entry<T>).height) return false;
    this.#moveTo((this.#prefix[at] as number) + row);
    return true;
  }

  /** Scroll the least to show row `row` of the item `id`. `false` when it cannot show. */
  ensureVisible(id: string, row = 0): boolean {
    const at = this.#index.get(id);
    if (at === undefined || this.#size.height <= 0) return false;
    const height = (this.#entries[at] as Entry<T>).height;
    if (!Number.isInteger(row) || row < 0 || row >= height) return false;
    const target = (this.#prefix[at] as number) + row;
    if (target < this.#top) this.#moveTo(target);
    else if (target >= this.#top + this.#size.height) this.#moveTo(target - this.#size.height + 1);
    return true;
  }

  /**
   * The item at absolute display row `row`, counted from the start of the list.
   * The result has the item-local row index and its text.
   * Return `undefined` when `row` is not a display row.
   */
  rowAt(row: number): { readonly item: T; readonly row: number; readonly text: TextRow } | undefined {
    if (!Number.isInteger(row) || row < 0 || row >= this.#total()) return undefined;
    const at = this.#entryAt(row);
    const entry = this.#entries[at] as Entry<T>;
    const local = row - (this.#prefix[at] as number);
    return { item: entry.item, row: local, text: this.#rowsOf(entry)[local] as TextRow };
  }

  /**
   * The first absolute display row and the rows of the item `id`.
   * Return `undefined` when the id is absent.
   */
  rowsOf(id: string): { readonly start: number; readonly rows: readonly TextRow[] } | undefined {
    const at = this.#index.get(id);
    if (at === undefined) return undefined;
    return { start: this.#prefix[at] as number, rows: this.#rowsOf(this.#entries[at] as Entry<T>) };
  }

  /** Give each later change of the state to `listener`, until the remover runs. */
  addChangeListener(listener: (state: ScrollState) => void): () => void {
    // A wrapper makes each registration its own, so a remover removes only its own one.
    const registered = (state: ScrollState): void => listener(state);
    this.#listeners.add(registered);
    return () => {
      this.#listeners.delete(registered);
    };
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

  draw(canvas: Canvas): void {
    let at = this.#entryAt(this.#top);
    if (at < 0) return;
    let row = this.#top - (this.#prefix[at] as number);
    for (let line = 0; line < canvas.height && at < this.#entries.length; line += 1) {
      const rows = this.#rowsOf(this.#entries[at] as Entry<T>);
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

  onMouse(event: MouseEvent): boolean {
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
      const known = this.#heights.get(entry.item);
      if (known !== undefined && known.width === width) {
        return { item: entry.item, key: entry.key, height: known.height };
      }
      const rows = width > 0 ? this.#render(entry.item, width) : [];
      if (width > 0) {
        this.#heights.set(entry.item, { width, height: rows.length });
        this.#keep(entry.item, entry.key, rows);
      }
      return { item: entry.item, key: entry.key, height: rows.length };
    });
    const anchor = this.#anchor();
    const order = this.#entries.map((entry) => entry.key);
    this.#items = entries.map((entry) => entry.item);
    this.#entries = entries;
    const present = new Set(this.#items);
    for (const [item, kept] of this.#rendered) if (!present.has(item)) this.#forget(item, kept);
    this.#prefix = [0];
    for (const entry of entries) this.#prefix.push((this.#prefix.at(-1) as number) + entry.height);
    this.#index = new Map(entries.map((entry, at) => [entry.key, at]));
    this.#size = { width: size.width, height: size.height };
    this.#top = this.#following ? this.#last() : this.#anchored(anchor, order);
    this.#trim();
  }

  /** The rows of `entry` at the width of the list. It renders them again after they left the kept rows. */
  #rowsOf(entry: Entry<T>): readonly TextRow[] {
    if (entry.height === 0) return [];
    const kept = this.#rendered.get(entry.item);
    if (kept !== undefined) return kept.rows;
    const rows = this.#render(entry.item, this.#size.width);
    this.#keep(entry.item, entry.key, rows);
    return rows;
  }

  /** Keep the rows of `item`, and trim the older rows. */
  #keep(item: T, key: string, rows: readonly TextRow[]): void {
    const old = this.#rendered.get(item);
    if (old !== undefined) this.#forget(item, old);
    if (rows.length === 0) return;
    this.#rendered.set(item, { key, rows });
    this.#renderedRows += rows.length;
    this.#trim(item);
  }

  /** While the kept rows exceed `KEPT_ROWS`, drop the oldest items outside the view. A caller reads `newest`, so it stays. */
  #trim(newest?: T): void {
    for (const [oldest, kept] of this.#rendered) {
      if (this.#renderedRows <= KEPT_ROWS) break;
      if (oldest !== newest && !this.#inView(kept.key)) this.#forget(oldest, kept);
    }
  }

  #forget(item: T, kept: Rendered): void {
    this.#rendered.delete(item);
    this.#renderedRows -= kept.rows.length;
  }

  #inView(key: string): boolean {
    const at = this.#index.get(key);
    if (at === undefined) return false;
    return (this.#prefix[at] as number) < this.#top + this.#size.height && (this.#prefix[at + 1] as number) > this.#top;
  }

  /** The anchor of the view now, or `undefined` before a layout or without rows. */
  #anchor(): Anchor | undefined {
    const at = this.#entryAt(this.#top);
    if (at < 0 || this.#size.height <= 0) return undefined;
    return { id: (this.#entries[at] as Entry<T>).key, row: this.#top - (this.#prefix[at] as number) };
  }

  /** The top row for `anchor` in the new entries. `order` holds the keys before the change. */
  #anchored(anchor: Anchor | undefined, order: readonly string[]): number {
    if (anchor === undefined) return Math.min(this.#top, this.#last());
    const rowOf = (key: string, row: number): number | undefined => {
      const at = this.#index.get(key);
      if (at === undefined) return undefined;
      const height = (this.#entries[at] as Entry<T>).height;
      if (height === 0) return undefined;
      return (this.#prefix[at] as number) + Math.min(row, height - 1);
    };
    const old = order.indexOf(anchor.id);
    let top = rowOf(anchor.id, anchor.row);
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

  /** Call `onTopReached` once when the view shows the top, unless a call still runs. */
  #askOlder(): void {
    const request = this.#onTopReached;
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
    for (const listener of [...this.#listeners]) listener(state);
  }
}
