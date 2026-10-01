import type { CancellationSignal } from "yuke:internal/native/cancellation";
import type { DrainFact, EngineEvent } from "yuke:internal/native/engine";
import type { Job } from "yuke:internal/native/jobs";
import type { Context, Scope } from "../ext.js";
import type { tui } from "../tui.js";
import type { Session } from "../session.js";
import type { Render } from "./transcript.js";
import type { ComposerVim } from "../composer-vim.js";
import type { ChatRegion, ChatView, StripRow } from "../chat-view.js";
import type { Composer } from "../ui.js";
import type { HostMouseEvent, ViewLike } from "./core.js";

/** A function that reverts one registration. A second call does nothing. */
export type Disposer = () => void;

/** One notification in the history. */
export interface Notification {
  level: Wire.NoticeLevel;
  /** The plugin or the application part that sent the notification. */
  source: string;
  message: string;
  /** The stack of a fault, or an empty string. */
  stack: string;
  /** The number of times this entry arrived in a row. */
  count: number;
}
export type AdviceFunction = (...args: any[]) => any;
// Advice follows the synchronous call, not promise settlement; a throw skips after and filterReturn.
export type AdviceWhere = "before" | "after" | "around" | "filterArgs" | "filterReturn";
/** The keys of `T` that hold a method, so advice cannot name a field, an accessor value, or a missing key. */
export type MethodKey<T> = { [P in keyof T]-?: T[P] extends AdviceFunction ? P : never }[keyof T] & string;
/** The advice for one `where` on method `F`, as `applyAdvice` calls it. `this` is the object whose method runs. A falsy `filterArgs` or an undefined `filterReturn` keeps the value. */
export type AdviceFor<F extends AdviceFunction, W extends AdviceWhere, This = unknown> =
  W extends "filterArgs" ? (this: This, args: Parameters<F>) => Parameters<F> | null | void :
  W extends "before" | "after" ? (this: This, ...args: Parameters<F>) => void :
  W extends "around" ? (this: This, next: F, ...args: Parameters<F>) => ReturnType<F> :
  W extends "filterReturn" ? (this: This, result: ReturnType<F>) => ReturnType<F> | void :
  never;

export interface AdviceOptions {
  /** The plugin that owns the advice. `ctx.advise` sets it to the plugin name. */
  owner?: string;
  /** The label that `advice.list` shows. The default is the function name. */
  name?: string;
  /** Lower order runs first; equal orders keep registration order. */
  order?: number;
}

/** An engine drain that names facts; each fact event carries the whole drain. */
export type EngineFactEvent = Exclude<EngineEvent, { type: "activity" }>;
type EngineFacts = { [K in Exclude<DrainFact, "notice" | "auth.login_finished">]: (ev: EngineFactEvent) => void };

/**
 * Every event on the bus, as its listener signature. A fact such as `x.changed` answers nothing; a point is asked
 * with `bail`, and the newest listener that answers wins. A plugin names its own events `<plugin>:<name>`.
 */
export interface Events extends EngineFacts {
  /** The process added a notification, or increased the count of the newest one. The history owns the entry. */
  "notify.posted"(entry: Readonly<Notification>): void;
  "engine.drained"(ev: EngineFactEvent): void;
  /** A notice and a login outcome name no session, so they arrive only in an index drain. */
  "notice"(ev: Extract<EngineEvent, { type: "index" }>): void;
  "auth.login_finished"(ev: Extract<EngineEvent, { type: "index" }>): void;
  "engine.activity.changed"(): void;
  "job.changed"(job: Job): void;
  "interaction.changed"(): void;
  /** A true answer holds the quit. */
  "quit.request"(): boolean | null | undefined;
  "ui.started"(ev: { type: "start" }): void;
  "ui.closed"(ev: { type: "input_closed" }): void;
  "ui.resized"(ev: Extract<HostEvent, { type: "resize" }>): void;
  "ui.ticked"(ev: Extract<HostEvent, { type: "tick" }>): void;
  "key.pressed"(ev: Extract<HostEvent, { type: "key" }>): void;
  "mouse.received"(ev: HostMouseEvent): void;
  "paste.received"(ev: Extract<HostEvent, { type: "paste" }>): void;
  "focus.changed"(ev: Extract<HostEvent, { type: "focus" }>): void;
  /** The terminal background changed between light and dark. `c.tui.background` holds the new class. */
  "background.changed"(ev: Extract<HostEvent, { type: "background" }>): void;
  /** The `colors` setting changed. `c.tui.colors` holds the color depth that the default palette now uses. */
  "colors.changed"(): void;
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
  /** The current session id changed; read `currentSession()`. */
  "session.current.changed"(): void;
  /** A true answer claims a left press in the chat pane. */
  "chat.press"(view: ChatView, ev: HostMouseEvent): boolean | null | undefined;
  "chat.strip"(view: ChatView): StripRow[] | null | undefined;
  "chat.rule"(view: ChatView): StripRow | null | undefined;
  "chat.cursor"(view: ChatView): { x: number; y: number; visible: boolean } | null | undefined;
  /** A string replaces the composer prompt. A listener that changes its answer must call `root.invalidate()`, because each layout asks once. */
  "composer.prompt"(composer: Composer): string | null | undefined;
  "composer-vim:mode"(composer: Composer, mode: "insert" | "normal"): void;
  [name: `${string}:${string}`]: (...args: any[]) => any;
}

