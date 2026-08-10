// Client script modules and onEvent. Keep in sync with *.js, host.odin, js.odin.
// yuke:fs: src/js/types.d.ts
/// <reference path="../js/types.d.ts" />

declare module "yuke:term" {
  export interface Style {
    fg?: string | number;
    bg?: string | number;
    bold?: boolean;
    dim?: boolean;
    italic?: boolean;
    underline?: boolean;
  }

  export interface Size {
    w: number;
    h: number;
  }

  export type KeyCode =
    | "char"
    | "unknown"
    | "text"
    | "up"
    | "down"
    | "left"
    | "right"
    | "home"
    | "end"
    | "insert"
    | "delete"
    | "page_up"
    | "page_down"
    | "enter"
    | "tab"
    | "backspace"
    | "esc"
    | "menu"
    | "f1"
    | "f2"
    | "f3"
    | "f4"
    | "f5"
    | "f6"
    | "f7"
    | "f8"
    | "f9"
    | "f10"
    | "f11"
    | "f12";

  export type KeyEventKind = "press" | "repeat" | "release";

  export type MouseEventKind = "press" | "release" | "move";
  export type MouseButton =
    | "none"
    | "left"
    | "middle"
    | "right"
    | "wheel_up"
    | "wheel_down"
    | "wheel_left"
    | "wheel_right";

  export interface StartEvent {
    type: "start";
  }

  export interface KeyEvent {
    type: "key";
    code: KeyCode;
    char: string;
    text: string;
    shifted: string;
    baseLayout: string;
    event: KeyEventKind;
    mods: number;
    locks: number;
  }

  export interface ResizeEvent {
    type: "resize";
    w: number;
    h: number;
  }

  export interface PasteEvent {
    type: "paste";
    len: number;
    truncated: boolean;
  }

  export interface MouseEvent {
    type: "mouse";
    x: number;
    y: number;
    event: MouseEventKind;
    button: MouseButton;
    mods: number;
  }

  export interface TickEvent {
    type: "tick";
  }

  export interface InputClosedEvent {
    type: "input_closed";
    reason: string;
  }

  export type TermEvent =
    | StartEvent
    | KeyEvent
    | ResizeEvent
    | PasteEvent
    | MouseEvent
    | TickEvent
    | InputClosedEvent;

  export interface Term {
    width: number;
    height: number;
    size(): Size;
    beginFrame(): void;
    endFrame(): void;
    fill(x: number, y: number, w: number, h: number, style?: Style): void;
    text(x: number, y: number, s: string, style?: Style): void;
    cursor(x: number, y: number, visible: boolean): void;
    setNeedsTick(enabled: boolean, periodMs?: number): void;
    quit(): void;
    keyMatches(ev: KeyEvent, cp: string, mods?: number): boolean;
  }

  export const term: Term;
  export type EventHandler = (ev: TermEvent) => void;
}

declare module "yuke:core" {
  import type { KeyEvent, MouseEvent, Style, TermEvent } from "yuke:term";

  export interface Config {
    plugins: Record<string, unknown>;
    [key: string]: unknown;
  }
  export const config: Config;

  export interface StyleGroupDef {
    fg?: string | number;
    bg?: string | number;
    bold?: boolean;
    dim?: boolean;
    italic?: boolean;
    underline?: boolean;
    link?: string;
  }

  export interface StyleApi {
    palette: Record<string, string | number>;
    groups: Record<string, StyleGroupDef>;
    resolve(name: string): Style;
    invalidate(): void;
  }
  export const style: StyleApi;

  export function fill(x: number, y: number, w: number, h: number, group: string): void;
  export function text(x: number, y: number, s: string, group: string): void;
  export function clip(s: string, max: number): string;

  export type CommandPredicateResult = boolean | [boolean, ...unknown[]];
  export type CommandPredicate =
    | null
    | string
    | ((...args: unknown[]) => CommandPredicateResult);
  export type CommandPerform = (...args: unknown[]) => void;

  export interface CommandEntry {
    predicate: CommandPredicate;
    perform: CommandPerform;
  }

  export interface CommandApi {
    map: Record<string, CommandEntry>;
    add(predicate: CommandPredicate, map: Record<string, CommandPerform>): void;
    perform(name: string, ...args: unknown[]): boolean;
  }
  export const command: CommandApi;

  export type KeymapHandler = (ev: KeyEvent) => boolean | void;
  export type KeymapBinding = string | KeymapHandler | Array<string | KeymapHandler>;

  export interface KeymapApi {
    map: Record<string, Array<string | KeymapHandler>>;
    add(bindings: Record<string, KeymapBinding>, overwrite?: boolean): void;
    onKey(ev: KeyEvent): boolean;
  }
  export const keymap: KeymapApi;

  export function strokeOf(ev: KeyEvent): string;

  export interface Rect {
    x: number;
    y: number;
    w: number;
    h: number;
  }

  export interface TickRequest {
    periodMs: number;
  }

  export interface CursorRequest {
    x: number;
    y: number;
    visible: boolean;
  }

  export interface Layer {
    modal?: boolean;
    name?: string;
    update?(): void;
    draw(): void;
    onKey?(ev: KeyEvent): boolean;
    onMouse?(ev: MouseEvent): boolean;
    tick?(): void;
    needsTick?(): TickRequest | null;
    cursor?(): CursorRequest | null;
  }

  export class View implements Layer {
    rect: Rect;
    constructor();
    get name(): string;
    update(): void;
    draw(): void;
    onKey(ev: KeyEvent): boolean;
    onMouse(ev: MouseEvent): boolean;
    tick(): void;
    needsTick(): TickRequest | null;
    cursor(): CursorRequest | null;
  }

