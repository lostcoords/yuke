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
  marker?: string | null;
  markerGroup?: string;
  markerSelGroup?: string;
  indent?: number;
  selGroup?: string;
}

export interface PasteSpan {
  start: number;
  end: number;
  label: string;
}

export interface ProjectionPart {
  span: PasteSpan;
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

export interface ComposerOptions {
  prompt?: string | undefined;
  placeholder?: string | undefined;
  onSubmit?: ((text: string) => boolean | void) | null | undefined;
  maxRows?: number | undefined;
}

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

export interface WindowContent {
  layout: (rect: Rect) => void;
  draw: (focused?: boolean) => void;
  cursor?: () => { x: number; y: number; visible: boolean } | null;
  onKey?: (event: HostEvent) => boolean;
  onMouse?: (event: HostMouseEvent) => boolean;
  needsTick?: () => { periodMs: number } | null;
  tick?: () => void;
}

export interface WindowOptions {
  name?: string;
  modal?: boolean;
  border?: Border;
  content?: WindowContent | null;
  width?: Dimension;
  height?: Dimension;
  anchor?: (() => Rect) | null;
  panelGroup?: string;
  borderGroup?: string;
  title?: string | (() => string);
  title_pos?: "left" | "center" | "right";
  titleGroup?: string;
  footer?: string | (() => string);
  footer_pos?: "left" | "center" | "right";
  footerGroup?: string;
}

export interface ListOptions<T> {
  items?: T[] | undefined;
  format?: ((item: T, index: number) => string | ListItem) | undefined;
  key?: ((item: T) => ListKey) | undefined;
  isSelectable?: ((item: T) => boolean) | undefined;
  onMove?: ((item: T, index: number) => void) | null | undefined;
  itemHeight?: number | undefined;
  group?: string | undefined;
  selGroup?: string | undefined;
  dimGroup?: string | undefined;
  dimSelGroup?: string | undefined;
  drawCursor?: boolean | undefined;
}

export type PickOptions<T> = WindowOptions & {
  items?: T[] | undefined;
  suggest?: ((query: string) => T[] | undefined) | undefined;
  filterText?: ((item: T) => string) | undefined;
  format?: ((item: T, index: number) => string | ListItem) | undefined;
  key?: ((item: T) => ListKey) | undefined;
  isSelectable?: ((item: T) => boolean) | undefined;
  itemGroup?: string | undefined;
  selGroup?: string | undefined;
  itemHeight?: number | undefined;
  onMove?: ((item: T, index: number) => void) | null | undefined;
  onAccept?: ((item: T, index: number) => void) | null | undefined;
  onCancel?: (() => void) | null | undefined;
  validate?: ((item: T) => boolean) | null | undefined;
  keymap?: Record<string, string | false | ((event: HostEvent, content: Picker<T>) => void)> | null | undefined;
  closeOnAccept?: boolean | undefined;
  needsTick?: { periodMs: number } | null | undefined;
  filter?: boolean | undefined;
  body?: string | undefined;
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
