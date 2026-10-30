/**
 * `Picker` of `yuke:tui`: a search field over a list of items. A rank gives the shown items in their final order, and
 * the picker never sorts them again. The selection follows its key. Up and Down move it, Enter chooses, and Esc
 * cancels.
 */
import { TextEditor } from "yuke:internal/tui/editor";
import { fuzzyMatch } from "yuke:internal/tui/fuzzy";
import { strokeOf } from "yuke:internal/tui/keys";
import { ScrollList } from "yuke:internal/tui/scroll";
import { measure } from "yuke:internal/tui/text";
import { attachHost, registerHost } from "yuke:internal/tui/widgets";
import type {
  Canvas,
  KeyEvent,
  MouseEvent,
  OffsetRange,
  PickerMatch,
  PickerOptions,
  Placement,
  Segment,
  Size,
  Style,
  TextRow,
  View,
} from "yuke:tui";

const MATCH: Style = { fg: "accent", bold: true };
const DETAIL: Style = { dim: true };

/** A shown match, its key, and whether it is selected. A new selection gives a new entry, so its rows render again. */
interface Entry<T> {
  readonly match: PickerMatch<T>;
  readonly key: string;
  readonly selected: boolean;
}

export class Picker<T extends object> {
  readonly input: TextEditor;
  readonly #options: PickerOptions<T>;
  readonly #list: ScrollList<Entry<T>>;
  #items: readonly T[];
  #entries: Entry<T>[] = [];
  #selected: string | undefined;
  /** The selection moved, so the next layout shows it. A wheel scroll leaves it where the user put it. */
  #reveal = true;