export type EventName = keyof Events & string;
/** `prepend` puts the listener first: `emit` tells it first, and `bail` asks it last. */
export interface EventOptions { prepend?: boolean }

/** The shared event bus: `emit` tells every listener in registration order; `bail` asks the newest listener first and answers the first value that is not false or null. */
export interface Bus {
  /** Add a listener. It throws a TypeError for an event name that no tier declares; an `owner:event` name needs no declaration. */
  on<K extends EventName>(name: K, fn: Events[K], opts?: EventOptions): Disposer;
  /** Add a listener for the next emit only. */
  once<K extends EventName>(name: K, fn: Events[K]): Disposer;
  /** Tell every listener in registration order. A listener that throws is reported, and the next listener runs. */
  emit<K extends EventName>(name: K, ...args: Parameters<Events[K]>): void;
  /** Ask the newest listener first. Answers the first value that is not false, null, or undefined, or undefined when no listener answers. */
  bail<K extends EventName>(name: K, ...args: Parameters<Events[K]>): Exclude<ReturnType<Events[K]>, false | null | undefined | void> | undefined;
  /** Declare more names for the life of a tier; the disposer withdraws them. */
  declare(names: string[]): Disposer;
  onError: ((error: unknown, name: string) => void) | null;
}
/**
 * The start function of a plugin. Register the plugin in the synchronous part of `apply`.
 * A sync apply may return its cleanup; an async apply resolves to nothing. The host never waits for an async apply. A rejection closes the plugin.
 */
export type PluginApply = (context: Context) => void | (() => void) | Promise<void>;

/** The facts of one tool call. */
export interface ToolContext {
  /** The absolute workspace root of the session that made the call. */
  workspaceRoot: string;
  /** The session that made the call. */
  sessionId: string;
  /** The message that holds the call in the transcript. */
  messageId: number;
  /** The part that holds the call in its message. */
  partId: number;
  /** Shows one chunk of live output while the tool runs. The model reads only the result; the stream stops at 1 MiB. */
  output(text: string): void;
}

/**
 * Run one tool call. A string reaches the model unchanged. `undefined` produces empty output. A `ToolOutcome` adds an error flag, a diff, images, or loaded tools.
 * Any other value, or an object with an unknown key, is an error. A rejection gives the model an error result with the message of the error.
 */
export type ToolExecute = (
  /** The JSON the model wrote. It may be any value, so a tool checks it before use. */
  args: unknown,
  /** The host cancels it when the call stops. */
  signal: CancellationSignal,
  context: ToolContext,
) => Promise<string | ToolOutcome | void>;

/** One tool for `ctx.tools.define`. */
export interface ToolDefinition {
  /** 1 to 64 characters of a-z, A-Z, 0-9, _ or -. No other tool may have the name. */
  name: string;
  /** The text the model reads to decide when to call the tool. It must not be empty. */
  description: string;
  /** The JSON Schema of the arguments. It needs `type: "object"` and a `properties` object. */
  parameters: Record<string, unknown>;
  execute: ToolExecute;
  /** Request deferred loading until a tool search names the definition. */
  defer?: boolean;
}

/** The value `inject` gives each capability name. A plugin declares its own through `declare module "yuke"`; an undeclared name is `unknown`. */
/** The `chat` capability. The shell asks it for each new pane, and plugins render the transcript through it. */
export interface ChatService {
  /** A new chat pane. Without `session`, the pane shows a new draft. */
  create(session?: Session): ChatView;
  /** Add a renderer to every transcript. It stacks on the renderers before it. The disposer removes it, and an unload of the block removes it too. */
  render(render: Render): Disposer;
  /** Rebuild the rows of one part in every pane, because its renderer reads state outside the part. */
  refresh(messageId: number, partId: number): void;
}

