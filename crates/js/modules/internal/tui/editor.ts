/**
 * `TextEditor` of `yuke:tui`: a text draft with spans, a selection, and the default editing keys. The display text
 * shows the label of each span in place of its source. `lines` splits the display text at its line ends. `rows` wraps
 * each line at the width of the editor. Each position is a source offset.
 */
import { strokeOf } from "yuke:internal/tui/keys";
import { graphemes, measure, offsetAtColumn, wrap } from "yuke:internal/tui/text";
import { checkAppearance, registerWidget, TextSupport } from "yuke:internal/tui/widgets";
import type {
  Bias,
  Canvas,
  CanvasStyle,
  ColumnUnit,
  Cursor,
  EditorChange,
  EditorOptions,
  EditorSpan,
  EditorState,
  KeyEvent,
  MouseEvent,
  OffsetRange,
  Placement,
  Point,
  Selection,
  Size,
  TextAppearance,
  TextCoordinates,
  TextEdit,
  TextExtension,
} from "yuke:tui";

const SELECTION: CanvasStyle = [{ reverse: true }, "editor.selection"];
const LABEL: CanvasStyle = [{ fg: "accent" }, "editor.label"];
const PLACEHOLDER: CanvasStyle = [{ dim: true }, "editor.placeholder"];
const NEWLINE_KEYS = new Set(["shift+enter", "alt+enter", "ctrl+j"]);
const UNWRAPPED = 0x7f_ff_ff_ff;

/** A row of the display text: `from` and `to` are display offsets, and `soft` marks a wrap at its end. */
interface Row {
  readonly from: number;
  readonly to: number;
  readonly soft: boolean;
}

/** The display text of a state at a width: the labels in place of their spans, and its lines and rows. */
interface Layout {
  readonly state: EditorState;
  readonly width: number;
  readonly shown: string;
  readonly lines: readonly Row[];
  readonly rows: readonly Row[];
}

/** A run of display text with the styles that cover it. */
interface Mark {
  readonly from: number;
  readonly to: number;
  readonly style: CanvasStyle;
  readonly wholeRows: boolean;
}

export class TextEditor {
  readonly kind = "editor";
  readonly focusable = true;
  readonly role: string;
  readonly lines: TextCoordinates<number>;
  readonly rows: TextCoordinates<number>;
  readonly #support: TextSupport<number, EditorChange>;
  readonly #multiline: boolean;
  readonly #placeholder: string;
  readonly #appearance: TextAppearance;
  readonly #submit: ((state: EditorState) => void) | undefined;
  #state: EditorState;
  #size: Size = { width: 0, height: 0 };
  #scroll = 0;
  /** The cell column that up and down keep across short rows, until another move. */
  #goal: number | undefined;
  /** The anchor of a mouse drag. */
  #drag: number | undefined;
  #layout: Layout | undefined;
  /** The text width at the last layout. */
  #laidOut = 0;

