/**
 * `TextView` of `yuke:tui`: a read-only document of items and sections, drawn from the rows of a scroll list. Each
 * row knows its section, and the source of each segment maps a display offset to a section offset. A copy joins rows
 * by their joins, and puts one line end between two sections and between two items.
 */
import { ScrollList } from "yuke:internal/tui/scroll";
import { graphemes, measure, offsetAtColumn, wrap } from "yuke:internal/tui/text";
import { attachHost, checkAppearance, registerWidget, TextSupport } from "yuke:internal/tui/widgets";
import type {
  Bias,
  Canvas,
  CanvasStyle,
  ColumnUnit,
  Cursor,
  Decoration,
  KeyEvent,
  MouseEvent,
  OffsetRange,
  Placement,
  Point,
  ScrollControl,
  Segment,
  Selection,
  Size,
  TextAppearance,
  TextCoordinates,
  TextDocument,
  TextExtension,
  TextItem,
  TextPosition,
  TextRange,
  TextRow,
  TextSection,
  TextViewChange,
  TextViewOptions,
} from "yuke:tui";

const SELECTION: CanvasStyle = [{ reverse: true }, "textView.selection"];

/** A row of a text view: the row of a section, with the key of that section. */
interface ViewRow extends TextRow {
  readonly section: string;
}

/** A place in the display text: a display row and a UTF-16 offset in the text of that row. */
interface Place {
  readonly row: number;
  readonly offset: number;
}

/** A selection or a decoration at its display places. */
interface PlacedRange {
  readonly start: Place;
  readonly end: Place;
  readonly style: CanvasStyle;
  readonly wholeRows: boolean;
}

/** A styled run of a row, in display offsets of the row. */
interface Mark {
  readonly from: number;
  readonly to: number;
  readonly style: CanvasStyle;
  readonly wholeRows: boolean;
}

export class TextView {
  readonly kind = "textView";
  readonly focusable = true;
  readonly role: string;
  readonly rows: TextCoordinates<TextPosition>;
  readonly #support: TextSupport<TextPosition, TextViewChange>;
  readonly #list: ScrollList<TextItem>;
  readonly #appearance: TextAppearance;
  readonly #copyOnRelease: boolean;
  readonly #activate: ((position: TextPosition, link: string | undefined) => void) | undefined;
  #document: TextDocument;
  /** The order of each item key, and of each section key in its item, for `compare`. */
  #order: Order;
  #revision = 0;
  #caret: TextPosition | undefined;
  #selection: Selection<TextPosition> | undefined;
  #size: Size = { width: 0, height: 0 };
  /** The two ends of the pressed grapheme, and whether the mouse moved since the press. */
  #drag:
    | { readonly start: TextPosition; readonly end: TextPosition; readonly link: string | undefined; moved: boolean }
    | undefined;
  /** True while the view changes the list, so the list change gives no `scroll` event of its own. */
  #quiet = false;

