import type { Node } from "../core.js";
import type { Color, Style } from "yuke:internal/native/term";
import type { Disposer } from "./ext.js";

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** One highlight group: the style that a draw call names. A string color first names a palette key, then a literal color. */
export interface StyleGroup {
  /** The text color. The default is the palette key "fg". */
  fg?: Color | string;
  bg?: Color | string;
  /** The underline color. */
  ul?: Color | string;
  /** The name of another group. This group takes that style, and its own fields win. A link cycle gives the default style. */
  link?: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  reverse?: boolean;
  underline?: boolean;
}

/** A change to a group: the fields to set. A field set to null removes that field from the merged group. */
export type StylePatch = { [K in keyof StyleGroup]?: StyleGroup[K] | null };

/** A set of changes: to groups, to palette colors, or both. A theme is one of these. */
export interface StyleLayer {
  groups?: Record<string, StylePatch>;
  palette?: Record<string, Color | null>;
}

/** The highlight groups and the palette. A draw call names a group, and `resolve` gives its terminal style. */
export interface StyleConfig {
  /** The merged palette: the default palette of the color depth and the background, then the theme, then each `setPalette`. Read it; change it with `setPalette` or `theme`. */
  palette: Record<string, Color>;
  /** The merged groups. Read them; change them with `set` or `theme`. */
  groups: Record<string, StyleGroup>;
  _base: Map<string, StyleGroup>;
  _patches: StyleLayer[];
  _cache: Record<string, Style>;
  /**
   * Set the default of groups that your plugin owns, below the theme and every other `set`, and return a disposer that removes them.
   * A name that has a default, core or from another plugin, throws a TypeError: change it without `{ default: true }`.
   */
  set(groups: Record<string, StyleGroup>, options: { default: true }): Disposer;
  /** Change fields of any group, and return a disposer that restores the value before. A later `set` wins. A change before the default applies when the default appears. */
  set(groups: Record<string, StylePatch>, options?: { default?: false }): Disposer;
  /** Change palette colors, and return a disposer that restores the value before. */
  setPalette(colors: Record<string, Color | null>): Disposer;
  /** Make `theme` the one active theme: above the defaults and below every other `set`. A new call replaces it. The disposer removes it, if it is still active. */
  theme(theme: StyleLayer): Disposer;
  _layer(layer: StyleLayer): Disposer;
  _apply(layer: StyleLayer): void;
  _group(name: string): void;
  _changed(): void;
  _build(name: string): Style;
  /** The terminal style of a group after its links. An unknown group gets the default text color. Each change repaints, so the result is always current. */
  resolve(name: string): Style;
}

export interface NavTarget {
  navBy: (delta: number) => void;
  navPage: (direction: number) => void;
  navEdge: (direction: number) => void;
}

export type HostMouseEvent = Extract<HostEvent, { type: "mouse" }>;

/** A view that a pane or an overlay can show. The root calls `layout` and then `draw`. Each other hook is optional. */
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

/**
 * A layer above the panes, such as a `Window`. The root lays it out over the whole screen.
 * A layer with `modal: false` is a float: it takes no focus, and an event that it does not claim goes to the layers below.
 * Every other layer is modal: it takes every key and click that reaches it, except a key of an `aboveModal` command.
 */
export type Overlay = Omit<ViewLike, "rect"> & { rect?: Rect };

/** A member of the frame loop without a view. `needsTick` answers its period, or null when it needs no tick now. */
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

/** One command. `desc` lists it in the palette; `slash: true` answers `/<name after the owner prefix>`, and a string names another word. */
export interface CommandSpec {
  /** The action. It gets the arguments of `perform`: a key binding passes the key event. */
  run: CommandAction;
  /**
   * The command runs, and lists, only while this answers true. It gets the same arguments as `run`.
   * A result `[true, ...args]` gives `run` those arguments. While it answers false, an older command of the same name can run.
   */
  when?: CommandPredicate | null;
  /** The text that the palette and the slash menu show. A command without it does not show in a listing. */
  desc?: string;
  /** A slash word needs `desc`, else `add` throws a TypeError. */
  slash?: boolean | string;
  /** The slash word takes the rest of the line as its argument. */
  args?: boolean;
  /** A key bound to the command runs it even while a modal dialog is open. */
  aboveModal?: boolean;
}

export interface CommandEntry {
  when: CommandPredicate | null;
  run: CommandAction;
  desc: string | null;
  slash: string | null;
  args: boolean;
  aboveModal: boolean;
}

export interface CommandListing {
  name: string;
  desc: string;
  slash: string | null;
  args: boolean;
}

export type CommandMap = Record<string, CommandEntry[]>;