  constructor(options: EditorOptions = {}) {
    if (typeof options !== "object" || options === null) throw new TypeError("editor options are an object");
    const role = options.role ?? "field";
    if (role !== "composer" && role !== "field") throw new TypeError("an editor role is composer or field");
    if (options.submit !== undefined && typeof options.submit !== "function") {
      throw new TypeError("submit is a function");
    }
    if (options.placeholder !== undefined && typeof options.placeholder !== "string") {
      throw new TypeError("a placeholder is a string");
    }
    this.role = role;
    this.#multiline = options.multiline !== false;
    this.#placeholder = options.placeholder ?? "";
    this.#submit = options.submit;
    this.#support = new TextSupport(options.group);
    this.#appearance = options.appearance === undefined ? {} : checkAppearance(options.appearance);
    this.#state = this.#checked(options.state ?? { text: "", selection: { anchor: 0, head: 0 }, spans: [] });
    this.lines = this.#coordinates((layout) => layout.lines);
    this.rows = this.#coordinates((layout) => layout.rows);
    registerWidget(this, this.#support);
  }

  get state(): EditorState {
    return this.#state;
  }

  get caret(): number {
    return this.#state.selection.head;
  }

  set caret(offset: number) {
    this.selection = { anchor: offset, head: offset };
  }

  get selection(): Selection<number> {
    return this.#state.selection;
  }

  set selection(selection: Selection<number>) {
    if (typeof selection !== "object" || selection === null) throw new TypeError("a selection is an object");
    const next = Object.freeze({
      anchor: this.#snap(this.#offset(selection.anchor)),
      head: this.#snap(this.#offset(selection.head)),
    });
    const now = this.#state.selection;
    if (next.anchor === now.anchor && next.head === now.head) return;
    this.#goal = undefined;
    this.#commit("selection", Object.freeze({ ...this.#state, selection: next }), []);
  }

  get contexts(): readonly string[] {
    return [this.role, ...this.#support.contexts()];
  }

  get visibleRows(): OffsetRange {
    const count = this.#rowCount(this.#current());
    return { from: this.#scroll, to: Math.min(count, this.#scroll + this.#size.height) };
  }

  extend(signal: AbortSignal): TextExtension<number, EditorChange> {
    return this.#support.extend(signal);
  }

  replace(from: number, to: number, text: string, spans: readonly EditorSpan[] = []): void {
    const start = this.#offset(from);
    const end = this.#offset(to);
    if (start > end) throw new RangeError(`a replaced range ends before it starts: ${start} to ${end}`);
    if (typeof text !== "string") throw new TypeError("a replacement is a string");
    const inserted = this.#line(text);
    const insertedSpans = checkSpans(inserted, spans);
    const snapped = start === end ? this.#snap(start) : undefined;
    const [effectiveFrom, effectiveTo] = snapped === undefined ? this.#expand(start, end) : [snapped, snapped];
    const old = this.#state;
    const delta = inserted.length - (effectiveTo - effectiveFrom);
    const kept = old.spans.flatMap((span) => {
      if (span.to <= effectiveFrom) return [span];
      if (span.from >= effectiveTo) return [shifted(span, delta)];
      return [];
    });
    const added = insertedSpans.map((span) => shifted(span, effectiveFrom));
    const textAfter = old.text.slice(0, effectiveFrom) + inserted + old.text.slice(effectiveTo);
    const spansAfter = Object.freeze([...kept, ...added].sort((a, b) => a.from - b.from));
    // An insertion can join a grapheme with its neighbor, so the caret goes to the next whole boundary.
    const caret = nextBoundary(textAfter, spansAfter, effectiveFrom + inserted.length);
    const after = Object.freeze({
      text: textAfter,
      selection: Object.freeze({ anchor: caret, head: caret }),
      spans: spansAfter,
    });
    const edit = Object.freeze({ from: effectiveFrom, to: effectiveTo, text: inserted, spans: insertedSpans });
    this.#goal = undefined;
    this.#commit("edit", after, [edit]);
  }

  reset(state: EditorState): void {
    this.#replaceAll("reset", state);
  }

  restore(state: EditorState): void {
    this.#replaceAll("restore", state);
  }

  heightFor(width: number): number {
    if (!Number.isInteger(width) || width < 0) throw new RangeError("a width is a whole number of cells");
    if (width === 0) return 0;
    return this.#rowCount(this.#layoutAt(this.#textWidth(width)));
  }

  submit(): void {
    this.#submit?.(this.#state);
  }

  hitTest(point: Point): number | undefined {
    const column = point.column - this.#promptWidth(this.#size.width);
    return this.rows.at({ column: Math.max(0, column), row: point.row + this.#scroll });
  }

  screenAt(position: number): Point | undefined {
    const point = this.rows.point(position);
    if (point === undefined) return undefined;
    const row = point.row - this.#scroll;
    if (row < 0 || row >= this.#size.height) return undefined;
    return { column: point.column + this.#promptWidth(this.#size.width), row };
  }

  ensureVisible(position: number): boolean {
    if (this.#size.height <= 0 || this.#size.width <= 0) return false;
    const point = this.rows.point(position);
    if (point === undefined) return false;
    const last = Math.max(0, this.#rowCount(this.#current()) - this.#size.height);
    const scroll = Math.min(last, point.row, Math.max(this.#scroll, point.row - this.#size.height + 1));
    if (scroll !== this.#scroll) {
      this.#scroll = scroll;
      this.#support.requestFrame();
    }
    return true;
  }

  layout(size: Size): readonly Placement[] {
    // A new prompt changes the wrap at the same size, so the text width counts too.
    const textWidth = this.#textWidth(size.width);
    if (size.width !== this.#size.width || size.height !== this.#size.height || textWidth !== this.#laidOut) {
      this.#size = { width: size.width, height: size.height };
      this.#laidOut = textWidth;
      const count = this.#rowCount(this.#current());
      this.#scroll = Math.max(0, Math.min(this.#scroll, count - size.height));
      this.ensureVisible(this.caret);
    }
    return [];
  }

  draw(canvas: Canvas, _focused: boolean): void {
    const appearance = this.#support.appearance(this.#appearance);
    const promptWidth = this.#promptWidth(canvas.width);
    const layout = this.#current();
    if (this.#scroll === 0 && promptWidth > 0) {
      canvas.region(0, 0, promptWidth, 1).text(0, 0, appearance.prompt ?? "", appearance.promptStyle);
    }
    if (this.#state.text === "" && this.#placeholder !== "" && this.#scroll === 0) {
      canvas.text(promptWidth, 0, this.#placeholder, PLACEHOLDER);
    }
    const marks = this.#marks(layout);
    const text = canvas.region(promptWidth, 0, canvas.width - promptWidth, canvas.height);
    const last = Math.min(layout.rows.length, this.#scroll + canvas.height);
    for (let index = this.#scroll; index < last; index += 1) {
      const row = layout.rows[index] as Row;
      const line = index - this.#scroll;
      const cuts = new Set([row.from, row.to]);
      for (const mark of marks) {
        if (mark.from > row.from && mark.from < row.to) cuts.add(mark.from);
        if (mark.to > row.from && mark.to < row.to) cuts.add(mark.to);
      }
      const edges = [...cuts].sort((a, b) => a - b);
      let column = 0;
      for (let at = 0; at + 1 < edges.length; at += 1) {
        const from = edges[at] as number;
        const to = edges[at + 1] as number;
        const styles = marks
          .filter((mark) =>
            mark.wholeRows ? overlaps(mark, row) : mark.from <= from && mark.to >= to && mark.to > from,
          )
          .map((mark) => mark.style);
        column = text.text(column, line, layout.shown.slice(from, to), styles.flat() as CanvasStyle);
      }
      const whole = marks.filter((mark) => mark.wholeRows && overlaps(mark, row)).map((mark) => mark.style);
      if (whole.length > 0) text.fill(column, line, text.width - column, 1, whole.flat() as CanvasStyle);
    }
  }

  cursor(): Cursor | undefined {
    const at = this.screenAt(this.caret);
    if (at === undefined) return undefined;
    const shape = this.#support.appearance(this.#appearance).cursorShape;
    return shape === undefined ? at : { ...at, shape };
  }

  key(event: KeyEvent): boolean {
    if (this.#support.key(event, "beforeDefault")) return true;
    const stroke = strokeOf(event);
    const select = stroke.startsWith("shift+");
    const move = select ? stroke.slice("shift+".length) : stroke;
    const { anchor, head } = this.#state.selection;
    const [low, high] = anchor < head ? [anchor, head] : [head, anchor];
    switch (move) {
      case "left":
      case "right": {
        const target =
          !select && low !== high ? (move === "left" ? low : high) : this.#step(head, move === "left" ? -1 : 1);
        this.#moveTo(target, select);
        return true;
      }
      case "up":
      case "down":
        this.#vertical(move === "up" ? -1 : 1, select);
        return true;
      case "home":
      case "end": {
        const layout = this.#current();
        const line = rowOf(layout.lines, this.#toDisplay(layout, head, "after"), "after");
        const target = this.#toSource(
          layout,
          move === "home" ? line.from : line.to,
          move === "home" ? "before" : "after",
        );
        this.#moveTo(target, select);
        return true;
      }
    }
    if (stroke === "backspace" || stroke === "delete") {
      if (low !== high) this.replace(low, high, "");
      else if (stroke === "backspace" && head > 0) this.replace(this.#step(head, -1), head, "");
      else if (stroke === "delete" && head < this.#state.text.length) this.replace(head, this.#step(head, 1), "");
      return true;
    }
    if (stroke === "enter") {
      if (this.#submit === undefined) return false;
      this.submit();
      return true;
    }
    if (NEWLINE_KEYS.has(stroke)) {
      if (!this.#multiline) return false;
      this.replace(low, high, "\n");
      return true;
    }
    const { ctrl, alt, super: superKey } = event.modifiers;
    if (event.code !== "character" || event.text === "" || ctrl || alt || superKey) return false;
    this.replace(low, high, event.text);
    return true;
  }

  mouse(event: MouseEvent): boolean {
    if (this.#support.mouse(event)) return true;
    if (event.button === "wheel_up" || event.button === "wheel_down") {
      const count = this.#rowCount(this.#current());
      const scroll = Math.max(
        0,
        Math.min(count - this.#size.height, this.#scroll + (event.button === "wheel_up" ? -1 : 1)),
      );
      if (scroll !== this.#scroll) {
        this.#scroll = scroll;
        this.#support.requestFrame();
      }
      return true;
    }
    if (event.button !== "left") return false;
    if (event.action === "cancel" || event.action === "release") {
      this.#drag = undefined;
      return true;
    }
    // A drag above the text reaches its start, and one below it reaches its end.
    const hit = this.hitTest(event) ?? (event.row < 0 ? 0 : this.#state.text.length);
    if (event.action === "press") {
      this.#drag = hit;
      this.caret = hit;
    } else if (event.action === "drag" && this.#drag !== undefined) {
      this.selection = { anchor: this.#drag, head: hit };
    }
    return true;
  }

  paste(text: string): boolean {
    if (this.#support.paste(text)) return true;
    const { anchor, head } = this.#state.selection;
    this.replace(Math.min(anchor, head), Math.max(anchor, head), text);
    return true;
  }

  /** Put `state` in place with one edit over the whole text. */
  #replaceAll(kind: "reset" | "restore", state: EditorState): void {
    const after = this.#checked(state);
    const edit = Object.freeze({ from: 0, to: this.#state.text.length, text: after.text, spans: after.spans });
    this.#goal = undefined;
    this.#commit(kind, after, [edit]);
  }

  /** Put `after` in place, keep the caret in view, and tell the extensions. */
  #commit(kind: EditorChange["kind"], after: EditorState, changes: readonly TextEdit[]): void {
    const before = this.#state;
    this.#state = after;
    this.ensureVisible(after.selection.head);
    this.#support.requestFrame();
    this.#support.emit(Object.freeze({ kind, before, after, changes: Object.freeze([...changes]) }));
  }

  /** A copy of `state` with whole offsets inside its text, frozen. */
  #checked(state: EditorState): EditorState {
    if (typeof state !== "object" || state === null || typeof state.text !== "string") {
      throw new TypeError("an editor state has a text");
    }
    const text = this.#line(state.text);
    const spans = checkSpans(text, state.spans);
    const within = (value: number): number => {
      if (!Number.isInteger(value) || value < 0 || value > text.length) {
        throw new RangeError(`the offset ${value} is outside the text of ${text.length} units`);
      }
      return snap(text, spans, value);
    };
    if (typeof state.selection !== "object" || state.selection === null) {
      throw new TypeError("an editor state has a selection");
    }
    const selection = Object.freeze({ anchor: within(state.selection.anchor), head: within(state.selection.head) });
    return Object.freeze({ text, selection, spans });
  }

  /** `text` of a one-line editor writes each line end as a space, so each offset stays. */
  #line(text: string): string {
    return this.#multiline ? text : text.replace(/[\r\n]/g, " ");
  }

  #offset(value: number): number {
    if (!Number.isInteger(value) || value < 0 || value > this.#state.text.length) {
      throw new RangeError(`the offset ${value} is outside the text of ${this.#state.text.length} units`);
    }
    return value;
  }

  #snap(offset: number): number {
    return snap(this.#state.text, this.#state.spans, offset);
  }

  /** The range of `from` to `to` grown to whole graphemes and whole spans. */
  #expand(from: number, to: number): [number, number] {
    const { text, spans } = this.#state;
    let start = previousBoundary(text, from, true);
    let end = nextBoundaryOf(text, to);
    // Spans end on grapheme edges and do not overlap, so one pass over them is enough.
    for (const span of spans) {
      if (span.from < end && span.to > start) {
        start = Math.min(start, span.from);
        end = Math.max(end, span.to);
      }
    }
    return [start, end];
  }

  /** The boundary one grapheme or one span from `offset`, toward the start for `-1`. */
  #step(offset: number, direction: -1 | 1): number {
    const { text, spans } = this.#state;
    const span = spans.find((item) => (direction < 0 ? item.to === offset : item.from === offset));
    if (span !== undefined) return direction < 0 ? span.from : span.to;
    return direction < 0 ? previousBoundary(text, offset, false) : nextBoundaryOf(text, offset + 1);
  }

  #moveTo(target: number, select: boolean): void {
    this.#goal = undefined;
    this.selection = { anchor: select ? this.#state.selection.anchor : target, head: target };
  }

  /** Move the head by `count` display rows, at the goal column. */
  #vertical(count: number, select: boolean): void {
    const point = this.rows.point(this.caret);
    if (point === undefined) return;
    const goal = this.#goal ?? point.column;
    const row = Math.max(0, Math.min(this.#rowCount(this.#current()) - 1, point.row + count));
    const target = this.rows.at({ column: goal, row });
    if (target === undefined) return;
    this.selection = { anchor: select ? this.#state.selection.anchor : target, head: target };
    this.#goal = goal;
  }

  #promptWidth(width: number): number {
    const prompt = this.#support.appearance(this.#appearance).prompt ?? "";
    // The prompt leaves at least one cell for the text.
    return Math.max(0, Math.min(measure(prompt), width - 1));
  }

  #textWidth(width: number): number {
    return Math.max(1, width - this.#promptWidth(width));
  }

  #current(): Layout {
    return this.#layoutAt(this.#textWidth(this.#size.width));
  }

  /** The layout of the state at `width` text cells. The last one stays for the next call. */
  #layoutAt(width: number): Layout {
    const state = this.#state;
    const cached = this.#layout;
    if (cached !== undefined && cached.state === state && cached.width === width) return cached;
    let shown = "";
    let at = 0;
    for (const span of state.spans) {
      shown += state.text.slice(at, span.from) + span.label;
      at = span.to;
    }
    shown += state.text.slice(at);
    // No line is as wide as the widest width, so its wrap gives the lines alone.
    const layout = { state, width, shown, lines: rowsOf(wrap(shown, UNWRAPPED)), rows: rowsOf(wrap(shown, width)) };
    this.#layout = layout;
    return layout;
  }

  /** The rows of `layout`, with the row for a caret after a full last row. */
  #rowCount(layout: Layout): number {
    const last = layout.rows.at(-1) as Row;
    return layout.rows.length + (measure(layout.shown.slice(last.from, last.to)) >= layout.width ? 1 : 0);
  }

  #toDisplay(layout: Layout, offset: number, bias: Bias): number {
    let shift = 0;
    for (const span of layout.state.spans) {
      if (offset <= span.from) break;
      if (offset < span.to) return span.from + shift + (bias === "before" ? 0 : span.label.length);
      shift += span.label.length - (span.to - span.from);
    }
    return offset + shift;
  }

  #toSource(layout: Layout, display: number, bias: Bias): number {
    let shift = 0;
    for (const span of layout.state.spans) {
      const start = span.from + shift;
      if (display <= start) break;
      if (display < start + span.label.length) return bias === "before" ? span.from : span.to;
      shift += span.label.length - (span.to - span.from);
    }
    return display - shift;
  }

  /** Coordinates over the rows that `pick` takes from the current layout. */
  #coordinates(pick: (layout: Layout) => readonly Row[]): TextCoordinates<number> {
    const editor = this;
    return Object.freeze({
      get count(): number {
        const layout = editor.#current();
        const rows = pick(layout);
        return rows === layout.rows ? editor.#rowCount(layout) : rows.length;
      },
      text(row: number): string {
        const layout = editor.#current();
        const found = pick(layout)[row];
        return found === undefined ? "" : layout.shown.slice(found.from, found.to);
      },
      at(point: Point, unit: ColumnUnit = "cell", bias: Bias = "before"): number | undefined {
        const layout = editor.#current();
        const rows = pick(layout);
        if (!Number.isInteger(point.row) || point.row < 0) return undefined;
        // The row after a full last row holds only the end of the text.
        if (point.row === rows.length && rows === layout.rows && editor.#rowCount(layout) > rows.length) {
          return layout.state.text.length;
        }
        const row = rows[point.row];
        if (row === undefined) return undefined;
        const display =
          row.from + offsetAtColumn(layout.shown.slice(row.from, row.to), Math.max(0, point.column), unit, bias);
        return editor.#toSource(layout, display, bias);
      },
      point(position: number, unit: ColumnUnit = "cell", bias: Bias = "after"): Point | undefined {
        if (!Number.isInteger(position) || position < 0 || position > editor.#state.text.length) return undefined;
        const layout = editor.#current();
        const rows = pick(layout);
        const display = editor.#toDisplay(layout, position, bias);
        const index = rows.indexOf(rowOf(rows, display, bias));
        const row = rows[index] as Row;
        const before = layout.shown.slice(row.from, display);
        const column = unit === "cell" ? measure(before) : graphemes(before).length / 3;
        if (rows !== layout.rows || unit !== "cell" || column < layout.width) return { column, row: index };
        // A caret after a full last row goes to the start of the next row; on another row it stays in the last cell.
        return index === rows.length - 1 ? { column: 0, row: index + 1 } : { column: layout.width - 1, row: index };
      },
    });
  }

  /** The styled runs of the display text: span labels, the selection, then the decorations of the extensions. */
  #marks(layout: Layout): Mark[] {
    const marks: Mark[] = [];
    for (const span of layout.state.spans) {
      const from = this.#toDisplay(layout, span.from, "before");
      marks.push({ from, to: from + span.label.length, style: LABEL, wholeRows: false });
    }
    const { anchor, head } = layout.state.selection;
    const range = (from: number, to: number, style: CanvasStyle, wholeRows: boolean): void => {
      const low = this.#toDisplay(layout, Math.min(from, to), "before");
      const high = this.#toDisplay(layout, Math.max(from, to), "after");
      if (low < high || wholeRows) marks.push({ from: low, to: high, style, wholeRows });
    };
    if (anchor !== head) range(anchor, head, SELECTION, false);
    for (const decoration of this.#support.decorations()) {
      const { anchor: from, head: to } = decoration.range;
      if (!Number.isInteger(from) || !Number.isInteger(to)) continue;
      const length = layout.state.text.length;
      range(clamp(from, length), clamp(to, length), decoration.style, decoration.wholeRows === true);
    }
    return marks;
  }
}

/**
 * A frozen copy of the spans of `text`, with each span checked: in order, apart, and on grapheme edges inside the text.
 * An image span covers one U+FFFC and holds media with a blob.
 */
function checkSpans(text: string, spans: readonly EditorSpan[]): readonly EditorSpan[] {
  if (!Array.isArray(spans)) throw new TypeError("spans are an array");
  const edges = spans.length === 0 ? new Set<number>() : new Set(boundaries(text));
  let end = 0;
  return Object.freeze(
    spans.map((span: EditorSpan) => {
      if (typeof span !== "object" || span === null) throw new TypeError("a span is an object");
      const { from, to, label } = span;
      if (!Number.isInteger(from) || !Number.isInteger(to) || from < end || to <= from || to > text.length) {
        throw new RangeError(`a span from ${from} to ${to} is not in order inside the text`);
      }
      if (!edges.has(from) || !edges.has(to)) throw new RangeError(`a span from ${from} to ${to} splits a grapheme`);
      if (typeof label !== "string" || label === "" || /[\r\n]/.test(label)) {
        throw new TypeError("a span label is one line that is not empty");
      }
      end = to;
      if (span.kind === "paste") return Object.freeze({ from, to, kind: "paste", label });
      if (span.kind !== "image") throw new TypeError("a span kind is paste or image");
      if (text.slice(from, to) !== "￼") throw new RangeError("an image span covers one U+FFFC");
      const media = span.media;
      const blob = media?.blob;
      const valid =
        typeof media?.mime === "string" &&
        (media.filename === undefined || typeof media.filename === "string") &&
        typeof blob?.digest === "string" &&
        Number.isInteger(blob.len) &&
        blob.len >= 0;
      if (!valid) throw new TypeError("an image span has media: a mime type and a blob with a digest and a length");
      const copy = { blob: Object.freeze({ digest: blob.digest, len: blob.len }), mime: media.mime };
      return Object.freeze({
        from,
        to,
        kind: "image",
        label,
        media: Object.freeze(media.filename === undefined ? copy : { ...copy, filename: media.filename }),
      });
    }),
  );
}

function shifted(span: EditorSpan, delta: number): EditorSpan {
  return Object.freeze({ ...span, from: span.from + delta, to: span.to + delta });
}

/** The grapheme starts of `text` and its length. */
function boundaries(text: string): number[] {
  const triples = graphemes(text);
  const starts: number[] = [];
  for (let at = 0; at < triples.length; at += 3) starts.push(triples[at] as number);
  starts.push(text.length);
  return starts;
}

/** The last grapheme boundary before `offset`, or at it when `inclusive`. */
function previousBoundary(text: string, offset: number, inclusive: boolean): number {
  return boundaries(text).findLast((start) => (inclusive ? start <= offset : start < offset)) ?? 0;
}

/** The first grapheme boundary at or after `offset`. */
function nextBoundaryOf(text: string, offset: number): number {
  return boundaries(text).find((start) => start >= offset) ?? text.length;
}

/** The first boundary at or after `offset` that is outside each span. */
function nextBoundary(text: string, spans: readonly EditorSpan[], offset: number): number {
  const span = spans.find((item) => item.from < offset && item.to > offset);
  return nextBoundaryOf(text, span === undefined ? offset : span.to);
}

/** The boundary nearest `offset`: a grapheme edge or a span edge. A tie takes the later one. */
function snap(text: string, spans: readonly EditorSpan[], offset: number): number {
  const span = spans.find((item) => item.from < offset && item.to > offset);
  const [low, high] =
    span === undefined ? [previousBoundary(text, offset, true), nextBoundaryOf(text, offset)] : [span.from, span.to];
  return offset - low < high - offset ? low : high;
}

function rowsOf(triples: Int32Array): Row[] {
  const rows: Row[] = [];
  for (let at = 0; at < triples.length; at += 3) {
    rows.push({ from: triples[at] as number, to: triples[at + 1] as number, soft: triples[at + 2] === 1 });
  }
  return rows;
}

/** The row that holds the display offset `display`. At a soft break, `after` takes the next row. */
function rowOf(rows: readonly Row[], display: number, bias: Bias): Row {
  for (const [index, row] of rows.entries()) {
    if (display > row.to) continue;
    if (display === row.to && row.soft && bias === "after" && index + 1 < rows.length) continue;
    return row;
  }
  return rows.at(-1) as Row;
}

/**
 * True when `mark` covers part of `row`. An empty mark covers the row of its offset. A mark that holds the offset of an
 * empty row covers that row.
 */
function overlaps(mark: Mark, row: Row): boolean {
  if (mark.from === mark.to)
    return row.from <= mark.from && (mark.from < row.to || (mark.from === row.to && !row.soft));
  if (row.from === row.to) return mark.from <= row.from && mark.to > row.from;
  return mark.from < row.to && mark.to > row.from;
}

function clamp(value: number, length: number): number {
  return Math.max(0, Math.min(length, value));
}
