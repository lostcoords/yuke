// The declaration of the public module `yuke:tui`.

/**
 * The types of the terminal interface and its stateless helpers. An import of this module starts nothing, so a plugin
 * can import it in each mode. Coordinates are local cells from 0. Text offsets are UTF-16 units, as in JavaScript
 * strings.
 */
declare module "yuke:tui" {
  import type { NoticeLevel } from "yuke:plugins";
  import type { Media, SessionId } from "yuke:protocol";

  export interface Size {
    readonly width: number;
    readonly height: number;
  }

  export interface Point {
    readonly column: number;
    readonly row: number;
  }

  export interface Rect extends Point, Size {}

  /** A steady block, underline, or bar. No shape keeps the shape of the terminal settings. */
  export type CursorShape = "block" | "underline" | "bar";

  export interface Cursor extends Point {
    readonly shape?: CursorShape | undefined;
  }

  /** Remove a registration. A second call does nothing. */
  export type Disposer = () => void;

  export type Direction = "row" | "column";

  export type FocusDirection = "left" | "right" | "up" | "down";

  /** The modifiers of a key or a mouse event. A terminal reports only shift, alt, and ctrl with a mouse event. */
  export interface Modifiers {
    readonly shift: boolean;
    readonly alt: boolean;
    readonly ctrl: boolean;
    readonly super: boolean;
    readonly hyper: boolean;
    readonly meta: boolean;
  }

  type FunctionNumber =
    | 1
    | 2
    | 3
    | 4
    | 5
    | 6
    | 7
    | 8
    | 9
    | 10
    | 11
    | 12
    | 13
    | 14
    | 15
    | 16
    | 17
    | 18
    | 19
    | 20
    | 21
    | 22
    | 23
    | 24
    | 25
    | 26
    | 27
    | 28
    | 29
    | 30
    | 31
    | 32
    | 33
    | 34
    | 35;

  /** `character` for a key of one character, else the name of the key. A function key past 35 is `unknown`. */
  export type KeyCode =
    | "character"
    | "enter"
    | "tab"
    | "backspace"
    | "esc"
    | "insert"
    | "delete"
    | "left"
    | "right"
    | "up"
    | "down"
    | "page_up"
    | "page_down"
    | "home"
    | "end"
    | "menu"
    | `f${FunctionNumber}`
    | "unknown";

  export interface KeyEvent {
    readonly type: "key";
    readonly code: KeyCode;
    /** The character of a `character` key, else "". */
    readonly character: string;
    /** The key with shift on the current layout, from a kitty terminal, else "". */
    readonly shifted: string;
    /** The key at the same place on a US layout, from a kitty terminal, else "". `strokeOf` does not read it. */
    readonly baseLayout: string;
    /** The text that the key types, else "". */
    readonly text: string;
    readonly modifiers: Modifiers;
  }

  export type MouseButton =
    | "left"
    | "middle"
    | "right"
    | "none"
    | "wheel_up"
    | "wheel_down"
    | "wheel_left"
    | "wheel_right"
    | `button_${number}`;

  /**
   * A mouse event, local to the view. A captured drag can leave the rect of the view, so its coordinates can be
   * negative or past the size.
   */
  export interface MouseEvent extends Point {
    readonly type: "mouse";
    readonly button: MouseButton;
    /** `cancel` ends a capture without a release, as when a modal opens during a drag. */
    readonly action: "press" | "release" | "motion" | "drag" | "cancel";
    readonly modifiers: Modifiers;
  }

  /** The names of the base palette. Each one has a color for a dark and a light background. */
  export type PaletteColor =
    | "fg"
    | "bg"
    | "surfaceFg"
    | "strongFg"
    | "accent"
    | "accentMuted"
    | "surface"
    | "warn"
    | "danger"
    | "pendingBg"
    | "errorBg"
    | "diffAddBg"
    | "diffDelBg";

  /** A color: a palette index from 0 to 255, `#` and six hex digits, `reset`, or a name of the base palette. */
  export type Color = number | `#${string}` | "reset" | PaletteColor;

  /** A style: the colors and the attributes of a cell. `link` names a style group whose fields fill the missing ones. */
  export interface Style {
    readonly fg?: Color | undefined;
    readonly bg?: Color | undefined;
    /** The color of the underline. It does not turn the underline on. */
    readonly underlineColor?: Color | undefined;
    readonly bold?: boolean | undefined;
    readonly dim?: boolean | undefined;
    readonly italic?: boolean | undefined;
    readonly reverse?: boolean | undefined;
    readonly underline?: boolean | undefined;
    readonly link?: string | undefined;
  }