/** The commands by name. A key binding, the palette, and a slash word run a command through `perform`. */
export interface CommandRegistry {
  /** The entries by name, newest first. */
  map: CommandMap;
  /**
   * Register `spec` under `name` and return a disposer. A newer command of the same name runs first.
   * It throws a TypeError for an empty name, a missing `run`, a `when` that is not a function, or a slash word without `desc`.
   */
  add: (name: string, spec: CommandSpec) => () => void;
  /** Run the newest command of `name` whose `when` answers true. Answer false when no command ran. */
  perform: (name: string, ...args: any[]) => boolean;
  /** Run the entry that `perform` would run, only when that entry is marked `aboveModal`. */
  performAboveModal: (name: string, ...args: any[]) => boolean;
  /** True when a command of `name` would run now. It calls each `when` with no arguments, and a `when` that throws counts as true. */
  available: (name: string) => boolean;
  /** The commands that have `desc` and would run now, sorted by the word that the palette shows. */
  list: () => CommandListing[];
}

/**
 * A command name, which runs through `command.perform` with the key event, or a function that gets the key event.
 * A function that returns false, or a command that does not run, lets the next binding of the stroke try.
 */
export type KeyBinding = string | ((event: HostEvent) => boolean | void);

export type ContextNode =
  | { t: "atom"; name: string }
  | { t: "eq"; name: string; value: string; neg: boolean }
  | { t: "not"; x: ContextNode }
  | { t: "and"; a: ContextNode; b: ContextNode }
  | { t: "or"; a: ContextNode; b: ContextNode };

/** A flag value, or a function that reads it at each key. A result of null or undefined, or a throw, makes the flag absent. */
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

/**
 * The key bindings. A stroke is a key with optional modifiers: "enter", "G", "ctrl+s", "alt+shift+tab".
 * A modifier is "ctrl", "alt", "super", or "shift". A named key such as "esc", "up", or "page_down" is lower case.
 * A character key keeps its case, so "G" and "g" differ and "shift+g" is "G". With ctrl, alt, or super, a character is lower case.
 * For one stroke, the binding whose context names the deepest active atom wins: a focused overlay, then the active pane, then the root.
 * On a tie, the newest binding wins. A binding without a context counts as the root.
 */
export interface KeymapRegistry {
  /** The bindings by normalized stroke, newest first. */
  map: KeyMap;
  prefixes: Record<string, string[]>;
  /** The first stroke of a sequence that waits for its second stroke, or null. */
  pending: Pending | null;
  /**
   * Register `bindings` and return a disposer. A key is a stroke, or two strokes with a space between them, such as "g g".
   * A second stroke also matches without ctrl, so "ctrl+w h" also answers ctrl+w ctrl+h. An array gives several bindings, tried in order.
   * It throws an Error when `context` has bad syntax.
   * @param context - an expression over the active atoms and the flags: `overlay`, `!chat`, `mode == insert`, `a && (b || c)`.
   * An atom is "root", a view name or one of its `contexts()`, or "overlay" while an overlay has the focus. No context applies everywhere.
   * @param options - `pending` sets how a sequence waits after its first stroke. "chord", the default, runs the first stroke alone
   * after `config.keymap.chordMs`. "operator" waits for the next key with no time limit. A second stroke that completes no sequence runs alone, and the first stroke does nothing.
   */
  add: (bindings: Record<string, KeyBinding | KeyBinding[]>, context?: string, options?: { pending?: "chord" | "operator" }) => () => void;
  /** Run the stroke above an open modal when its winning binding names an `aboveModal` command. */
  performAboveModal: (ev: Extract<HostEvent, { type: "key" }>) => boolean;
  _indexPrefix: (key: string, present: boolean) => void;
  _armKind: (prefix: string) => "chord" | "operator" | null;
  /** True while a sequence waits for its second stroke. */
  owns: () => boolean;
  /** Run the bindings for one key event from the root. Answer true when a binding claimed the key or a sequence started. */
  onKey: (event: Extract<HostEvent, { type: "key" }>) => boolean;
  _seq: number;
  /** The waiting first stroke, or "" when no sequence waits. */
  pendingLabel: () => string;
  needsTick: () => { periodMs: number } | null;
  tick: () => void;
  /** The bindings of one stroke that apply now, best first. It does not normalize `stroke`. */
  candidates: (stroke: string) => KeyEntry[];
  /** For each command name, a stroke whose best binding runs that command now. A caller shows it next to the command. */
  hints: () => Record<string, string>;
  /** The binding that `stroke` runs now and the bindings that it shadows, each with its context source. `winner` is null when no binding applies. */
  describe: (stroke: string) => unknown;
  _perform: (stroke: string, event: Extract<HostEvent, { type: "key" }>) => boolean;
}

/** One status bar segment. The bar is the last row. It joins the segments of each side with " · ". */
export interface StatusSegment {
  /** The default is "left". The right side keeps its full width, and the left side clips. */
  side?: "left" | "right";
  /** The position in its side, low first. The default is 0. It must be finite. */
  order?: number;
  /** Answer the text at each draw. An empty string, null, or undefined hides the segment. A throw hides it and reports a fault. */
  render: () => string | null | undefined;
}

export interface StatusEntry {
  side: "left" | "right";
  order: number;
  render: () => string | null | undefined;
}

export type RootEvent = { type: "start" } | { type: "input_closed" } | HostEvent;