  constructor(options: TextViewOptions) {
    if (typeof options !== "object" || options === null) throw new TypeError("text view options are an object");
    const role = options.role ?? "text";
    if (role !== "transcript" && role !== "text") throw new TypeError("a text view role is transcript or text");
    if (options.activate !== undefined && typeof options.activate !== "function") {
      throw new TypeError("activate is a function");
    }
    this.role = role;
    this.#appearance = options.appearance === undefined ? {} : checkAppearance(options.appearance);
    this.#copyOnRelease = options.copyOnRelease !== false;
    this.#activate = options.activate;
    this.#support = new TextSupport(options.group);
    this.#list = new ScrollList<TextItem>({
      key: (item) => item.key,
      render: (item, width) => renderItem(item, width),
      followTail: options.followTail === true,
      ...(options.requestOlder === undefined ? {} : { requestOlder: options.requestOlder }),
    });
    this.#order = checkDocument(options.document);
    this.#document = options.document;
    this.#list.setItems(this.#document.items);
    this.#list.onChange(() => {
      if (!this.#quiet) this.#emit("scroll");
    }, new AbortController().signal);
    this.rows = this.#coordinates();
    const support = this.#support;
    const list = this.#list;
    registerWidget(this, {
      group: support.group,
      attach: (host) => {
        support.attach(host);
        // The view draws the list itself, so the list gets its host through the view.
        attachHost(list, host);
      },
      key: (event, phase) => support.key(event, phase),
    });
  }

  get document(): TextDocument {
    return this.#document;
  }

  get revision(): number {
    return this.#revision;
  }

  get scroll(): ScrollControl {
    return this.#list;
  }

  get contexts(): readonly string[] {
    return [this.role, ...this.#support.contexts()];
  }

  get visibleRows(): OffsetRange {
    const state = this.#list.state;
    return { from: state.top, to: Math.min(state.total, state.top + state.height) };
  }

  get caret(): TextPosition | undefined {
    return this.#caret;
  }

  /** Set the caret. This clears the selection. */
  set caret(position: TextPosition | undefined) {
    const caret = position === undefined ? undefined : this.#position(position);
    if (samePosition(caret, this.#caret) && this.#selection === undefined) return;
    this.#caret = caret;
    this.#selection = undefined;
    this.#emit("selection");
  }

  get selection(): Selection<TextPosition> | undefined {
    return this.#selection;
  }

  /** Set the selection. This puts the caret at its head. */
  set selection(selection: Selection<TextPosition> | undefined) {
    if (selection === undefined) {
      if (this.#selection === undefined) return;
      this.#selection = undefined;
      this.#emit("selection");
      return;
    }
    if (typeof selection !== "object" || selection === null) throw new TypeError("a selection is an object");
    const next = Object.freeze({ anchor: this.#position(selection.anchor), head: this.#position(selection.head) });
    const now = this.#selection;
    if (now !== undefined && samePosition(now.anchor, next.anchor) && samePosition(now.head, next.head)) return;
    this.#selection = next;
    this.#caret = next.head;
    this.#emit("selection");
  }

  extend(signal: AbortSignal): TextExtension<TextPosition, TextViewChange> {
    return this.#support.extend(signal);
  }

  /** Replace the document. With the same key, a caret or a selection end stays while its position is valid. */
  setDocument(document: TextDocument): void {
    if (document === this.#document) return;
    const order = checkDocument(document);
    const same = document.key === this.#document.key;
    this.#quiet = true;
    try {
      this.#list.setItems(document.items);
    } finally {
      this.#quiet = false;
    }
    this.#document = document;
    this.#order = order;
    const keep = (position: TextPosition | undefined): TextPosition | undefined =>
      same && position !== undefined && this.#valid(position) ? position : undefined;
    this.#caret = keep(this.#caret);
    const anchor = keep(this.#selection?.anchor);
    const head = keep(this.#selection?.head);
    this.#selection = anchor !== undefined && head !== undefined ? Object.freeze({ anchor, head }) : undefined;
    // A press keeps its start only while that position stays, so a release never reads a removed item.
    const drag = this.#drag;
    if (drag !== undefined && (keep(drag.start) === undefined || keep(drag.end) === undefined)) this.#drag = undefined;
    this.#emit("document");
  }

  compare(first: TextPosition, second: TextPosition): number {
    return this.#compare(this.#position(first), this.#position(second));
  }

  /** The order of two checked positions. */
  #compare(first: TextPosition, second: TextPosition): number {
    const a = this.#order.get(first.item);
    const b = this.#order.get(second.item);
    if (a === undefined || b === undefined) throw new RangeError("a position names an item that the document lacks");
    if (a.at !== b.at) return a.at - b.at;
    const sectionA = a.sections.get(first.section);
    const sectionB = a.sections.get(second.section);
    if (sectionA === undefined || sectionB === undefined) {
      throw new RangeError("a position names a section that its item lacks");
    }
    return sectionA !== sectionB ? sectionA - sectionB : first.offset - second.offset;
  }

  text(range: TextRange, format: "display" | "source" = "display"): string {
    const [from, to] = this.#ordered(this.#position(range.from), this.#position(range.to));
    if (format === "source") return this.#sourceText(from, to);
    if (format !== "display") throw new TypeError("a text format is display or source");
    const start = this.#place(from, "after");
    const end = this.#place(to, "before");
    if (start === undefined || end === undefined || start.row > end.row) return "";
    let out = "";
    for (let row = start.row; row <= end.row; row += 1) {
      const view = this.#rowAt(row) as ViewRow;
      const lower = row === start.row ? start.offset : 0;
      const upper = row === end.row ? end.offset : Number.POSITIVE_INFINITY;
      let at = 0;
      for (const segment of view.segments) {
        const from = Math.max(lower, at);
        const to = Math.min(upper, at + segment.text.length);
        if (segment.copy !== false && to > from) out += segment.text.slice(from - at, to - at);
        at += segment.text.length;
      }
      if (row < end.row) out += view.join;
    }
    return out;
  }

  activate(position: TextPosition, link?: string): boolean {
    const checked = this.#position(position);
    if (link !== undefined && typeof link !== "string") throw new TypeError("a link is a string");
    if (this.#activate === undefined) return false;
    this.#activate(checked, link);
    return true;
  }

  hitTest(point: Point): TextPosition | undefined {
    return this.rows.at({ column: Math.max(0, point.column), row: point.row + this.#list.state.top });
  }

  screenAt(position: TextPosition): Point | undefined {
    const point = this.rows.point(position);
    if (point === undefined) return undefined;
    const row = point.row - this.#list.state.top;
    return row >= 0 && row < this.#size.height ? { column: point.column, row } : undefined;
  }

  ensureVisible(position: TextPosition): boolean {
    const place = this.#place(this.#position(position), "after");
    if (place === undefined) return false;
    const found = this.#list.rowAt(place.row);
    if (found === undefined) return false;
    return this.#list.ensureVisible(found.item.key, found.row);
  }

  layout(size: Size): readonly Placement[] {
    const changed = size.width !== this.#size.width || size.height !== this.#size.height;
    this.#size = { width: size.width, height: size.height };
    this.#quiet = true;
    try {
      this.#list.layout(size);
    } finally {
      this.#quiet = false;
    }
    if (changed) this.#emit("layout");
    return [];
  }

  draw(canvas: Canvas, _focused: boolean): void {
    const top = this.#list.state.top;
    const ranges = this.#ranges();
    for (let line = 0; line < canvas.height; line += 1) {
      const found = this.#list.rowAt(top + line);
      if (found === undefined) break;
      const view = found.text as ViewRow;
      const marks = this.#marksOf(view, top + line, ranges);
      const cuts = new Set([0]);
      let length = 0;
      for (const segment of view.segments) {
        length += segment.text.length;
        cuts.add(length);
      }
      for (const mark of marks) {
        if (mark.from > 0 && mark.from < length) cuts.add(mark.from);
        if (mark.to > 0 && mark.to < length) cuts.add(mark.to);
      }
      const edges = [...cuts].sort((a, b) => a - b);
      const text = view.segments.map((segment) => segment.text).join("");
      let column = 0;
      for (let at = 0; at + 1 < edges.length; at += 1) {
        const from = edges[at] as number;
        const to = edges[at + 1] as number;
        const segment = segmentAt(view.segments, from);
        const styles: CanvasStyle[] = segment?.style === undefined ? [] : [segment.style];
        for (const mark of marks) if (mark.wholeRows || (mark.from <= from && mark.to >= to)) styles.push(mark.style);
        column = canvas.text(column, line, text.slice(from, to), styles.flat() as CanvasStyle);
      }
      const whole = marks.filter((mark) => mark.wholeRows).map((mark) => mark.style);
      if (whole.length > 0) canvas.fill(column, line, canvas.width - column, 1, whole.flat() as CanvasStyle);
    }
  }

  cursor(): Cursor | undefined {
    if (this.#caret === undefined) return undefined;
    const at = this.screenAt(this.#caret);
    if (at === undefined) return undefined;
    const shape = this.#support.appearance(this.#appearance).cursorShape;
    return shape === undefined ? at : { ...at, shape };
  }

  /** The view has no default keys: only the handlers of the extensions take a key. */
  key(event: KeyEvent): boolean {
    return this.#support.key(event, "beforeDefault");
  }

  mouse(event: MouseEvent): boolean {
    if (this.#support.mouse(event)) return true;
    if (event.button === "wheel_up" || event.button === "wheel_down") return this.#list.mouse(event);
    if (event.button !== "left") return false;
    if (event.action === "cancel") {
      this.#drag = undefined;
      return true;
    }
    if (event.action === "press") {
      const start = this.hitTest(event);
      const end = this.#endAt(event) ?? start;
      if (start === undefined || end === undefined) return false;
      this.#drag = { start, end, link: this.#linkAt(event), moved: false };
      this.caret = start;
      return true;
    }
    const drag = this.#drag;
    if (drag === undefined) return false;
    const point = { column: event.column, row: Math.max(0, Math.min(this.#size.height - 1, event.row)) };
    const start = this.hitTest(point);
    const end = this.#endAt(point) ?? start;
    if (event.action === "drag" || event.action === "release") {
      if (start !== undefined && end !== undefined && (event.action === "drag" || drag.moved)) {
        drag.moved = true;
        this.selection =
          this.#compare(start, drag.start) >= 0 ? { anchor: drag.start, head: end } : { anchor: drag.end, head: start };
      }
    }
    if (event.action === "release") {
      this.#drag = undefined;
      const selection = this.#selection;
      if (drag.moved && selection !== undefined) {
        if (this.#copyOnRelease) this.#support.copy(this.text({ from: selection.anchor, to: selection.head }));
      } else this.activate(drag.start, drag.link);
    }
    return true;
  }

  /** The link of the segment at `point`, or `undefined`. */
  #linkAt(point: Point): string | undefined {
    const row = this.#rowAt(point.row + this.#list.state.top);
    if (row === undefined) return undefined;
    let column = 0;
    for (const segment of row.segments) {
      column += measure(segment.text);
      if (point.column < column) return segment.link;
    }
    return undefined;
  }

  /**
   * The end of the grapheme at `point`: a column one cell on with the `after` bias reaches past a wide grapheme and a
   * replacement, so a selection holds the whole of them.
   */
  #endAt(point: Point): TextPosition | undefined {
    return this.rows.at(
      { column: Math.max(0, point.column) + 1, row: point.row + this.#list.state.top },
      "cell",
      "after",
    );
  }

  paste(text: string): boolean {
    return this.#support.paste(text);
  }

  #emit(kind: TextViewChange["kind"]): void {
    this.#revision += 1;
    this.#support.requestFrame();
    this.#support.emit(Object.freeze({ kind, revision: this.#revision }));
  }

  /** A checked copy of `position`: its item and section exist, and its offset is from 0 to the section length. */
  #position(position: TextPosition): TextPosition {
    if (typeof position !== "object" || position === null) throw new TypeError("a text position is an object");
    if (!this.#valid(position)) {
      throw new RangeError(
        `the position ${position.item}/${position.section}:${position.offset} is not in the document`,
      );
    }
    return Object.freeze({ item: position.item, section: position.section, offset: position.offset });
  }

  #valid(position: TextPosition): boolean {
    const section = this.#section(position.item, position.section);
    return (
      section !== undefined &&
      Number.isInteger(position.offset) &&
      position.offset >= 0 &&
      position.offset <= section.text.length
    );
  }

  #section(item: string, key: string): TextSection | undefined {
    const order = this.#order.get(item);
    const at = order?.sections.get(key);
    if (order === undefined || at === undefined) return undefined;
    return (this.#document.items[order.at] as TextItem).sections[at];
  }

  #ordered(first: TextPosition, second: TextPosition): [TextPosition, TextPosition] {
    return this.#compare(first, second) <= 0 ? [first, second] : [second, first];
  }

  /** The source text from `from` to `to`, with one line end between two sections and between two items. */
  #sourceText(from: TextPosition, to: TextPosition): string {
    const parts: string[] = [];
    const first = this.#order.get(from.item)?.at as number;
    const last = this.#order.get(to.item)?.at as number;
    for (let at = first; at <= last; at += 1) {
      const item = this.#document.items[at] as TextItem;
      for (const section of item.sections) {
        const position = { item: item.key, section: section.key, offset: 0 };
        const end = { ...position, offset: section.text.length };
        if (this.#compare(end, from) < 0 || this.#compare(position, to) > 0) continue;
        const start = section.key === from.section && item.key === from.item ? from.offset : 0;
        const stop = section.key === to.section && item.key === to.item ? to.offset : section.text.length;
        parts.push(section.text.slice(start, stop));
      }
    }
    return parts.join("\n");
  }

  #rowAt(row: number): TextRow | undefined {
    return this.#list.rowAt(row)?.text;
  }

  /**
   * The display place of `position`. At a boundary of two rows, `after` takes the later row. A position on hidden
   * markup goes to the nearest shown source on its `bias` side. A hidden section has no place.
   */
  #place(position: TextPosition, bias: Bias): Place | undefined {
    const item = this.#list.rowsOf(position.item);
    if (item === undefined) return undefined;
    const places: Place[] = [];
    let before: Place | undefined;
    let after: Place | undefined;
    for (const [index, row] of item.rows.entries()) {
      if ((row as ViewRow).section !== position.section) continue;
      let at = 0;
      for (const segment of row.segments) {
        const source = segment.source;
        const end = at + segment.text.length;
        if (source !== undefined) {
          const place = (offset: number): Place => ({ row: item.start + index, offset });
          if (position.offset >= source.from && position.offset <= source.to) {
            if (source.kind === "text") places.push(place(at + position.offset - source.from));
            else if (position.offset === source.from) places.push(place(at));
            else if (position.offset === source.to) places.push(place(end));
            else places.push(place(bias === "before" ? at : end));
          } else if (source.to < position.offset) before = place(end);
          else if (after === undefined && source.from > position.offset) after = place(at);
        }
        at = end;
      }
    }
    if (places.length > 0) return bias === "before" ? places[0] : places.at(-1);
    return bias === "before" ? (before ?? after) : (after ?? before);
  }

  /** The position at the display offset `offset` of the display row `row`. */
  #positionAt(row: number, offset: number, bias: Bias): TextPosition | undefined {
    const found = this.#list.rowAt(row);
    if (found === undefined) return undefined;
    const view = found.text as ViewRow;
    const position = (source: number): TextPosition =>
      Object.freeze({ item: found.item.key, section: view.section, offset: source });
    let at = 0;
    let previous: number | undefined;
    for (const [index, segment] of view.segments.entries()) {
      const end = at + segment.text.length;
      const source = segment.source;
      // A cell at a boundary belongs to the segment that starts there; only the end of the row stays in the last one.
      const inside = offset < end || (offset === end && index === view.segments.length - 1);
      if (source !== undefined && offset >= at && inside) {
        if (source.kind === "text") return position(source.from + offset - at);
        if (offset === at) return position(source.from);
        if (offset === end) return position(source.to);
        return position(bias === "before" ? source.from : source.to);
      }
      if (source === undefined && offset >= at && inside) {
        // A layout piece has no source, so the position goes to the shown source next to it.
        const next = view.segments.slice(index + 1).find((item) => item.source !== undefined)?.source?.from;
        const chosen = bias === "before" ? (previous ?? next) : (next ?? previous);
        return position(chosen ?? this.#nearest(found.item.key, view.section, row, bias));
      }
      if (source !== undefined) previous = source.to;
      at = end;
    }
    return position(previous ?? this.#nearest(found.item.key, view.section, row, bias));
  }

  /**
   * The source offset next to the display row `row`, for a row with no shown source, such as a blank row between two
   * Markdown blocks: the end of the source before it, or the start of the source after it for `after`.
   */
  #nearest(item: string, section: string, row: number, bias: Bias): number {
    const rows = this.#list.rowsOf(item);
    if (rows === undefined) return 0;
    const local = row - rows.start;
    const sources = (index: number) =>
      (rows.rows[index] as ViewRow).section === section
        ? (rows.rows[index] as ViewRow).segments.flatMap((segment) =>
            segment.source === undefined ? [] : [segment.source],
          )
        : [];
    let before: number | undefined;
    for (let index = local - 1; before === undefined && index >= 0; index -= 1) before = sources(index).at(-1)?.to;
    let after: number | undefined;
    for (let index = local + 1; after === undefined && index < rows.rows.length; index += 1)
      after = sources(index)[0]?.from;
    return (bias === "before" ? (before ?? after) : (after ?? before)) ?? 0;
  }

  #coordinates(): TextCoordinates<TextPosition> {
    const view = this;
    return Object.freeze({
      get count(): number {
        return view.#list.state.total;
      },
      text(row: number): string {
        return (
          view
            .#rowAt(row)
            ?.segments.map((segment) => segment.text)
            .join("") ?? ""
        );
      },
      at(point: Point, unit: ColumnUnit = "cell", bias: Bias = "before"): TextPosition | undefined {
        const row = view.#rowAt(point.row);
        if (row === undefined) return undefined;
        const text = row.segments.map((segment) => segment.text).join("");
        return view.#positionAt(point.row, offsetAtColumn(text, Math.max(0, point.column), unit, bias), bias);
      },
      point(position: TextPosition, unit: ColumnUnit = "cell", bias: Bias = "after"): Point | undefined {
        if (!view.#valid(position)) return undefined;
        const place = view.#place(position, bias);
        if (place === undefined) return undefined;
        const row = view.#rowAt(place.row) as TextRow;
        const before = row.segments
          .map((segment) => segment.text)
          .join("")
          .slice(0, place.offset);
        return { column: unit === "cell" ? measure(before) : graphemes(before).length / 3, row: place.row };
      },
    });
  }

  /** The display places of the selection and of the decorations of the extensions, found once for a frame. */
  #ranges(): PlacedRange[] {
    const ranges: PlacedRange[] = [];
    const add = (range: Selection<TextPosition>, style: CanvasStyle, wholeRows: boolean): void => {
      if (!this.#valid(range.anchor) || !this.#valid(range.head)) return;
      const [from, to] = this.#ordered(range.anchor, range.head);
      if (this.#compare(from, to) >= 0 && !wholeRows) return;
      const start = this.#place(from, "after");
      const end = this.#place(to, "before");
      if (start !== undefined && end !== undefined) ranges.push({ start, end, style, wholeRows });
    };
    if (this.#selection !== undefined) add(this.#selection, SELECTION, false);
    for (const decoration of this.#support.decorations() as Decoration<TextPosition>[]) {
      add(decoration.range, decoration.style, decoration.wholeRows === true);
    }
    return ranges;
  }

  /** The marks of the display row `row` for `ranges`, in display offsets of the row. */
  #marksOf(view: ViewRow, row: number, ranges: readonly PlacedRange[]): Mark[] {
    if (ranges.length === 0) return [];
    const length = view.segments.reduce((total, segment) => total + segment.text.length, 0);
    const marks: Mark[] = [];
    for (const range of ranges) {
      if (row < range.start.row || row > range.end.row) continue;
      const from = row === range.start.row ? range.start.offset : 0;
      const to = row === range.end.row ? range.end.offset : length;
      if (to > from || range.wholeRows) marks.push({ from, to, style: range.style, wholeRows: range.wholeRows });
    }
    return marks;
  }
}

/** The rows of `item` at `width`: the rows of each section, the last one with a line end before the next section. */
function renderItem(item: TextItem, width: number): ViewRow[] {
  const rows: ViewRow[] = [];
  for (const section of item.sections) {
    const own = section.render === undefined ? plainRows(section.text, width) : section.render(width);
    if (!Array.isArray(own)) throw new TypeError(`the section ${section.key} renders an array of rows`);
    if (own.length === 0) continue;
    // A copy puts one line end between two sections, also between two items.
    if (rows.length > 0) {
      const last = rows.at(-1) as ViewRow;
      rows[rows.length - 1] = { ...last, join: "\n" };
    }
    for (const row of own) rows.push({ segments: row.segments, join: row.join, section: section.key });
  }
  if (rows.length > 0) {
    const last = rows.at(-1) as ViewRow;
    rows[rows.length - 1] = { ...last, join: "\n" };
  }
  return rows;
}

/** The rows of plain `text` wrapped at `width`. A wrap joins with "", and a line end joins with "\n". */
function plainRows(text: string, width: number): TextRow[] {
  const triples = wrap(text, width);
  const rows: TextRow[] = [];
  for (let at = 0; at < triples.length; at += 3) {
    const from = triples[at] as number;
    const to = triples[at + 1] as number;
    const segment: Segment = { text: text.slice(from, to), source: { kind: "text", from, to } };
    rows.push({ segments: [segment], join: triples[at + 2] === 1 ? "" : "\n" });
  }
  return rows;
}

/** The segment of `segments` that holds the display offset `offset`. */
function segmentAt(segments: readonly Segment[], offset: number): Segment | undefined {
  let at = 0;
  for (const segment of segments) {
    if (offset < at + segment.text.length) return segment;
    at += segment.text.length;
  }
  return undefined;
}

function samePosition(first: TextPosition | undefined, second: TextPosition | undefined): boolean {
  return (
    first === second ||
    (first !== undefined &&
      second !== undefined &&
      first.item === second.item &&
      first.section === second.section &&
      first.offset === second.offset)
  );
}

/** The place of each item and of each section in its item, by key. */
type Order = Map<string, { readonly at: number; readonly sections: Map<string, number> }>;

/** Check `document`, and return its order. A document that is not valid throws a `TypeError`. */
function checkDocument(document: TextDocument): Order {
  if (typeof document !== "object" || document === null || typeof document.key !== "string") {
    throw new TypeError("a text document has a key");
  }
  if (!Array.isArray(document.items)) throw new TypeError("a text document has items");
  const order: Order = new Map();
  for (const [at, item] of document.items.entries()) {
    if (typeof item !== "object" || item === null || typeof item.key !== "string" || !Array.isArray(item.sections)) {
      throw new TypeError("a text item has a key and sections");
    }
    if (order.has(item.key)) throw new TypeError(`two text items have the key ${item.key}`);
    const sections = new Map<string, number>();
    order.set(item.key, { at, sections });
    for (const [index, section] of item.sections.entries()) {
      const valid =
        typeof section === "object" &&
        section !== null &&
        typeof section.key === "string" &&
        (section.kind === "text" || section.kind === "label") &&
        typeof section.text === "string" &&
        (section.render === undefined || typeof section.render === "function");
      if (!valid) throw new TypeError(`a section of the item ${item.key} has a key, a kind, a text, and a render`);
      if (sections.has(section.key)) throw new TypeError(`the item ${item.key} has two sections ${section.key}`);
      sections.set(section.key, index);
    }
  }
  return order;
}