  /** A change of a style group: a field changes, `null` deletes it, and a missing field stays. */
  export type StylePatch = { readonly [K in keyof Style]?: Style[K] | null };

  /** A command: the palette lists it, and a key binding names it. */
  export interface Command {
    /** The name: letters, digits, and `:`, `-`, `_`, `.`. */
    readonly name: string;
    /** One line for the palette, beside the name. */
    readonly description?: string | undefined;
    /** Run the command. The keymap does not wait for a promise, so the keys go on during the run. */
    readonly run: (args: unknown) => void | Promise<void>;
    /** False when the command cannot run now. A disabled command passes its key on. */
    readonly enabled?: (() => boolean) | undefined;
  }

  /** A command as the palette lists it. */
  export interface CommandItem {
    readonly name: string;
    readonly description?: string | undefined;
    readonly enabled: boolean;
  }

  /** A notice of the host or of a plugin. A notice with the level, source, and text of the last one raises `count`. */
  export interface Notice {
    readonly level: NoticeLevel;
    /** The plugin name, `console`, or `host:…`. */
    readonly source: string;
    readonly text: string;
    readonly count: number;
  }

  /** A style group name, a style, or a list of style group names and styles. A later item wins per field. */
  export type CanvasStyle = string | Style | readonly (string | Style)[];

  /**
   * What a view draws on.
   * Use it only during the draw call that gets it.
   * A draw outside its rect is cut off.
   */
  export interface Canvas extends Size {
    /** Write `text` on one row and return the column after it. */
    readonly text: (column: number, row: number, text: string, style?: CanvasStyle) => number;
    readonly fill: (column: number, row: number, width: number, height: number, style?: CanvasStyle) => void;
    /** A canvas for a part of this one, cut to this one. */
    readonly region: (column: number, row: number, width: number, height: number) => Canvas;
  }

  /** A child of a view and its rect, local to the view. */
  export interface Placement {
    readonly view: View;
    readonly rect: Rect;
  }

  /** Anything that draws. An object (`satisfies View`) or a class. */
  export interface View {
    /** The children and their rects. The core draws each child after its parent, routes its input, and guards it. */
    readonly layout?: ((size: Size) => readonly Placement[]) | undefined;
    /** Draw the view. `focused` is true when the view or a child has the focus. */
    readonly draw: (canvas: Canvas, focused: boolean) => void;
    /** True when a click or `tui.focus` can give the view the focus. The view of a pane can take it without this. */
    readonly focusable?: boolean | undefined;
    readonly focusChanged?: ((focused: boolean) => void) | undefined;
    /** The context atoms of the keymap while the view is on the focus path. */
    readonly contexts?: readonly string[] | undefined;
    /** True when the view takes the key. */
    readonly key?: ((event: KeyEvent) => boolean) | undefined;
    readonly mouse?: ((event: MouseEvent) => boolean) | undefined;
    readonly paste?: ((text: string) => boolean) | undefined;
    /** The cursor of the focused view, or `undefined` for none. */
    readonly cursor?: (() => Cursor | undefined) | undefined;
    /** The view inside this one that takes the first focus of this view. A later focus returns to the last one. */
    readonly initialFocus?: View | undefined;
    /** The type and the state that restore the view after a reload. */
    readonly snapshot?: (() => ViewSnapshot) | undefined;
  }

  /** A selection from `anchor`, where it started, to `head`, where the caret is. */
  export interface Selection<P> {
    readonly anchor: P;
    readonly head: P;
  }

  /** How a text widget looks: the cursor shape when it has the focus, and a prompt before its text. */
  export interface TextAppearance {
    readonly cursorShape?: CursorShape | undefined;
    readonly prompt?: string | undefined;
    readonly promptStyle?: string | Style | undefined;
  }

  /** A style over a range of a text widget. `wholeRows` styles each row of the range from edge to edge. */
  export interface Decoration<P> {
    readonly range: Selection<P>;
    readonly style: string | Style;
    readonly wholeRows?: boolean | undefined;
  }