  constructor(options: PickerOptions<T>) {
    if (typeof options !== "object" || options === null) throw new TypeError("picker options are an object");
    for (const name of ["key", "label", "choose", "cancel"] as const) {
      if (typeof options[name] !== "function") throw new TypeError(`a picker takes a ${name} function`);
    }
    for (const name of ["detail", "rank", "render"] as const) {
      if (options[name] !== undefined && typeof options[name] !== "function") {
        throw new TypeError(`the picker option ${name} is a function`);
      }
    }
    if (!Array.isArray(options.items)) throw new TypeError("picker items are an array");
    this.#options = options;
    this.#items = options.items;
    this.input = new TextEditor({ multiline: false });
    const extension = this.input.extend(new AbortController().signal);
    extension.onKey((event) => this.key(event));
    extension.onChange((change) => {
      // A new query selects its best result, as the user expects at the top.
      if (change.before.text !== change.after.text) this.#rank(true);
    });
    this.#list = new ScrollList<Entry<T>>({
      key: (entry) => entry.key,
      render: (entry, width) =>
        this.#options.render === undefined
          ? [this.#row(entry, width)]
          : this.#options.render(entry.match, width, entry.selected),
    });
    const list = this.#list;
    // The picker draws its list itself, so the list gets its host through the picker.
    registerHost(this, (host) => attachHost(list, host));
    this.#rank();
  }

  /** A picker takes the focus, and gives it to its search field. */
  get focusable(): boolean {
    return true;
  }

  get initialFocus(): View {
    return this.input;
  }

  get selected(): T | undefined {
    return this.#entries.find((entry) => entry.key === this.#selected)?.match.item;
  }

  get query(): string {
    return this.input.state.text;
  }

  set query(text: string) {
    if (typeof text !== "string") throw new TypeError("a picker query is a string");
    if (text === this.query) return;
    this.input.reset({ text, selection: { anchor: text.length, head: text.length }, spans: [] });
  }

  setItems(items: readonly T[]): void {
    if (!Array.isArray(items)) throw new TypeError("picker items are an array");
    this.#items = items;
    this.#rank();
  }

  /** Move the selection by `rows` results. It stops at the first and the last result. */
  move(rows: number): void {
    if (!Number.isInteger(rows)) throw new TypeError("a picker move is a whole number of results");
    if (this.#entries.length === 0) return;
    const at = this.#entries.findIndex((entry) => entry.key === this.#selected);
    const next = Math.max(0, Math.min(this.#entries.length - 1, at + rows));
    this.#select((this.#entries[next] as Entry<T>).key);
  }

  /** Give the selected item to `choose`. `false` without a selected item. */
  choose(): boolean {
    const item = this.selected;
    if (item === undefined) return false;
    this.#options.choose(item);
    return true;
  }

  cancel(): void {
    this.#options.cancel();
  }

  layout(size: Size): readonly Placement[] {
    this.#list.layout({ width: size.width, height: Math.max(0, size.height - 1) });
    if (this.#reveal && this.#selected !== undefined) this.#list.ensureVisible(this.#selected);
    this.#reveal = false;
    return [{ view: this.input, rect: { column: 0, row: 0, width: size.width, height: 1 } }];
  }

  draw(canvas: Canvas, focused: boolean): void {
    this.#list.draw(canvas.region(0, 1, canvas.width, Math.max(0, canvas.height - 1)), focused);
  }

  /** Up, Down, Enter, and Esc. Enter stays here also when nothing is selected. */
  key(event: KeyEvent): boolean {
    switch (strokeOf(event)) {
      case "up":
        this.move(-1);
        return true;
      case "down":
        this.move(1);
        return true;
      case "enter":
        this.choose();
        return true;
      case "esc":
        this.cancel();
        return true;
      default:
        return false;
    }
  }

  /** The wheel scrolls the results, and a press on a result chooses it. */
  mouse(event: MouseEvent): boolean {
    // The search field takes the first row.
    const local = { ...event, row: event.row - 1 };
    if (event.button === "wheel_up" || event.button === "wheel_down") return this.#list.mouse(local);
    if (event.button !== "left" || event.action !== "press" || local.row < 0) return false;
    const found = this.#list.rowAt(this.#list.state.top + local.row);
    if (found === undefined) return false;
    this.#select(found.item.key);
    this.choose();
    return true;
  }

  /** Rank the items for the query. With `top`, or when the selected key leaves, select the first result. */
  #rank(top = false): void {
    const query = this.query;
    const matches =
      this.#options.rank === undefined
        ? defaultRank(query, this.#items, this.#options.label)
        : this.#options.rank(query, this.#items);
    if (!Array.isArray(matches)) throw new TypeError("a picker rank gives an array of matches");
    const keys = matches.map((match) => this.#options.key(match.item));
    const selected = !top && this.#selected !== undefined && keys.includes(this.#selected) ? this.#selected : keys[0];
    this.#selected = selected;
    this.#entries = matches.map((match, at) => ({ match, key: keys[at] as string, selected: keys[at] === selected }));
    this.#list.setItems(this.#entries);
    this.#reveal = true;
  }

  /** Select `key`: the old and the new selected entries become new objects, so only their rows render again. */
  #select(key: string): void {
    if (key === this.#selected) return;
    const old = this.#selected;
    this.#selected = key;
    this.#entries = this.#entries.map((entry) =>
      entry.key === key || entry.key === old ? { ...entry, selected: entry.key === key } : entry,
    );
    this.#list.setItems(this.#entries);
    this.#reveal = true;
    this.#list.ensureVisible(key);
  }

  /** The default row shows the label with its matched ranges marked, then the detail. It reverses a selected row. */
  #row(entry: Entry<T>, width: number): TextRow {
    const label = this.#options.label(entry.match.item);
    const ranges = entry.match.ranges ?? [];
    const segments: Segment[] = [];
    const reverse: Style = entry.selected ? { reverse: true } : {};
    const add = (from: number, to: number, matched: boolean): void => {
      if (to <= from) return;
      segments.push({ text: label.slice(from, to), style: { ...(matched ? MATCH : {}), ...reverse } });
    };
    let at = 0;
    for (const range of ranges) {
      add(at, range.from, false);
      add(range.from, range.to, true);
      at = range.to;
    }
    add(at, label.length, false);
    const detail = this.#options.detail?.(entry.match.item) ?? "";
    if (detail !== "") segments.push({ text: `  ${detail}`, style: { ...DETAIL, ...reverse } });
    const cells = segments.reduce((sum, segment) => sum + measure(segment.text), 0);
    if (entry.selected && cells < width) segments.push({ text: " ".repeat(width - cells), style: { reverse: true } });
    return { segments, join: "\n" };
  }
}

/** The default rank: an empty query keeps the input order; else each match by fuzzy score, ties in input order. */
function defaultRank<T>(query: string, items: readonly T[], label: (item: T) => string): PickerMatch<T>[] {
  if (query === "") return items.map((item) => ({ item }));
  const scored: { readonly item: T; readonly score: number; readonly ranges: readonly OffsetRange[] }[] = [];
  for (const item of items) {
    const match = fuzzyMatch(query, label(item));
    if (match !== undefined) scored.push({ item, score: match.score, ranges: match.ranges });
  }
  // The sort keeps the input order of equal scores. Two infinite scores give NaN, which the sort reads as equal.
  scored.sort((a, b) => b.score - a.score);
  return scored.map((entry) => ({ item: entry.item, ranges: entry.ranges }));
}
