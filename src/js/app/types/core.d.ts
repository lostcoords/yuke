import type { Node } from "../core.js";
import type { Color, Style } from "yuke:term";

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface StyleGroup {
  // A string first selects an own palette key, then a literal color.
  fg?: Color | string;
  bg?: Color | string;
  ul?: Color | string;
  link?: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  reverse?: boolean;
  underline?: boolean;
}

export interface StyleConfig {
  palette: Record<string, Color>;
  groups: Record<string, StyleGroup>;
  _refs: Record<string, number>;
  _cache: Record<string, Style>;
  add: (groups: Record<string, StyleGroup>) => () => void;
  resolve: (name: string) => Style;
  invalidate: () => void;
}

export interface NavTarget {
  navBy: (delta: number) => void;
  navPage: (direction: number) => void;
  navEdge: (direction: number) => void;
}

export type HostMouseEvent = Extract<HostEvent, { type: "mouse" }>;

export interface ViewLike {
  rect: Rect;
  layout: (rect: Rect) => void;
  draw: (focused?: boolean) => unknown;
  name?: string;
  onKey?: (event: HostEvent) => boolean;
  onMouse?: (event: HostMouseEvent) => boolean;
  onFocus?: () => void;
  contexts?: () => string[];
  navTarget?: () => NavTarget | null;
  needsTick?: () => { periodMs: number } | null;
  tick?: () => void;
  cursor?: () => { x: number; y: number; visible: boolean } | null;
  modal?: boolean;
}

export type Overlay = Omit<ViewLike, "rect"> & { rect?: Rect };

export interface Tickable {
  onStart?: () => void;
  onStop?: () => void;
  needsTick?: () => { periodMs: number } | null;
  tick?: () => void;
}

export interface TickableEntry {
  tickable: Tickable;
  refs: number;
  started: boolean;
}

export type NodeShape =
  | { type: "leaf"; view: ViewLike }
  | { type: "split"; kind: "row" | "col"; a: Node; b: Node; ratio: number };

export type CommandAction = (...args: any[]) => unknown;
export type CommandPredicate = (...args: any[]) => boolean | [boolean, ...any[]];

export interface CommandMeta {
  title: string;
  description: string;
  slash?: string | null;
  args?: boolean;
}

export interface CommandEntry {
  predicate: CommandPredicate | null;
  perform: CommandAction;
  meta: CommandMeta | null;
}

export interface CommandListing {
  name: string;
  title: string;
  description: string;
  slash: string | null;
  args: boolean;
}

export type CommandMap = Record<string, CommandEntry[]>;

export interface CommandRegistry {
  map: CommandMap;
  add: (predicate: string | CommandPredicate | null, map: Record<string, CommandAction>, meta?: Record<string, CommandMeta>) => () => void;
  perform: (name: string, ...args: any[]) => boolean;
  available: (name: string) => boolean;
  list: () => CommandListing[];
}

export type KeyBinding = string | ((event: HostEvent) => boolean | void);

export type ContextNode =
  | { t: "atom"; name: string }
  | { t: "eq"; name: string; value: string; neg: boolean }
  | { t: "not"; x: ContextNode }
  | { t: "and"; a: ContextNode; b: ContextNode }
  | { t: "or"; a: ContextNode; b: ContextNode };

export type ContextFlag = string | (() => string | null | undefined);

export interface ContextExpr {
  source: string;
  node: ContextNode;
  atoms: string[];
}

export type RouteWhere = "keymap" | "view";

export interface RouteEntry {
  where: RouteWhere;
  context: ContextExpr | null;
  order: number;
}

export interface SlotEntry {
  fn: (object: any, argument?: any) => unknown;
}

export interface KeyEntry {
  fn: KeyBinding;
  context: ContextExpr | null;
  order: number;
  pending: "chord" | "operator";
}

export interface Pending {
  stroke: string;
  kind: "chord" | "operator";
  at: number;
  ev: Extract<HostEvent, { type: "key" }> | null;
}

export type KeyMap = Record<string, KeyEntry[]>;

export interface KeymapRegistry {
  map: KeyMap;
  prefixes: Record<string, string[]>;
  pending: Pending | null;
  add: (bindings: Record<string, KeyBinding | KeyBinding[]>, context?: string, options?: { pending?: "chord" | "operator" }) => () => void;
  _rebuildPrefixes: () => void;
  _armKind: (prefix: string) => "chord" | "operator" | null;
  owns: () => boolean;
  onKey: (event: Extract<HostEvent, { type: "key" }>) => boolean;
  _seq: number;
  arm: (stroke: string, kind: "chord" | "operator", event?: Extract<HostEvent, { type: "key" }> | null) => void;
  pendingLabel: () => string;
  needsTick: () => { periodMs: number } | null;
  tick: () => void;
  candidates: (stroke: string) => KeyEntry[];
  describe: (stroke: string) => unknown;
  _perform: (stroke: string, event: Extract<HostEvent, { type: "key" }>) => boolean;
}

export interface StatusSegment {
  side?: "left" | "right";
  order?: number;
  render: () => string | null | undefined;
}

export interface StatusEntry {
  side: "left" | "right";
  order: number;
  render: () => string | null | undefined;
}

export type RootEvent = { type: "start" } | { type: "input_closed" } | HostEvent;