  /**
   * The part of one plugin in a text widget: key contexts, an appearance, decorations, and handlers. Each setter
   * replaces only this part. A later extension wins per appearance field and per decoration style field. `dispose()`
   * and the abort of the signal of `extend` remove the part. After that, each call does nothing.
   */
  export interface TextExtension<P, E> {
    /** Add context atoms of the keymap while the widget is on the focus path. */
    setContexts: (atoms: readonly string[]) => void;
    setAppearance: (appearance: TextAppearance) => void;
    setDecorations: (decorations: readonly Decoration<P>[]) => void;
    /**
     * Take a key of the focused widget: `true` stops it. A `beforeKeymap` handler runs before the keymap. A key that it
     * takes ends a pending key sequence. A `beforeDefault` handler (the default) runs after the keymap and before the
     * editing of the widget. The newest handler of a phase runs first.
     */
    onKey: (handler: (event: KeyEvent) => boolean, phase?: "beforeDefault" | "beforeKeymap") => Disposer;
    /** Take a mouse event before the widget: `true` stops it. A handler can return `false` to only watch. */
    onMouse: (handler: (event: MouseEvent) => boolean) => Disposer;
    onPaste: (handler: (text: string) => boolean) => Disposer;
    onChange: (listener: (event: E) => void) => Disposer;
    dispose: () => void;
  }

  /** A range of UTF-16 offsets. `to` is not in the range. */
  export interface OffsetRange {
    readonly from: number;
    readonly to: number;
  }

  /** The unit of a column: graphemes, or terminal cells. */
  export type ColumnUnit = "grapheme" | "cell";

  /** The side of a boundary that a position takes: the end of what comes before it, or the start of what follows. */
  export type Bias = "before" | "after";

  /**
   * Rows of a text widget and the map between a position and a point. A column counts cells unless `unit` says
   * graphemes. A column in a grapheme or a label snaps to its start (`before`) or its end (`after`).
   */
  export interface TextCoordinates<P> {
    readonly count: number;
    /** The text of `row`, or "" for a row that does not exist. */
    text: (row: number) => string;
    /** The position at `point`: `bias` defaults to `before`. A column past the row gives the end of the row. */
    at: (point: Point, unit?: ColumnUnit, bias?: Bias) => P | undefined;
    /** The point of `position`: `bias` defaults to `after`, so a position at a soft break goes on the next row. */
    point: (position: P, unit?: ColumnUnit, bias?: Bias) => Point | undefined;
  }

  /** A view of text that plugins extend: an editor or a text view. Points are cells local to the widget. */
  export interface TextWidget<P, E> extends View {
    readonly role: string;
    /** The display rows: soft wraps make rows, and a label shows in place of its source. */
    readonly rows: TextCoordinates<P>;
    /** The rows that the widget shows. */
    readonly visibleRows: OffsetRange;
    /** A new part of the plugin that owns `signal`. */
    extend: (signal: AbortSignal) => TextExtension<P, E>;
    /**
     * The position at a cell of the widget. A column past a row gives the row end. A row outside the text gives
     * `undefined`.
     */
    hitTest: (point: Point) => P | undefined;
    /** The cell of `position` in the widget, or `undefined` when it does not show. */
    screenAt: (position: P) => Point | undefined;
    /** Scroll the least to show `position`. `false` when it cannot show. */
    ensureVisible: (position: P) => boolean;
  }

  /** A range of an editor that shows a label and edits as one unit: a long paste, or an image (one U+FFFC). */
  export type EditorSpan = OffsetRange &
    (
      | { readonly kind: "paste"; readonly label: string }
      | { readonly kind: "image"; readonly label: string; readonly media: Readonly<Media> }
    );

  /** The draft of an editor: its text, its selection, and its spans. */
  export interface EditorState {
    readonly text: string;
    readonly selection: Selection<number>;
    readonly spans: readonly EditorSpan[];
  }

  /** One effective edit: `from` and `to` in the text before it, the inserted text, and its spans from 0. */
  export interface TextEdit extends OffsetRange {
    readonly text: string;
    readonly spans: readonly EditorSpan[];
  }

  /**
   * A change of an editor. `reset` puts a new draft, `restore` puts a saved state back, and `selection` moves only the
   * selection. `changes` holds the edits of an `edit`.
   */
  export interface EditorChange {
    readonly kind: "edit" | "reset" | "restore" | "selection";
    readonly before: EditorState;
    readonly after: EditorState;
    readonly changes: readonly TextEdit[];
  }

  export interface EditorOptions {
    /** The default role is `field`. The role is a context atom of the keymap while the editor has the focus. */
    readonly role?: "composer" | "field" | undefined;
    /** The group of related widgets, such as a composer and its transcript. The default is a new group. */
    readonly group?: object | undefined;
    /** The default is true. A one-line editor writes each line end as a space. */
    readonly multiline?: boolean | undefined;
    /** Show one `•` for each grapheme and each span, as for a password. The state keeps the text. */
    readonly mask?: boolean | undefined;
    readonly state?: EditorState | undefined;
    /** The text that an empty editor shows. */
    readonly placeholder?: string | undefined;
    readonly appearance?: TextAppearance | undefined;
    /** Get the state at Enter. The editor keeps the draft, so the owner resets it when it wants an empty editor. */
    readonly submit?: ((state: EditorState) => void) | undefined;
  }

