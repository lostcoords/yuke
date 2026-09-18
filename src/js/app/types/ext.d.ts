import type { Context, Scope } from "../ext.js";

export type Disposer = () => void;
export type Effect = () => unknown;
export type AdviceFunction = (...args: any[]) => any;
export type AdviceWhere = "before" | "after" | "around" | "filterArgs" | "filterReturn";

export interface AdviceOptions {
  owner?: string;
  name?: string;
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
export type PluginApply = (context: Context, config: unknown) => void | Promise<void>;

export type ToolExecute = (
  args: any,
  signal: import("yuke:cancellation-native").CancellationSignal,
  context: { workspaceRoot: string; sessionId?: string; messageId?: number; partId?: number },
) => Promise<unknown>;

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: ToolExecute;
  spawnsAgents?: boolean;
  needsSkills?: boolean;
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

export type HookHandler = (payload: any) => unknown;

export interface HookEntry {
  owner: string;
  fn: HookHandler;
}

export interface HookAnswer {
  block?: unknown;
  replace?: unknown;
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
  signal?: { aborted: boolean } | undefined;
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