  export class RootView {
    active: View | null;
    overlays: Layer[];
    constructor();
    setActive(view: View | null): void;
    get focused(): Layer | null;
    pushOverlay(layer: Layer): Layer;
    popOverlay(layer?: Layer): void;
    invalidate(): void;
    draw(): void;
    syncTick(): void;
    tickLayers(): void;
    onEvent(ev: TermEvent): void;
  }

  export const root: RootView;
  export function quit(): void;
}

declare module "yuke:ui" {
  import type { KeyEvent, MouseEvent } from "yuke:term";
  import type { CursorRequest, Layer, Rect, TickRequest } from "yuke:core";

  export interface ListCell {
    text: string;
    right?: string;
    group?: string;
    selGroup?: string;
    rightGroup?: string;
    rightSelGroup?: string;
  }

  export type ListFormatResult = string | ListCell;

  export interface ListOptions<T = unknown> {
    items?: T[];
    format?: (item: T, index: number) => ListFormatResult;
    key?: (item: T) => unknown;
    isSelectable?: (item: T) => boolean;
    onMove?: (item: T, index: number) => void;
    group?: string;
    selGroup?: string;
    dimGroup?: string;
    dimSelGroup?: string;
  }

  export class List<T = unknown> {
    format: (item: T, index: number) => ListFormatResult;
    key: (item: T) => unknown;
    isSelectable: (item: T) => boolean;
    onMove: ((item: T, index: number) => void) | null;
    group: string;
    selGroup: string;
    dimGroup: string;
    dimSelGroup: string;
    items: T[];
    selectedKey: unknown;
    scroll: number;
    constructor(opts?: ListOptions<T>);
    setItems(items: T[]): void;
    selected(): T | null;
    selectedIndex(): number;
    ensureVisible(h: number): void;
    move(delta: number): void;
    moveToEdge(dir: number): void;
    onKey(ev: KeyEvent): boolean;
    draw(rect: Rect): void;
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

  export const borders: {
    single: BorderSet;
    rounded: BorderSet;
    double: BorderSet;
    [name: string]: BorderSet;
  };

  export type BorderSpec = "single" | "rounded" | "double" | BorderSet | "none" | null;
  export type DimSpec = number | ((max: number) => number);
  export type LabelSpec = string | (() => string);
  export type LabelPos = "left" | "center" | "right";

  export interface WindowContent {
    draw?(win: Window): void;
    onKey?(ev: KeyEvent): boolean;
    onMouse?(ev: MouseEvent): boolean;
    needsTick?(): TickRequest | null;
    tick?(): void;
    cursor?(win: Window): CursorRequest | null;
  }

  export interface WindowOptions {
    name?: string;
    title?: LabelSpec;
    footer?: LabelSpec;
    title_pos?: LabelPos;
    footer_pos?: LabelPos;
    border?: BorderSpec;
    width?: DimSpec;
    height?: DimSpec;
    modal?: boolean;
    content?: WindowContent | null;
    panelGroup?: string;
    borderGroup?: string;
    titleGroup?: string;
    footerGroup?: string;
  }

  export class Window implements Layer {
    opts: WindowOptions;
    modal: boolean;
    border: BorderSpec;
    content: WindowContent | null;
    rect: Rect;
    inner: Rect;
    constructor(opts?: WindowOptions);
    get name(): string;
    update(): void;
    winText(lx: number, ly: number, s: string, group: string): void;
    winFill(lx: number, ly: number, fw: number, fh: number, group: string): void;
    draw(): void;
    drawContent(win: Window): void;
    cursor(): CursorRequest | null;
    onKey(ev: KeyEvent): boolean;
    onMouse(ev: MouseEvent): boolean;
    needsTick(): TickRequest | null;
    tick(): void;
  }

  export type PickerAction = "accept" | "cancel" | "close" | "next" | "prev" | "top" | "bottom";
  export type PickerKeymapBinding =
    | false
    | PickerAction
    | string
    | ((ev: KeyEvent, content: PickerContent) => void);

  export interface PickerOptions<T = unknown> extends ListOptions<T>, WindowOptions {
    itemGroup?: string;
    onAccept?: (item: T, index: number) => void;
    onCancel?: () => void;
    validate?: (item: T) => boolean;
    keymap?: Record<string, PickerKeymapBinding>;
    needsTick?: TickRequest | null;
    closeOnAccept?: boolean;
  }

  export class PickerContent<T = unknown> implements WindowContent {
    opts: PickerOptions<T>;
    win: Window | null;
    list: List<T>;
    onAccept: ((item: T, index: number) => void) | null;
    onCancel: (() => void) | null;
    validate: ((item: T) => boolean) | null;
    keymap: Record<string, PickerKeymapBinding> | null;
    closeOnAccept: boolean;
    constructor(items: T[], opts: PickerOptions<T>);
    setItems(items: T[]): void;
    selected(): T | null;
    draw(win: Window): void;
    needsTick(): TickRequest | null;
    cursor(): CursorRequest | null;
    close(): void;
    accept(): void;
    cancel(): void;
    action(name: PickerAction | string): void;
    onKey(ev: KeyEvent): boolean;
  }

  export interface SelectResult<T = unknown> {
    win: Window;
    content: PickerContent<T>;
    close(): void;
  }

  export interface UiApi {
    select<T = unknown>(items: T[], opts?: PickerOptions<T>): SelectResult<T>;
  }

  export const ui: UiApi;
}

declare module "yuke:defaults" {
  import type { TickRequest, View } from "yuke:core";

  export class HomeView extends View {
    get name(): "home";
    tick(): void;
    needsTick(): TickRequest | null;
    draw(): void;
  }

  export class ShellView extends View {
    get name(): "shell";
    draw(): void;
  }

  export const home: HomeView;
  export const shell: ShellView;
}

declare var onEvent: import("yuke:term").EventHandler | undefined;
