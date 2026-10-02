import type { Picker } from "../ui.js";
import type { HostMouseEvent, NavTarget, Rect } from "./core.js";

export type ItemKey = string | number;
export type PickerAction = "accept" | "cancel" | "close" | "next" | "prev" | "top" | "bottom";
export type ListKey = string | number | object;

export interface ListItem {
  text?: string;
  group?: string;
  lines?: ListItem[];
  detail?: string;
  detailGroup?: string;
  detailSelGroup?: string;
  right?: string;
  rightGroup?: string;
  rightSelGroup?: string;
  marker?: string;
  markerGroup?: string;
  markerSelGroup?: string;
  indent?: number;
  selGroup?: string;
}

/** A collapsed paste whose position gives its label and number, so a delete renumbers the rest. */
export interface PasteSpan {
  start: number;
  end: number;
}

/** An attached image whose position gives its label and number, so a delete renumbers the rest. */
export interface ImageSpan {
  start: number;
  end: number;
  blob: Wire.MediaBlob;
}

export type ComposerSpan = PasteSpan | ImageSpan;

/** Hold the buffer and its spans, so a failed send puts the images back with the text. */
export interface ComposerSnapshot {
  text: string;
  spans: ComposerSpan[];
}

export interface ProjectionPart {
  span: ComposerSpan;
  start: number;
  end: number;
  delta: number;
}

export interface Projection {
  text: string;
  parts: ProjectionPart[];
}

export interface WrapRow {
  start: number;
  end: number;
  soft: boolean;
}

/** The options of a `Composer`. */
export interface ComposerOptions {
  /** The dim text that shows while the buffer is empty. */
  placeholder?: string;
  /** Gets the content on enter. A result of false keeps the buffer; any other result clears it. */
  onSubmit?: (content: Wire.ContentPart[]) => boolean | void;
}

/** The glyphs of a border: the corners tl, tr, br, bl and the edges t, r, b, l. */
export interface BorderSet {
  tl: string;
  t: string;
  tr: string;
  r: string;
  br: string;
  b: string;
  bl: string;
  l: string;
}

export type Border = "none" | "single" | "rounded" | "double" | BorderSet;
export type Dimension = number | ((max: number) => number);
/** A row count, or a callback on the available rows and the content width, so the rows can follow wrapped text. */
export type ContentHeight = number | ((maxRows: number, width: number) => number);

export interface WindowContent {
  layout: (rect: Rect) => void;
  draw: (focused: boolean) => void;
  cursor?: () => { x: number; y: number; visible: boolean } | null;
  onKey?: (event: HostEvent) => boolean;
  onMouse?: (event: HostMouseEvent) => boolean;
  needsTick?: () => { periodMs: number } | null;
  tick?: () => void;
}

/** The options of a `Window`. */
export interface WindowOptions {
  /** The context atom of the window while it has the focus, for a key binding context. The default is "window". */
  name?: string;
  /** False makes a float: it takes no focus, and an event that it does not claim goes to the layers below. The default is true. */
  modal?: boolean;
  /** The default is "single". "none" draws no border and no padding. */
  border?: Border;
  /** The view inside the border. The window lays it out, draws it, and passes the keys and the clicks to it. */
  content?: WindowContent | undefined;
  /** The outer width in cells, or a function of the available width. The default is 60% of the screen, or the anchor width. */
  width?: Dimension;
  /** The outer height in rows, or a function of the available rows. The default is 60% of the available rows. */
  height?: Dimension;
  /** The content row count, before the border, padding, and footer; height takes precedence. */
  contentHeight?: ContentHeight;
  /** Answer a rect to sit on: the window takes its x and its width, and its bottom row is just above the rect. */
  anchor?: (() => Rect) | undefined;
  /** Place the window in `bounds`. The layout keeps it inside. It replaces the center and the anchor placement. */
  place?: ((bounds: Rect, w: number, h: number) => { x: number; y: number }) | undefined;
  /** A press outside a modal window cancels it, as esc does. `"ignore"` keeps a window that holds typed text or a running task. */
  outsidePress?: "cancel" | "ignore";
  /** The blank cells between the border and the content. The default is `{ x: 2, y: 1 }`. */
  padding?: { x: number; y: number };
  /** The highlight group of the window area. The default is "UIPanel". */
  panelGroup?: string;
  /** The default is "UIBorder". */
  borderGroup?: string;
  /** The text in the top border. A function gives it at each draw. It shows only with a border. */
  title?: string | (() => string);
  /** The default is "left". */
  title_pos?: "left" | "center" | "right";
  /** The default is "UITitle". */
  titleGroup?: string;
  /** A row under the content. A function gives it at each draw. */
  footer?: string | (() => string);
  /** The default is "left". */
  footer_pos?: "left" | "center" | "right";
  /** The default is "UIDim". */
  footerGroup?: string;
}

