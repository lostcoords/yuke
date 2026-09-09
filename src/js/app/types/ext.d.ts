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
  list: AdviceEntry[];
}

export interface AdviceEntry {
  owner: string;
  name: string;
  key: string;
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
export type PluginApply = (context: Context, config: unknown) => unknown;

export type ToolExecute = (
  args: any,
  signal: { aborted: boolean },
  context: { workspaceRoot: string; sessionId?: string; messageId?: number; partId?: number },
) => Promise<unknown>;

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: ToolExecute;
  spawnsAgents?: boolean;
}

export type InjectContext = Context & Record<string, any>;
export type InjectApply = (context: InjectContext) => unknown;

export interface Plugin {
  name: string;
  apply: PluginApply;
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
  interactive?: boolean;
  deviceLogin?: (
    start: Wire.AuthLoginResult,
    outcome: Promise<Wire.AuthLoginOutcome>,
    options?: InteractionOptions,
  ) => Promise<Wire.AuthLoginOutcome | undefined>;
  confirm(title: string, message?: string, options?: InteractionOptions): Promise<boolean | undefined>;
  select(title: string, choices: string[], options?: InteractionOptions): Promise<string | undefined>;
  input(title: string, placeholder?: string, options?: InteractionOptions): Promise<string | undefined>;
  notify(message: string, level?: "info" | "warn" | "error"): void;
}

export interface Answerer {
  surfaceFor: (context: Context) => InteractionSurface;
}