  /**
   * An editor of text with spans. Offsets are UTF-16 units. An edit keeps whole graphemes and whole spans. The editor
   * types text and handles backspace, delete, the arrows, home, and end. Shift with a move extends the selection.
   * Enter calls the `submit` option when it exists. In a multiline editor, shift+enter, alt+enter, and ctrl+j add a
   * line end.
   */
  export class TextEditor implements TextWidget<number, EditorChange> {
    constructor(options?: EditorOptions);
    readonly kind: "editor";
    readonly role: string;
    readonly focusable: true;
    readonly state: EditorState;
    /** The logical lines, split at the line ends. */
    readonly lines: TextCoordinates<number>;
    readonly rows: TextCoordinates<number>;
    readonly visibleRows: OffsetRange;
    readonly contexts: readonly string[];
    /** The selection head. A set collapses the selection. */
    caret: number;
    selection: Selection<number>;
    /**
     * Replace `from` to `to` with `text`. A range grows to whole graphemes and spans, and an insertion goes to the
     * nearest boundary (a tie goes after). The caret goes to the next whole boundary after `text`. Span offsets start
     * at 0 in `text`.
     */
    replace(from: number, to: number, text: string, spans?: readonly EditorSpan[]): void;
    /** Put a new draft. */
    reset(state: EditorState): void;
    /** Put a saved state back, as an undo does. */
    restore(state: EditorState): void;
    /** The count of rows of the text at `width` cells, with the prompt. A width of 0 gives 0. */
    heightFor(width: number): number;
    /** Give the state to the `submit` option. Without the option, do nothing. */
    submit(): void;
    extend(signal: AbortSignal): TextExtension<number, EditorChange>;
    hitTest(point: Point): number | undefined;
    screenAt(position: number): Point | undefined;
    ensureVisible(position: number): boolean;
    layout(size: Size): readonly Placement[];
    draw(canvas: Canvas, focused: boolean): void;
    cursor(): Cursor | undefined;
    key(event: KeyEvent): boolean;
    mouse(event: MouseEvent): boolean;
    paste(text: string): boolean;
  }

  /** A place in a text document: an offset in the text of one section of one item. */
  export interface TextPosition {
    readonly item: string;
    readonly section: string;
    readonly offset: number;
  }

  export interface TextRange {
    readonly from: TextPosition;
    readonly to: TextPosition;
  }

  /**
   * A part of an item, such as a reply, a tool title, or a tool output. `render` gives its rows at a width, and the
   * offsets of their sources index `text`. Without `render`, the text wraps plainly. A render with no rows hides it.
   */
  export interface TextSection {
    readonly key: string;
    /** A `label` is a title line, such as the header of a tool. */
    readonly kind: "text" | "label";
    readonly text: string;
    readonly stops?: readonly number[] | undefined;
    readonly render?: ((width: number) => readonly TextRow[]) | undefined;
  }

  /** One entry of a document, such as a message. Its section keys are unique in the item. */
  export interface TextItem {
    readonly key: string;
    readonly sections: readonly TextSection[];
  }

  /** The content of a text view. Its item keys are unique, and a changed item is a new object. */
  export interface TextDocument {
    readonly key: string;
    readonly items: readonly TextItem[];
  }

  /** A change of a text view. `revision` grows by one with each change. */
  export interface TextViewChange {
    readonly kind: "document" | "layout" | "scroll" | "selection";
    readonly revision: number;
  }

  /** The scroll state and moves of a text view. The content changes only through `setDocument`. */
  export interface ScrollControl {
    readonly state: ScrollState;
    scrollBy: (rows: number) => void;
    scrollTo: (row: number) => void;
    followTail: () => void;
    scrollToItem: (key: string, row?: number) => boolean;
    ensureVisible: (key: string, row?: number) => boolean;
    onChange: (listener: (state: ScrollState) => void, signal: AbortSignal) => Disposer;
  }

  export interface TextViewOptions {
    readonly document: TextDocument;
    /** The default role is `text`. */
    readonly role?: "transcript" | "text" | undefined;
    readonly group?: object | undefined;
    /** The cursor shape of the caret. A text view draws no prompt. */
    readonly appearance?: TextAppearance | undefined;
    /** Copy a mouse selection when the button goes up. The default is true. */
    readonly copyOnRelease?: boolean | undefined;
    /** Act on a click without a drag, and on `activate`. `link` is the target of the segment at the position. */
    readonly activate?: ((position: TextPosition, link: string | undefined) => void) | undefined;
    readonly followTail?: boolean | undefined;
    readonly requestOlder?: (() => void | Promise<void>) | undefined;
  }