export interface ListOptions<T> {
  items?: T[] | undefined;
  format?: ((item: T, index: number) => string | ListItem) | undefined;
  key?: ((item: T) => ListKey) | undefined;
  isSelectable?: ((item: T) => boolean) | undefined;
  onMove?: ((item: T, index: number) => void) | undefined;
  itemHeight?: number | undefined;
  group?: string | undefined;
  selGroup?: string | undefined;
  dimGroup?: string | undefined;
  dimSelGroup?: string | undefined;
  drawCursor?: boolean | undefined;
}

/** The options of `ui.pick` and `ui.select`: the window options and the picker options. */
export type PickOptions<T> = WindowOptions & {
  /** The source items. `ui.select` sets them from its argument. */
  items?: T[];
  /** Answer the items for a query, in their final order, in place of the fuzzy rank. undefined gives no items. */
  suggest?: (query: string) => T[] | undefined;
  /** The text that the fuzzy rank matches for an item. The default is `String(item)`. */
  filterText?: (item: T) => string;
  /** The row of an item. The default is `String(item)`. */
  format?: (item: T, index: number) => string | ListItem;
  /** A stable identity for an item, so the selection follows it. The default is the item itself. */
  key?: (item: T) => ListKey;
  /** False makes a row that the selection skips. */
  isSelectable?: (item: T) => boolean;
  /** The default is "UIItem". */
  itemGroup?: string;
  /** The highlight group of the selected row. The default is "UIItemSel". */
  selGroup?: string;
  /** The screen rows for each item. The default is 1. */
  itemHeight?: number;
  /** Called when a key or a click moves the selection. */
  onMove?: (item: T, index: number) => void;
  /** Called with the selected item on enter. The window closes first, unless `closeOnAccept` is false. */
  onAccept?: (item: T, index: number) => void;
  /** Called after esc closes the window. */
  onCancel?: () => void;
  /** False keeps the picker open on enter, and `onAccept` does not run. */
  validate?: (item: T) => boolean;
  /** Strokes that run before the default keys: a `PickerAction` name, a function, or false to ignore the key. */
  keymap?: Record<string, string | false | ((event: HostEvent, content: Picker<T>) => void)> | undefined;
  /** False keeps the window open after an accept. The default is true. */
  closeOnAccept?: boolean;
  /** A redraw period while the picker shows, for rows whose `format` reads live values. */
  needsTick?: { periodMs: number };
  /** False removes the query line, as `ui.select` does. The default is true. */
  filter?: boolean;
  /** Text above the list. It wraps, and the wheel and the page keys scroll it. */
  body?: string;
  /** Fit the window to the query line and at most this many rows. */
  maxRows?: number;
};

export type NavAction = (target: NavTarget) => void;

export interface TextOptions {
  text?: string;
  group?: string;
}

export interface PromptOptions {
  placeholder?: string;
  mask?: boolean;
  settle: (value: string | undefined) => void;
}
