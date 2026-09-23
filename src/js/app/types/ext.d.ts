import type { CancellationSignal } from "yuke:cancellation-native";
import type { Context, Scope } from "../ext.js";
import type { events } from "../kernel.js";
import type { tui } from "../tui.js";

export type Disposer = () => void;
export type Effect = () => unknown;
export type AdviceFunction = (...args: any[]) => any;
// Advice follows the synchronous call, not promise settlement; a throw skips after and filterReturn.
export type AdviceWhere = "before" | "after" | "around" | "filterArgs" | "filterReturn";

export interface AdviceOptions {
  owner?: string;
  name?: string;
  /** Lower order runs first; equal orders keep registration order. */
  order?: number;
}

export interface AdviceRecord {
  original: AdviceFunction;
  descriptor: PropertyDescriptor | undefined;
  list: AdviceEntry[];
}

export interface AdviceEntry {
  owner: string;
  name: string;
  where: AdviceWhere;
  fn: AdviceFunction;
  order: number;
}

export interface AdviceInfo {
  prop: string;
  owner: string;
  name: string;
  where: AdviceWhere;
  order: number;
}

export type EventHandler = Parameters<typeof events.on>[1];
export type EventOptions = Parameters<typeof events.on>[2];
export type PluginApply = (context: Context) => void | Promise<void>;

export interface ToolContext {
  workspaceRoot: string;
  sessionId?: string;
  messageId?: number;
  partId?: number;
  /** Shows one chunk of live output while the tool runs. The model reads only the result; the stream stops at 1 MiB. */
  output(text: string): void;
}

export type ToolExecute = (
  args: any,
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
  /** Cancels the signal and startup, reverts the registrations, awaits the releases, and frees the name. A sync close answers nothing. */
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

/** The chain stores every point's handlers in one shape, so the entry erases the point. */
export interface HookEntry {
  owner: string;
  fn: HookHandler<any>;
}

export type HookDecision = { type: "block"; reason: string } | { type: "replace"; value: any };

/** A resource release. It may answer a Promise; the close awaits it before the next older release. */
export type Release = () => unknown;

export interface ReleaseEntry {
  release: Release | null;
}

/** The state a scope makes on first use: releases, a signal, and an async close. */
export interface ScopeLife {
  /** The scope another effect closes, such as an inject block; its drain still holds this parent's close. */
  parent: Scope | null;
  releases: ReleaseEntry[] | null;
  signal: CancellationSignal | null;
  closed: Promise<void> | undefined;
  /** The closes of children that left the scope while their releases still run. */
  draining: Set<Promise<void>> | null;
  /** Set when an owner gives up waiting, so a late release fault stays silent. */
  quiet: boolean;
}

/** The state a plugin makes only for an async apply or an async close. */
export interface PluginAsync {
  ready?: Promise<void>;
  startup?: Promise<void> | undefined;
  cancelReady?: ((error: Error) => void) | undefined;
  closed?: Promise<void>;
  settle?: () => void;
  timer?: number;
}

export interface ScopeEntry {
  owner: Scope | null;
  cleanup: Disposer | null;
  /** The child scope this entry closes, so the parent can await its releases. */
  child: Scope | null;
}

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

export type Answerer = {
  notify(owner: string, message: string, level: "info" | "warn" | "error"): void;
} & ({
  interactive: true;
  open(request: InteractionRequest, context: Context, options: InteractionOptions | undefined,
    resolve: (value: unknown) => void, reject: (error: unknown) => void): Disposer;
} | { interactive: false });
