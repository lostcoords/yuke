import { defineTool } from "yuke:internal/define";
import { hostSignal } from "yuke:internal/events";
import { notify, unregister } from "yuke:internal/native";
import type { NoticeLevel, PluginContext, PluginSession, Services, SessionCleanup, SessionContext } from "yuke:plugins";
import type { ObjectSchema, Tool } from "yuke:tools";

/** One plugin as the host gives it. The host checked the manifest, the order, and the providers before any plugin code. */
interface PluginSpec {
  readonly name: string;
  readonly root: string;
  readonly dataDir: string;
  /** The absolute path of the entry module, or `undefined` for a plugin without code. */
  readonly entry: string | undefined;
  readonly uses: readonly string[];
  readonly provides: readonly string[];
}

/** The services of the loaded plugins. A service enters only after its provider's `apply` succeeds. */
const services = new Map<string, unknown>();

/** The `session` export of each loaded plugin, in load order. */
const sessionExports: { readonly plugin: string; readonly session: PluginSession }[] = [];

/** The part of one plugin in one open session. */
interface Scope {
  /** Set before the abort, so neither an abort listener nor a cleanup can define a tool. */
  closed: boolean;
  readonly abort: (reason: string) => void;
  /** The ids of the tools that the scope defined. */
  readonly tools: number[];
  /** Settles with the cleanup that `session` returns, or `undefined` after a failure. It never rejects. */
  settled: Promise<SessionCleanup | undefined>;
  /** Run `cleanup`. A failure is a notice. */
  readonly clean: (cleanup: SessionCleanup) => Promise<void>;
}

/** The scopes of each open session, by the open number of the host. */
const opens = new Map<number, { readonly scopes: readonly Scope[]; readonly ready: Promise<void> }>();

/**
 * Load the plugin `spec`: import its entry, check its exports, and await `apply(ctx)`. A failure aborts the signal of
 * the plugin and throws. Only a loaded plugin runs `session`.
 */
export async function load(spec: PluginSpec): Promise<void> {
  const { signal, abort } = hostSignal();
  const pending = new Map<string, unknown>();
  let applying = true;
  const ctx: PluginContext = Object.freeze({
    name: spec.name,
    root: spec.root,
    dataDir: spec.dataDir,
    signal,
    provide(name: string, value: unknown): void {
      if (!spec.provides.includes(name))
        throw new TypeError(`provide: plugin ${spec.name} has no '${name}' in provides`);
      if (!applying) throw new TypeError(`provide: plugin ${spec.name} provides '${name}' after its apply`);
      if (pending.has(name)) throw new TypeError(`provide: plugin ${spec.name} provides '${name}' twice`);
      if (value === undefined || value === null)
        throw new TypeError(`provide: plugin ${spec.name} cannot provide '${name}' as null or undefined`);
      pending.set(name, value);
    },
    get<K extends keyof Services & string>(name: K): NonNullable<Services[K]> {
      if (!spec.uses.includes(name)) throw new TypeError(`get: plugin ${spec.name} has no '${name}' in uses`);
      if (!services.has(name)) throw new Error(`get: no loaded plugin provides '${name}'`);
      return services.get(name) as NonNullable<Services[K]>;
    },
    notify(level: NoticeLevel, message: string): void {
      notify(spec.name, level, String(message), undefined);
    },
  });

  try {
    let session: PluginSession | undefined;
    if (spec.entry !== undefined) {
      const { apply, session: exported } = (await import(spec.entry)) as {
        readonly apply?: unknown;
        readonly session?: unknown;
      };
      if (apply === undefined && exported === undefined) {
        throw new TypeError(`${spec.entry} exports neither apply nor session: a plugin entry exports one or both`);
      }
      if (apply !== undefined && typeof apply !== "function") throw new TypeError("the apply export is no function");
      if (exported !== undefined && typeof exported !== "function") {
        throw new TypeError("the session export is no function");
      }
      session = exported as PluginSession | undefined;
      const result: unknown = apply === undefined ? undefined : apply(ctx);
      if (result !== undefined && (await result) !== undefined) {
        throw new TypeError("apply must return nothing or a promise of nothing");
      }
    }
    applying = false;
    const missing = spec.provides.filter((name) => !pending.has(name));
    if (missing.length > 0) throw new TypeError(`apply did not provide ${missing.join(", ")} of provides`);
    for (const [name, value] of pending) services.set(name, value);
    if (session !== undefined) sessionExports.push({ plugin: spec.name, session });
  } catch (error) {
    applying = false;
    abort(`plugin ${spec.name} did not load`);
    throw error;
  }
}

/**
 * Start `session(s)` of each loaded plugin for the session `sessionId`, under the open number `open`. Each call starts
 * before any of them settles. The open does not wait for them; `ready(open)` does.
 */
export function openSession(open: number, sessionId: string, folder: string): void {
  const scopes = sessionExports.map(({ plugin, session }) => start(open, sessionId, folder, plugin, session));
  const ready = Promise.all(scopes.map((scope) => scope.settled)).then(() => undefined);
  opens.set(open, { scopes, ready });
}

/** Settles when `session` of each plugin of the open session `open` settles. It never rejects. */
export function ready(open: number): Promise<void> {
  return opens.get(open)?.ready ?? Promise.resolve();
}

/**
 * Close the open session `open`: mark each scope closed, abort each signal, and await each cleanup. The close waits
 * for each `session` to settle, also one that ignores the abort. A failed cleanup sends a notice.
 */
export async function closeSession(open: number): Promise<void> {
  const state = opens.get(open);
  if (state === undefined) return;
  opens.delete(open);
  for (const scope of state.scopes) scope.closed = true;
  for (const scope of state.scopes) scope.abort("the session closed");
  await Promise.all(
    state.scopes.map(async (scope) => {
      const cleanup = await scope.settled;
      if (cleanup !== undefined) await scope.clean(cleanup);
    }),
  );
}

/** Run `session(s)` of `plugin` in its own scope. */
function start(open: number, sessionId: string, folder: string, plugin: string, session: PluginSession): Scope {
  const { signal, abort } = hostSignal();
  const report = (message: string): void => notify(plugin, "error", message, sessionId);
  const clean = async (cleanup: SessionCleanup): Promise<void> => {
    try {
      await cleanup();
    } catch (error) {
      report(`the cleanup of the session failed: ${String(error)}`);
    }
  };
  const scope: Scope = { closed: false, abort, tools: [], settled: Promise.resolve(undefined), clean };
  const s: SessionContext = Object.freeze({
    sessionId,
    folder,
    signal,
    tools: Object.freeze({
      define<const S extends ObjectSchema>(tool: Tool<S>): void {
        if (scope.closed) throw new TypeError(`plugin ${plugin} defines a tool after the end of its session`);
        scope.tools.push(defineTool(tool, open));
      },
    }),
    notify(level: NoticeLevel, message: string): void {
      notify(plugin, level, String(message), sessionId);
    },
  });
  scope.settled = (async () => {
    try {
      const result: unknown = await session(s);
      if (result !== undefined && typeof result !== "function") {
        throw new TypeError("session must return nothing or a cleanup function");
      }
      return result as SessionCleanup | undefined;
    } catch (error) {
      // The close owns the scope, so a failure after the close needs no rollback.
      if (scope.closed) return undefined;
      scope.closed = true;
      unregister(scope.tools);
      abort(`session of plugin ${plugin} failed`);
      report(`the session setup failed, and its tools are gone: ${String(error)}`);
      return undefined;
    }
  })();
  return scope;
}
