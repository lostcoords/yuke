// Client script modules and onEvent. Keep in sync with *.js, host.odin, js.odin.
// yuke:fs, yuke:exec, yuke:diff: src/js/types.d.ts
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
    measure(s: string): number;
    // Flat [i, n, w] triples per grapheme cluster: UTF-16 offset, UTF-16 length, cell width.
    graphemes(s: string): Int32Array;
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

  export interface DaemonConfig {
    host: string;
    port: number;
    autoConnect: boolean;
    retryMs: number;
    token?: string;
  }

  export interface Config {
    plugins: Record<string, unknown>;
    daemon: DaemonConfig;
    [key: string]: unknown;
  }
  export const config: Config;

  export interface DefineConfigInput {
    daemon?: Partial<DaemonConfig>;
  }

  export function defineConfig(partial: DefineConfigInput): DefineConfigInput;

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
  export function wrap(s: string, width: number): string[];

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
    prefixes: Record<string, boolean>;
    pending: string | null;
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

  export interface Service {
    onStart?(): void;
    needsTick?(): TickRequest | null;
    tick?(): void;
  }

  // A focus target: a pane with a rect, key handling, and rect-aware drawing.
  export interface Pane {
    rect: Rect;
    name?: string;
    onKey?(ev: KeyEvent): boolean;
    draw(focused: boolean): void;
  }

  export type FocusDir = "h" | "j" | "k" | "l";

  export class Focus {
    panes: Pane[];
    current: Pane | null;
    constructor();
    add(pane: Pane): Pane;
    set(pane: Pane): void;
    cycle(step: number): void;
    dir(d: FocusDir): void;
  }

  export class RootView {
    active: View | null;
    overlays: Layer[];
    services: Service[];
    constructor();
    setActive(view: View | null): void;
    addService(svc: Service): Service;
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

declare module "yuke:client" {
  export type ConnectionState = "disconnected" | "connecting" | "ready" | "closing";

  export interface ConnectOptions {
    remote?: boolean;
    device?: string;
    host?: string;
    port?: number;
    secure?: boolean;
    token?: string;
  }

  export type ClientErrorCode =
    | "transport_failed"
    | "bad_initialize"
    | "unknown_response"
    | "decode_failed"
    | "bad_frame"
    | "out_of_memory"
    | "request_id_exhausted"
    | "too_many_pending"
    | "not_ready"
    | "connection_closed"
    | "not_enrolled"
    | "identity_unreadable"
    | "roster_failed"
    | "device_not_found"
    | "device_ambiguous"
    | "ticket_failed";

  export class ClientError extends Error {
    code: ClientErrorCode;
    constructor(code: ClientErrorCode);
  }

  export type RpcErrorCode =
    | -32603
    | -32602
    | -32601
    | -32600
    | -31000
    | -31001
    | -31002
    | -31003
    | -31004
    | -31005
    | -31006
    | -31007
    | -31008
    | -31009
    | -31010
    | -31011
    | -31012
    | -31013
    | -31014
    | -31015
    | -31016
    | -31017
    | -31018
    | -31019
    | -31020
    | -31021;

  export class RpcError extends Error {
    code: RpcErrorCode;
    constructor(code: RpcErrorCode, message: string);
  }

  export type SessionScope =
    | { type: "all" }
    | { type: "workspace"; workspace_id: string };

  export type SessionPopulation =
    | { type: "top_level" }
    | { type: "children"; parent_id: string }
    | { type: "job_runs"; job_id: string }
    | { type: "all" };

  export type SessionView = "active" | "recent" | "active_recent";

  export interface SessionListParams {
    scope?: SessionScope;
    population?: SessionPopulation;
    view?: SessionView;
    limit?: number;
    cursor?: string;
  }

  export interface ClientIdentity {
    name: string;
    version: string;
  }

  export type SessionOrigin =
    | { type: "root" }
    | {
        type: "child";
        parent_id: string;
        parent_message_id: number;
        parent_part_id: number;
      }
    | { type: "fork"; source_id: string }
    | { type: "cron"; job_id: string };

  export interface TokenUsage {
    input: number;
    output: number;
    reasoning: number;
    cache_read: number;
    cache_write: number;
  }

  export interface Session {
    id: string;
    workspace_id: string;
    profile: string;
    model: string;
    reasoning: string;
    config_rev: number;
    permission: "strict" | "normal" | "yolo";
    max_rounds: number | null;
    title: string;
    message_count: number;
    usage_total: TokenUsage;
    created_at_ms: number;
    updated_at_ms: number;
    created_by: ClientIdentity | null;
    origin: SessionOrigin;
    agent?: string;
  }

  export interface RunConfig {
    config_rev: number;
    model: string;
    reasoning: string;
  }

  export type RunErrorCode =
    | "provider"
    | "protocol"
    | "network"
    | "timeout"
    | "rate_limited"
    | "quota_exhausted"
    | "auth"
    | "unknown_model"
    | "unsupported_reasoning"
    | "max_rounds"
    | "context_overflow"
    | "runtime"
    | "internal";

  export type ActivityState =
    | { type: "idle" }
    | { type: "building"; run_id: number; started_at_ms: number }
    | { type: "running"; run_id: number; started_at_ms: number }
    | { type: "reasoning"; run_id: number; message_id: number; part_id: number }
    | {
        type: "waiting_permission";
        run_id: number;
        message_id: number;
        part_id: number;
        tool_name: string;
        requested_at_ms: number;
      }
    | {
        type: "running_tool";
        run_id: number;
        message_id: number;
        part_id: number;
        tool_name: string;
        started_at_ms: number;
      }
    | {
        type: "retrying";
        run_id: number;
        attempt: number;
        max_attempts: number;
        next_at_ms: number;
        code: RunErrorCode;
        message: string;
      }
    | {
        type: "compacting";
        run_id: number;
        reason: "auto" | "manual";
        started_at_ms: number;
      };

  export interface SessionActivity {
    state: ActivityState;
    config?: RunConfig;
    queued: number;
    context_usage: TokenUsage;
    pending_compaction: number | null;
  }

  export interface SessionListItem {
    session: Session;
    activity: SessionActivity;
  }

  export interface SessionListResult {
    revision: number;
    items: SessionListItem[];
    next_cursor: string | null;
    total: number;
  }

  export type SessionSync = "needs_resync" | "resyncing" | "synced";

  export interface TranscriptPart {
    type: "text" | "reasoning";
    text: string;
  }

  export interface TranscriptMessage {
    type: "user" | "assistant";
    id: number;
    content: TranscriptPart[];
  }

  export interface SessionSnapshot {
    sessionId: string;
    sync: SessionSync;
    rev: number;
    hasMore: boolean;
    messages: TranscriptMessage[];
    active: TranscriptMessage | null;
  }

  export function connect(options: ConnectOptions): Promise<void>;
  export function disconnect(): void;
  export function connectionState(): ConnectionState;
  export function sessionList(params?: SessionListParams): Promise<SessionListResult>;
  export function sessionOpen(id: string): void;
  export function sessionClose(): void;
  export function sessionRev(): number;
  export function sessionResync(): Promise<void>;
  export function sessionSnapshot(): SessionSnapshot | null;
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

  export interface PagerRow {
    text: string;
    group?: string;
    bg?: string;
    marker?: string | null;
    markerGroup?: string;
    indent?: number;
    key?: unknown;
  }

  export class Pager {
    rows: PagerRow[];
    scroll: number;
    stuck: boolean;
    constructor();
    atBottom(): boolean;
    toBottom(): void;
    toTop(): void;
    scrollBy(delta: number): void;
    setRows(rows: PagerRow[]): void;
    draw(rect: Rect): void;
    onKey(ev: KeyEvent): boolean;
  }

  export interface TranscriptPart {
    type: string;
    text?: string;
  }

  export interface TranscriptMessage {
    type: "user" | "assistant";
    id: string;
    rev: number;
    content: TranscriptPart[];
  }

  export class Transcript {
    messages: TranscriptMessage[];
    pager: Pager;
    constructor();
    setMessages(messages: TranscriptMessage[]): void;
    touch(): void;
    draw(rect: Rect): void;
    onKey(ev: KeyEvent): boolean;
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
  import type { KeyEvent } from "yuke:term";
  import type { Focus, Pane, Rect, Service, View } from "yuke:core";
  import type { List } from "yuke:ui";
  import type { SessionActivity } from "yuke:client";

  export interface SessionRow {
    id: string;
    title: string;
    activity: SessionActivity;
  }

  export class SessionList implements Pane {
    rect: Rect;
    list: List<SessionRow>;
    activeId: string | null;
    loaded: boolean;
    loading: boolean;
    get name(): "sessions";
    syncConnection(): void;
    refresh(): void;
    clear(): void;
    current(): SessionRow | null;
    onKey(ev: KeyEvent): boolean;
    draw(focused: boolean): void;
  }

  export class MainPane implements Pane {
    rect: Rect;
    get name(): "main";
    onKey(ev: KeyEvent): boolean;
    draw(focused: boolean): void;
  }

  export class AppView extends View {
    sidebar: SessionList;
    main: MainPane;
    focus: Focus;
    get name(): "app";
    onKey(ev: KeyEvent): boolean;
    draw(): void;
  }

  export const app: AppView;

  export function openExplorer(startPath: string): unknown;
  export function openPalette(): unknown;
  export function openCommandLine(): unknown;

  export const connection: Service & {
    nextRetryAt: number;
    attempt(): void;
    scheduleRetry(): void;
  };
}

declare var onEvent: import("yuke:term").EventHandler | undefined;
