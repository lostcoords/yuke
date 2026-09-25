import type { CancellationSignal } from "yuke:internal/native/cancellation";
import type { EngineEvent } from "yuke:internal/native/engine";
import type { Job } from "yuke:internal/native/jobs";
import type { Context, Scope } from "../ext.js";
import type { tui } from "../tui.js";
import type { ChatRegion, ChatView, PresentationContext, PresentationProvider, StripRow } from "../chat-view.js";
import type { Composer } from "../ui.js";
import type { HostMouseEvent, ViewLike } from "./core.js";

export type Disposer = () => void;
export type AdviceFunction = (...args: any[]) => any;
// Advice follows the synchronous call, not promise settlement; a throw skips after and filterReturn.
export type AdviceWhere = "before" | "after" | "around" | "filterArgs" | "filterReturn";

export interface AdviceOptions {
  owner?: string;
  name?: string;
  /** Lower order runs first; equal orders keep registration order. */
  order?: number;
}

/** An engine drain that names facts; each fact event carries the whole drain. */
export type EngineFactEvent = Exclude<EngineEvent, { type: "activity" }>;
type EngineFacts = { [K in Exclude<Wire.BroadcastName, "notice" | "auth.login_finished">]: (ev: EngineFactEvent) => void };

/**
 * Every event on the bus, as its listener signature. A fact such as `x.changed` answers nothing; a point is asked
 * with `bail`, and the newest listener that answers wins. A plugin names its own events `<plugin>:<name>`.
 */
export interface Events extends EngineFacts {
  "ext.error"(error: unknown, owner: string): void;
  "engine.drained"(ev: EngineFactEvent): void;
  /** A notice and a login outcome name no session, so they arrive only in an index drain. */
  "notice"(ev: Extract<EngineEvent, { type: "index" }>): void;
  "auth.login_finished"(ev: Extract<EngineEvent, { type: "index" }>): void;
  "engine.activity.changed"(): void;
  "jobs.changed"(job: Job): void;
  "interaction.changed"(): void;
  /** A true answer holds the quit. */
  "quit.request"(): boolean | null | undefined;
  "ui.start"(ev: { type: "start" }): void;
  "ui.closed"(ev: { type: "input_closed" }): void;
  "ui.resize"(ev: Extract<HostEvent, { type: "resize" }>): void;
  "ui.tick"(ev: Extract<HostEvent, { type: "tick" }>): void;
  "key.press"(ev: Extract<HostEvent, { type: "key" }>): void;
  "mouse.input"(ev: HostMouseEvent): void;
  "paste.input"(ev: Extract<HostEvent, { type: "paste" }>): void;
  "focus.changed"(ev: Extract<HostEvent, { type: "focus" }>): void;
  "pane.focused"(view: ViewLike): void;
  "pane.closed"(view: ViewLike): void;
  "region.focused"(view: ChatView, region: ChatRegion): void;
  "clipboard.copied"(copy: { what: string; text: string; bytes: number }): void;
  "composer.changed"(composer: Composer): void;
  "composer.attached"(composer: Composer): void;
  "model.changed"(change: { model: Wire.ModelInfo; sessionId: string | null }): void;
  "session.changed"(ev: Extract<EngineEvent, { type: "session" }>): void;
  "index.changed"(ev: Extract<EngineEvent, { type: "index" }>): void;
  "activity.changed"(sessionId: string, activity: Wire.SessionActivity | null): void;
  "session.focused"(): void;
  /** A true answer claims a left press in the chat pane. */
  "chat.press"(view: ChatView, ev: HostMouseEvent): boolean | null | undefined;
  "chat.strip"(view: ChatView): StripRow[] | null | undefined;
  "chat.presentation"(view: ChatView, context: PresentationContext): PresentationProvider | null | undefined;
  "chat.rule"(view: ChatView): StripRow | null | undefined;
  "chat.cursor"(view: ChatView): { x: number; y: number; visible: boolean } | null | undefined;
  "composer.prompt"(composer: Composer): string | null | undefined;
  "composer-vim:mode"(composer: Composer, mode: "insert" | "normal"): void;
  [name: `${string}:${string}`]: (...args: any[]) => any;
}

export type EventName = keyof Events & string;
export interface EventOptions { prepend?: boolean }

/** The shared event bus: `emit` tells every listener in registration order; `bail` asks the newest listener first and answers the first value that is not false or null. */
export interface Bus {
  on<K extends EventName>(name: K, fn: Events[K], opts?: EventOptions): Disposer;
  once<K extends EventName>(name: K, fn: Events[K]): Disposer;
  emit<K extends EventName>(name: K, ...args: Parameters<Events[K]>): void;
  bail<K extends EventName>(name: K, ...args: Parameters<Events[K]>): Exclude<ReturnType<Events[K]>, false | null | undefined | void> | undefined;
  /** Declare more names for the life of a tier; the disposer withdraws them. */
  declare(names: string[]): Disposer;
  onError: ((error: unknown, name: string) => void) | null;
}
/** A sync apply may return its cleanup; an async apply resolves to nothing. */
export type PluginApply = (context: Context) => void | (() => void) | Promise<void>;

export interface ToolContext {
  workspaceRoot: string;
  sessionId?: string;
  messageId?: number;
  partId?: number;
  /** Shows one chunk of live output while the tool runs. The model reads only the result; the stream stops at 1 MiB. */
  output(text: string): void;
}