  /**
   * A read-only view of a document of items and sections, on a scroll list. A position stays on its section when other
   * items change. A drag selects. When `copyOnRelease` is true (the default), the release copies the selection. The
   * view has no default keys.
   */
  export class TextView implements TextWidget<TextPosition, TextViewChange> {
    constructor(options: TextViewOptions);
    readonly kind: "textView";
    readonly role: string;
    readonly focusable: true;
    readonly document: TextDocument;
    readonly revision: number;
    readonly scroll: ScrollControl;
    readonly rows: TextCoordinates<TextPosition>;
    readonly visibleRows: OffsetRange;
    readonly contexts: readonly string[];
    caret: TextPosition | undefined;
    selection: Selection<TextPosition> | undefined;
    /** Replace the document. With the same document key, a caret or selection end stays while its position is valid. */
    setDocument(document: TextDocument): void;
    /** Negative when `first` comes before `second` in the document, 0 when they are equal, else positive. */
    compare(first: TextPosition, second: TextPosition): number;
    /** The text of `range`: its display copy (the default), or the source text of its sections. */
    text(range: TextRange, format?: "display" | "source"): string;
    /** Call the `activate` option with `position` and the link of its segment. Return `false` without the option. */
    activate(position: TextPosition): boolean;
    extend(signal: AbortSignal): TextExtension<TextPosition, TextViewChange>;
    hitTest(point: Point): TextPosition | undefined;
    screenAt(position: TextPosition): Point | undefined;
    ensureVisible(position: TextPosition): boolean;
    layout(size: Size): readonly Placement[];
    draw(canvas: Canvas, focused: boolean): void;
    cursor(): Cursor | undefined;
    key(event: KeyEvent): boolean;
    mouse(event: MouseEvent): boolean;
    paste(text: string): boolean;
  }

  /** A placed text widget. `signal` aborts when the widget leaves the tree. */
  export interface WidgetMount {
    readonly widget: TextEditor | TextView;
    readonly pane: Pane | undefined;
    readonly group: object;
    readonly signal: AbortSignal;
  }

  /** The placed text widgets of all plugins. */
  export interface WidgetRegistry {
    readonly list: () => readonly WidgetMount[];
    /** Give `attach` the current mounts, then each new mount. Run a cleanup when its mount leaves or the watch ends. */
    readonly watch: (attach: (mount: WidgetMount) => Disposer | undefined) => Disposer;
  }

  /**
   * The source of a segment. A `text` mapping has one source unit for each shown unit, so an offset in the segment
   * maps to `from` plus that offset. A `replacement` stands for its whole source range, such as a list mark for "- ".
   */
  export interface SourceMapping extends OffsetRange {
    readonly kind: "text" | "replacement";
  }

  /** A styled piece of a row. A segment with `copy: false`, such as alignment padding, stays out of a copy. */
  export interface Segment {
    readonly text: string;
    readonly style?: string | Style | undefined;
    /** The source of the segment. A layout segment, such as the indent of a wrapped list item, has none. */
    readonly source?: SourceMapping | undefined;
    /** The target of the link that the segment belongs to. */
    readonly link?: string | undefined;
    readonly copy?: boolean | undefined;
  }

  /** One row of rendered text. */
  export interface TextRow {
    readonly segments: readonly Segment[];
    /** The text after this row in a copy: "\n" after a line, " " after a wrap at a space, "" in a split word. */
    readonly join: string;
  }

  /** The kind and the source range of one Markdown block. A code block has its fence language, or "". */
  export type MarkdownBlock = OffsetRange &
    (
      | { readonly kind: "code"; readonly language: string }
      | { readonly kind: "heading" | "paragraph" | "quote" | "rule" | "list" | "table" }
    );

  /**
   * A Markdown text as styled rows. `setText` and `append` parse again only the last two blocks when the text grows.
   * The style groups are `markdown.*`. Each source offset indexes `source()`. Calls share cached rows, so do not change
   * them.
   */
  export class Markdown {
    constructor(text?: string);
    /** The source with each "\r\n" and "\r" as "\n". */
    source(): string;
    /** Replace the source. `false` when it is the same. */
    setText(text: string): boolean;
    /** Add `fragment` at the end. A "\r\n" split between two fragments is one line break. */
    append(fragment: string): void;
    /** The blocks in source order. */
    blocks(): readonly MarkdownBlock[];
    /** The rows at `width`, at most `limit`, with an empty row between two blocks. */
    rows(width: number, limit?: number): readonly TextRow[];
  }

