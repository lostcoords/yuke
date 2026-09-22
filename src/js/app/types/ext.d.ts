import type { Context, Scope } from "../ext.js";

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

export type EventHandler = Parameters<typeof import("../kernel.js").events.on>[1];
export type EventOptions = Parameters<typeof import("../kernel.js").events.on>[2];
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
  signal: import("yuke:cancellation-native").CancellationSignal,
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
  tui: ReturnType<typeof import("../tui.js").tui.bindTo>;
  [name: string]: unknown;
}

export type InjectContext<K extends string = "tui"> = Context & Pick<Capabilities, K>;
export type InjectApply<K extends string = string> = (context: InjectContext<K>) => unknown;

export interface PluginHandle {
  /** Rejects on startup failure or cancellation. */
  readonly ready: Promise<void>;
  /** Withdraws registrations, cancels startup, stops the plugin, and drains its resources. */
  dispose(): void | Promise<void>;
}

export interface Plugin {
  name: string;
  apply: PluginApply;
  stop?: (context: Context) => void | Promise<void>;
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

export interface OwnedResource {
  release: Disposer | null;
}

export interface ResourceState {
  active: boolean;
  signal?: import("yuke:cancellation-native").CancellationSignal;
  resources?: OwnedResource[];
  children?: Set<Context>;
  closed?: Promise<void>;
}

export interface ScopeEntry {
  owner: Scope | null;
  cleanup: Disposer | null;
}

export interface InteractionOptions {
  signal?: import("yuke:cancellation-native").CancellationSignal;
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