export type ToolExecute = (
  /** The JSON the model wrote. It may be any value, so a tool checks it before use. */
  args: unknown,
  signal: CancellationSignal,
  context: ToolContext,
) => Promise<unknown>;

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: ToolExecute;
  /** Request deferred loading until a tool search names the definition. */
  defer?: boolean;
}

export interface Capabilities {
  tui: ReturnType<typeof tui.bindTo>;
  [name: string]: unknown;
}

export type InjectContext<K extends string = "tui"> = Context & Pick<Capabilities, K>;
export type InjectApply<K extends string = string> = (context: InjectContext<K>) => unknown;

export interface PluginHandle {
  /** Rejects on startup failure or cancellation. */
  readonly ready: Promise<void>;
  /** Cancels the signal and startup, reverts the registrations, awaits the releases, and frees the name; a sync close answers nothing. */
  dispose(): void | Promise<void>;
}

export interface Plugin {
  name: string;
  apply: PluginApply;
}

/** The run facts every engine hook carries. */
export interface HookContext {
  session_id: string;
  parent_id: string | null;
  depth: number;
  max_agent_depth: number;
  agent_name: string;
  workspace: string;
  has_skills: boolean;
}

/** One tool as the provider request declares it. `input_schema` is JSON Schema text. */
export interface ToolDecl {
  name: string;
  description: string;
  input_schema: string;
  defer_loading: boolean;
  strict: boolean;
}

/** One tool result as the model reads it. */
export interface ToolOutcome {
  output: string;
  is_error: boolean;
  view?: Wire.View[] | null;
  media?: Wire.MediaBlob[];
  /** The definitions a tool search loaded. The engine admits each one against the run loadout. */
  tools_added?: Wire.ToolDefinition[];
}

export interface PromptSection {
  key: string;
  text: string;
}

/** The prompt facts. The date is the session start, so a rebuild never moves it. */
export interface PromptContext {
  session_id: string;
  parent_id: string | null;
  depth: number;
  agent_name: string;
  workspace: string;
  operating_system: string;
  shell: string;
  session_start_date_utc: string;
}

export interface PromptBuild {
  context: PromptContext;
  instructions: { scope: Wire.InstructionScope; path: string; text: string }[];
  skills: { name: string; description: string }[];
  sections: PromptSection[];
}

/** The closed point set of `lib/proto/hook.zig`, with the payload each handler reads. */
export interface HookPayloads {
  "tools.select": { tools: string[]; context: HookContext };
  /** `arguments` is the raw JSON text of the call. */
  "tool.before": { name: string; arguments: string; context: HookContext };
  "tool.after": { name: string; arguments: string } & ToolOutcome;
  "request.build": { model: string; system: string; tools: ToolDecl[]; max_output_tokens: number; context: HookContext };
  "request.send": { url: string; headers: { name: string; value: string }[]; body: string };
  "prompt.build": PromptBuild;
  "compaction.prompt": { context: HookContext; mode: "summarize" | "merge"; prompt: string };
  "input.before": { session_id: string | null; content: Wire.ContentPart[]; create?: Wire.CreateSession };
}

/** The whole value a `replace` answer carries, not a patch. */
export interface HookReplacements {
  "tools.select": { tools: string[] };
  "tool.before": { name: string; arguments: string };
  "tool.after": ToolOutcome;
  "request.build": { model: string; system: string; tools: ToolDecl[]; max_output_tokens: number };
  "request.send": HookPayloads["request.send"];
  "prompt.build": { sections: PromptSection[] };
  "compaction.prompt": { prompt: string };
  "input.before": { content: Wire.ContentPart[] };
}

export type HookPoint = keyof HookPayloads;

/** A block stops the action with a reason. A replace hands the next handler a new value. Nothing means proceed. */
export type HookAnswer<P extends HookPoint = HookPoint> = { block: string; replace?: undefined } | { replace: HookReplacements[P]; block?: undefined };

export type HookHandler<P extends HookPoint = HookPoint> = (payload: HookPayloads[P]) => HookAnswer<P> | null | undefined | void | Promise<HookAnswer<P> | null | undefined | void>;

/** A resource release; the close awaits a returned Promise before the next older release. */
export type Release = () => unknown;

export interface InteractionOptions {
  signal?: CancellationSignal;
  secret?: boolean;
  labels?: { accept?: string; cancel?: string };
}

export interface InteractionSurface {
  /** The process-wide pending count; interaction.changed has no payload and tells callers to read it again. */
  readonly pending: number;
  readonly interactive: boolean;
  deviceLogin: (
    start: Wire.AuthLoginResult,
    outcome: Promise<Wire.AuthLoginOutcome>,
    options?: InteractionOptions,
  ) => Promise<Wire.AuthLoginOutcome | undefined>;
  confirm(title: string, message?: string, options?: InteractionOptions): Promise<boolean | undefined>;
  select(title: string, choices: string[], options?: InteractionOptions): Promise<string | undefined>;
  input(title: string, placeholder?: string, options?: InteractionOptions): Promise<string | undefined>;
  notify(message: string, level?: "info" | "warn" | "error"): void;
}

export type InteractionRequest = Exclude<Wire.InteractionRequest, { type: "select" }>
  | (Extract<Wire.InteractionRequest, { type: "select" }> & { options: string[] })
  | {
    type: "device_login";
    title: string;
    start: Wire.AuthLoginResult;
    outcome: Promise<Wire.AuthLoginOutcome>;
  };