  /** The place of a scroll list: `top` is the first shown display row. `total` counts the rows of all items. */
  export interface ScrollState {
    readonly top: number;
    readonly height: number;
    readonly total: number;
    /** The view stays at the bottom while items grow. */
    readonly following: boolean;
    /** An item below the view changed while the list did not follow the tail. */
    readonly changedBelow: boolean;
    /**
     * The item at the top and its row there. A change keeps that item at the top. When the item goes, its nearest
     * neighbor takes its place. Without rows, it is `undefined`.
     */
    readonly anchor: { readonly key: string; readonly row: number } | undefined;
  }

  export interface ScrollListOptions<T extends object> {
    readonly items?: readonly T[] | undefined;
    /** A key that stays the same for one item across updates. Two items cannot share one key. */
    readonly key: (item: T) => string;
    /** Give the rows of `item` at `width` cells. The list keeps them while the item object and the width stay. */
    readonly render: (item: T, width: number) => readonly TextRow[];
    /** The default is false. */
    readonly followTail?: boolean | undefined;
    /**
     * Load older items when the view shows the top. The list calls it once for each visit of the top or update of the
     * items there, and not again while a call runs. Return a promise to hold the next call until the load ends.
     */
    readonly requestOlder?: (() => void | Promise<void>) | undefined;
  }

  /**
   * Items as rows that scroll by display rows. The list paints only the shown rows. The top item and its row stay
   * across a prepend, an update, and a resize. The wheel scrolls; the owner binds the keys.
   */
  export class ScrollList<T extends object> implements View {
    constructor(options: ScrollListOptions<T>);
    readonly items: readonly T[];
    readonly state: ScrollState;
    /** Replace the items. An item object that stays keeps its rows, so give a new object for a changed item. */
    setItems(items: readonly T[]): void;
    scrollBy(rows: number): void;
    scrollTo(row: number): void;
    /** Go to the bottom and follow the tail. */
    followTail(): void;
    /** Put row `row` of the item `key` at the top, as far as the rows below allow. `false` without that row. */
    scrollToItem(key: string, row?: number): boolean;
    /** Scroll the least to show row `row` of the item `key`. `false` when it cannot show. */
    ensureVisible(key: string, row?: number): boolean;
    /**
     * The item at absolute display row `row`, counted from the start of the list.
     * The result has the item-local row index and its text.
     * Return `undefined` when `row` is not a display row.
     */
    rowAt(row: number): { readonly item: T; readonly row: number; readonly text: TextRow } | undefined;
    /**
     * The first absolute display row and the rows of the item `key`.
     * Return `undefined` when the key is absent.
     */
    rowsOf(key: string): { readonly start: number; readonly rows: readonly TextRow[] } | undefined;
    /** Give each later state to `listener`, until `signal` aborts or the disposer runs. */
    onChange(listener: (state: ScrollState) => void, signal: AbortSignal): Disposer;
    layout(size: Size): readonly Placement[];
    draw(canvas: Canvas, focused: boolean): void;
    mouse(event: MouseEvent): boolean;
  }

  /** A fuzzy match: a higher score is a better match, and `ranges` mark the matched letters of the text. */
  export interface FuzzyMatch {
    readonly score: number;
    readonly ranges: readonly OffsetRange[];
  }

  /**
   * The fuzzy match of `query` in `text`, or `undefined` when the letters of `query` do not appear in order. The match
   * ignores case. Consecutive letters and the starts of words score higher. Each range covers whole graphemes. The
   * score values can change between versions; only their order counts.
   */
  export function fuzzyMatch(query: string, text: string): FuzzyMatch | undefined;

  /** A ranked item, with the ranges of its label to mark. */
  export interface PickerMatch<T> {
    readonly item: T;
    readonly ranges?: readonly OffsetRange[] | undefined;
  }

