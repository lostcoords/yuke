// The plugin runtime's own bookkeeping: scopes, advice, hooks, and the frontend seam. Plugin code never receives these.
import type { CancellationSignal } from "yuke:internal/native/cancellation";
import type { Context, Scope } from "../ext.js";
import type { AdviceFunction, AdviceWhere, Disposer, HookHandler, InteractionOptions, InteractionRequest, Release } from "./ext.js";

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

/** The chain stores every point's handlers in one shape, so the entry erases the point. */
export interface HookEntry {
  owner: string;
  fn: HookHandler<any>;
}

export type HookDecision = { type: "block"; reason: string } | { type: "replace"; value: any };

export interface ReleaseEntry {
  release: Release | null;
}

/** The state a scope makes on first use: releases, a signal, and an async close. */
export interface ScopeLife {
  /** The scope that awaits this close, so a quiet owner silences a late child fault. */
  awaiter: Scope | null;
  releases: ReleaseEntry[] | null;
  signal: CancellationSignal | null;
  closed: Promise<void> | undefined;
  /** Settles the promise a caller inside the close received. */
  settle: (() => void) | undefined;
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

export type Answerer = {
  notify(owner: string, message: string, level: "info" | "warn" | "error"): void;
} & ({
  interactive: true;
  open(request: InteractionRequest, context: Context, options: InteractionOptions | undefined,
    resolve: (value: unknown) => void, reject: (error: unknown) => void): Disposer;
} | { interactive: false });