export interface Capabilities {
  /** The terminal UI of one block. An unload of the block removes what the block adds. The shell provides it. */
  tui: ReturnType<typeof tui.bindTo>;
  /** The chat panes and their transcript renderers. The `chat` plugin provides it, and a plugin that replaces the chat pane provides its own. */
  chat: ChatService;
  /** The composer mode service. It exists only while the `composerVim` plugin runs. */
  "composer-vim": ComposerVim;
  [name: string]: unknown;
}

/** A name that `ctx.<name>` already holds, so `provide` and `inject` refuse it at runtime. */
export type ContextMember = keyof Context | "constructor";
/** `unknown` for a free capability name and `never` for a context member, so `K & FreeName<K>` refuses a member. */
export type FreeName<K extends string> = [Extract<K, ContextMember>] extends [never] ? unknown : never;
/** A provider is the capability, or an object whose `bindTo` builds the capability for each block. */
export type Provider<K extends string> = Capabilities[K] | { bindTo(context: Context): Capabilities[K] };

/** The context of an `inject` block: a Context with each named capability as a member. */
export type InjectContext<K extends string = "tui"> = Context & Pick<Capabilities, K>;
/** The block of `inject`. It runs synchronously, and a returned function runs as its cleanup when the block reverts. */
export type InjectApply<K extends string = string> = (context: InjectContext<K>) => unknown;

/** The handle that `plugins.use` and `ctx.use` answer. */
export interface PluginHandle {
  /** Cancels the signal, reverts the registrations, and waits for the releases and an async apply until the close deadline. Then it frees the name. A sync close answers nothing. */
  dispose(): void | Promise<void>;
}

/** A plugin for `plugins.use` or `ctx.use`. */
export interface Plugin {
  /** A non-empty name. No other live plugin may have it. It prefixes the commands of the plugin. */
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

/** One tool result. The model reads `output`, `media`, and `tools_added`. The UI shows `diff`. An error result shows `output` only. */
export interface ToolOutcome {
  output: string;
  is_error?: boolean;
  diff?: Wire.DiffFile[];
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

/** A hook point that `ctx.hook` can answer. */
export type HookPoint = keyof HookPayloads;

/** A block stops the action with a reason. A replace hands the next handler a new value. Nothing means proceed. */
export type HookAnswer<P extends HookPoint = HookPoint> = { block: string; replace?: undefined } | { replace: HookReplacements[P]; block?: undefined };

/** A handler of one hook point. It may be async. A throw blocks the action and reports a fault. */
export type HookHandler<P extends HookPoint = HookPoint> = (payload: HookPayloads[P]) => HookAnswer<P> | null | undefined | void | Promise<HookAnswer<P> | null | undefined | void>;

/** A resource release; the close awaits a returned Promise before the next older release. */
export type Release = () => unknown;

/** The options of one prompt. */
export interface InteractionOptions {
  /** A cancel of this signal closes the prompt, and the prompt answers undefined. */
  signal?: CancellationSignal;
  /** Hide the typed text of `input`. */
  secret?: boolean;
  /** The two answers of `confirm`. The defaults are Yes and No. */
  labels?: { accept?: string; cancel?: string };
}

/**
 * Prompts and notifications for one plugin. Each prompt answers undefined on a cancel, a signal cancel, or an unload of the plugin.
 * A prompt rejects with an InteractionUnavailable error when no answerer is installed.
 */
export interface InteractionSurface {
  /** The process-wide pending count; interaction.changed has no payload and tells callers to read it again. */
  readonly pending: number;
  /** True when the frontend can show prompts and the plugin is alive. Without it, `confirm` answers false, the other prompts answer undefined, and a warning names the prompt. */
  readonly interactive: boolean;
  /** Show the URL and the code of a device-code login. Answers the login outcome, or undefined on a cancel. */
  deviceLogin: (
    start: Wire.AuthLoginResult,
    outcome: Promise<Wire.AuthLoginOutcome>,
    options?: InteractionOptions,
  ) => Promise<Wire.AuthLoginOutcome | undefined>;
  /** Ask a yes or no question. Answers true or false, or undefined on a cancel. */
  confirm(title: string, message?: string, options?: InteractionOptions): Promise<boolean | undefined>;
  /** Ask for one of `choices`, which must be non-empty and unique. Answers the chosen string, or undefined on a cancel. */
  select(title: string, choices: string[], options?: InteractionOptions): Promise<string | undefined>;
  /** Ask for one line of text. Answers the text, or undefined on a cancel. */
  input(title: string, placeholder?: string, options?: InteractionOptions): Promise<string | undefined>;
  /** Add a notification from this plugin to the history. It needs no frontend. The default level is info. */
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