  export interface PickerOptions<T extends object> {
    readonly items: readonly T[];
    /** A key that stays the same for one item. The selection follows it. */
    readonly key: (item: T) => string;
    readonly label: (item: T) => string;
    /** The picker shows this dim text after the label. The default rank does not match it. */
    readonly detail?: ((item: T) => string) | undefined;
    /**
     * The shown items for a query, in their final order. The picker does not sort them again. The default matches
     * each label with `fuzzyMatch`: the best score first, ties in input order, and all items for an empty query.
     */
    readonly rank?: ((query: string, items: readonly T[]) => readonly PickerMatch<T>[]) | undefined;
    /**
     * The rows of a match. The default shows the label with its ranges marked, then the detail. It reverses a selected
     * row.
     */
    readonly render?: ((match: PickerMatch<T>, width: number, selected: boolean) => readonly TextRow[]) | undefined;
    /** Enter chooses the selected item. A left press on a result selects it and chooses it. */
    readonly choose: (item: T) => void;
    /** Esc cancels. The owner closes the picker. */
    readonly cancel: () => void;
  }

  /**
   * A search field over a list of ranked items. Up and Down move the selection and stop at the ends. Enter chooses,
   * and Esc cancels. The picker opens no overlay of its own.
   */
  export class Picker<T extends object> implements View {
    constructor(options: PickerOptions<T>);
    readonly input: TextEditor;
    readonly selected: T | undefined;
    /** The picker takes the focus and gives it to its search field. */
    readonly focusable: boolean;
    readonly initialFocus: View;
    query: string;
    setItems(items: readonly T[]): void;
    move(rows: number): void;
    /** `false` without a selected item. */
    choose(): boolean;
    cancel(): void;
    layout(size: Size): readonly Placement[];
    draw(canvas: Canvas, focused: boolean): void;
    key(event: KeyEvent): boolean;
    mouse(event: MouseEvent): boolean;
  }

  /** A change of `tui.focused`. `pane` is the pane that holds `current`, or `undefined` outside the panes. */
  export interface FocusChange {
    readonly previous: View | undefined;
    readonly current: View | undefined;
    readonly pane: Pane | undefined;
  }

  /** An image of the clipboard as PNG. */
  export interface ClipboardImage {
    readonly bytes: Uint8Array;
    readonly mime: "image/png";
  }

  /** A mounted view. `close()` runs once by any path, and `signal` aborts at the close. */
  export interface Mount {
    readonly close: () => void;
    readonly signal: AbortSignal;
  }

  /** Make the view of a new mount. A throw closes the mount and gives one fault. */
  export type ViewFactory = (mount: Mount) => View;

  /**
   * Why the core opens a pane. `start` is the first pane of a start without saved panes. `new` is a split, the pane
   * after a close of the last pane, or a saved empty pane of a restore.
   */
  export type PaneReason = "start" | "new";

  /** Make the view of a pane that the core opens. A throw closes the mount, gives one fault, and leaves the pane empty. */
  export type DefaultPane = (mount: Mount, reason: PaneReason) => View;

  export interface Pane extends Mount {
    readonly view: View;
    readonly focus: () => void;
  }

  /** The pane tree of the core. */
  export interface Panes {
    /** The view of the tree, for a root layout. */
    readonly view: View;
    /** The active pane beneath any modal. */
    readonly active: Pane | undefined;
    /** Split the active pane. The new pane gets the focus. The close of the last pane gives a new default pane. */
    readonly split: (create: ViewFactory, options?: { readonly direction?: Direction | undefined }) => Pane;
    /**
     * Make the view of each pane that the core opens. `PaneReason` names the cases. One plugin at a time sets it, and
     * a second set throws a `TypeError`. Without it, such a pane is empty.
     */
    readonly setDefault: (create: DefaultPane) => Disposer;
    readonly focus: (direction: FocusDirection) => boolean;
    readonly focusNext: () => void;
  }

  export interface OverlayOptions {
    /** Default true: a modal takes the focus and all input below it. A float takes only what it handles. */
    readonly modal?: boolean | undefined;
    /** The rect of the overlay. Default: the full screen. */
    readonly place?: ((size: Size) => Rect) | undefined;
  }

  /** The size of a child of `stack`: cells, a share of the rest, or cells from the size of the stack. */
  export type StackSize = number | "fill" | ((size: Size) => number);

  export interface StackChild {
    readonly view: View;
    readonly size: StackSize;
  }

  /** A JSON value. */
  export type JsonValue =
    | null
    | boolean
    | number
    | string
    | readonly JsonValue[]
    | { readonly [key: string]: JsonValue };

  export interface ViewSnapshot {
    /** A view type of `tui.views.register`. */
    readonly type: string;
    readonly state: JsonValue;
  }

  /** Make a view from its saved state. The state can come from an older version of the plugin. */
  export type RestoreView = (state: unknown, mount: Mount) => View;

  /**
   * How the terminal interface started.
   * A reload keeps the folder and the session.
   */
  export interface Startup {
    /** The folder that yuke started in. */
    readonly cwd: string;
    /** The session of `--continue` or `--session`. The start pane shows it. A restored pane keeps its saved session. */
    readonly session?: SessionId | undefined;
  }

  /** The surface of one plugin: `ctx.get("tui")`. Each registration and mount belongs to the plugin. */
  export interface Tui extends Size {
    readonly background: "dark" | "light";
    readonly truecolor: boolean;
    readonly startup: Startup;
    readonly panes: Panes;
    /** The deepest view on the focus path. */
    readonly focused: View | undefined;
    readonly focus: (view: View) => boolean;
    /** Give each later change of `focused` to `listener`. */
    readonly onFocus: (listener: (change: FocusChange) => void) => Disposer;
    /** Set the root view. Its close gives the default root back: the pane tree alone. */
    readonly setRoot: (create: ViewFactory) => Mount;
    readonly overlay: (create: ViewFactory, options?: OverlayOptions) => Mount;
    /**
     * Open the command palette: the enabled commands in a modal picker. A choice closes it, gives the focus back, and
     * then runs the command. Esc closes it and calls `cancel`.
     */
    readonly palette: (options?: { readonly cancel?: (() => void) | undefined }) => Mount;
    readonly commands: {
      readonly add: (command: Command) => Disposer;
      /** Run a command. `false` when it is missing or disabled, else `true`, also when the run fails later. */
      readonly run: (name: string, args?: unknown) => boolean;
      readonly list: () => readonly CommandItem[];
    };
    readonly keys: {
      readonly bind: (spec: string, command: string, options?: { readonly in?: string | undefined }) => Disposer;
      /** The keys of the pending sequence, such as `ctrl+k`, or "". */
      readonly pending: () => string;
      readonly keysOf: (name: string) => readonly string[];
    };
    readonly styles: {
      readonly set: (name: string, patch: StylePatch) => Disposer;
    };
    readonly notices: {
      readonly list: () => readonly Notice[];
      readonly on: (listener: (notice: Notice) => void) => Disposer;
    };
    readonly widgets: WidgetRegistry;
    readonly views: {
      readonly register: (type: string, restore: RestoreView) => Disposer;
    };
    /** Ask for a frame in `delay` milliseconds. Many asks give one frame. Ask after a state change outside the input. */
    readonly requestFrame: (delay?: number) => void;
    /** Send `text` to the clipboard of the terminal. */
    readonly copy: (text: string) => void;
    /**
     * The image of the system clipboard as PNG, or `undefined` when it holds no image, as for text only. It reads a PNG
     * image, and on macOS also a TIFF image. It needs a display. On Linux, a display that does not answer also gives
     * `undefined`. The promise rejects when the read fails or when the PNG is over 3,932,160 bytes.
     */
    readonly readImage: () => Promise<ClipboardImage | undefined>;
  }

  /** A layout of children in a row or a column. Sized children take their cells in order; `fill` shares the rest. */
  export function stack(direction: Direction, children: readonly StackChild[]): View;

  /** The cells of `text`. */
  export function measure(text: string): number;
  /** The UTF-16 offset, the UTF-16 length, and the cells of each grapheme of `text`, three numbers each. */
  export function graphemes(text: string): Int32Array;
  /** The UTF-16 length of the longest grapheme prefix of `text` that fits in `cells`. */
  export function fit(text: string, cells: number): number;
  /**
   * The rows of `text` at `width` cells, as `[start, end, soft]` triples. A line end ends a row (soft 0). A soft break
   * (soft 1) comes after the last space when the text from that space fits, else before the grapheme that does not
   * fit. With `head`, only the first `head` rows stay.
   */
  export function wrap(text: string, width: number, head?: number): Int32Array;
  /**
   * The strokes of the key spec `spec`, in the form that `strokeOf` gives. White space separates the strokes. A stroke
   * is `ctrl+alt+super+shift+key`: a named key in lower case (`enter`, `esc`, `space`, `page_down`, `f5`), or one
   * character. A character keeps its case, and shift without ctrl, alt, or super folds into it: `shift+g` is `G`. A
   * shifted symbol is its own character: write `!`, not `shift+1`. With ctrl, alt, or super, the character is lower
   * case and shift drops: `ctrl+shift+a` is `ctrl+a`. A spec that names no key throws a `TypeError`.
   */
  export function parseKeys(spec: string): readonly string[];
  /** The stroke of `event`, as `parseKeys` writes it, or "" for a key that no spec names, such as one with hyper. */
  export function strokeOf(event: KeyEvent): string;
}
