import { defineTool } from "yuke:internal/define";
import { hostSignal } from "yuke:internal/events";
import { notify, unregister } from "yuke:internal/native";
import type {
  NoticeLevel,
  PluginContext,
  PluginSession,
  PromptBuild,
  Services,
  SessionCleanup,
  SessionContext,
  SessionHooks,
  ToolCallHook,
} from "yuke:plugins";
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

/** The form of a prompt section key. */
const sectionKey = /^[a-z][a-z0-9_-]*$/;

/** The handlers of each hook point, in the order of their addition. Each point of `SessionHooks` is a key. */
type HookLists = { readonly [K in keyof SessionHooks]: SessionHooks[K][] };

/** The part of one plugin in one open session. */
interface Scope {
  /** The name of the plugin. */
  readonly plugin: string;
  /** Set before the abort, so neither an abort listener nor a cleanup can define a tool or add a hook. */
  closed: boolean;
  readonly abort: (reason: string) => void;
  /** The ids of the tools that the scope defined. */
  readonly tools: number[];
  /** The hook handlers of the scope. */
  readonly hooks: HookLists;
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
 * Start the `prompt.build` handlers of the open session `open` on `sections`, after `session` of each plugin settles.
 * Each handler sees the edits of the handlers before it. The answer is the sections after the last handler, and
 * `sections` for a closed session. `abort` aborts the signal of the build.
 */
export function startPromptBuild(
  open: number,
  sections: readonly (readonly [string, string])[],
): Started<[string, string][]> {
  return started(async (signal) => {
    const state = opens.get(open);
    if (state === undefined) return sections.map(([key, text]) => [key, text]);
    await state.ready;
    const build: PromptBuild = { sections: Object.fromEntries(sections), signal };
    for (const scope of state.scopes) {
      // An addition or a removal during a build changes the next build.
      for (const handler of [...scope.hooks["prompt.build"]]) {
        if (scope.closed) break;
        let problem: string | undefined;
        try {
          const result: unknown = await handler(build);
          // A getter in the sections is code of the plugin, so the check runs in the same `try`.
          problem =
            result === undefined ? sectionProblem(build.sections) : "returned a value: a handler returns nothing";
        } catch (error) {
          throw hookFailure(scope.plugin, error);
        }
        if (problem !== undefined) throw new TypeError(`prompt.build of plugin ${scope.plugin} ${problem}`);
      }
    }
    return Object.entries(build.sections);
  });
}

/**
 * Start the `tool.before` handlers of the open session `open` on one call. `id` is the id of the call, `name` is the
 * name of its tool, and `args` is its JSON text. The answer is the reason of the first block, or `undefined` when the
 * call runs. A closed session blocks nothing. `abort` aborts the signal of the call.
 */
export function startToolBefore(open: number, id: string, name: string, args: string): Started<string | undefined> {
  return started(async (signal) => {
    const state = opens.get(open);
    if (state === undefined) return undefined;
    await state.ready;
    const call: ToolCallHook = Object.freeze({ id, name, arguments: frozen(JSON.parse(args)), signal });
    for (const scope of state.scopes) {
      for (const handler of [...scope.hooks["tool.before"]]) {
        if (scope.closed) break;
        try {
          const answer: unknown = await handler(call);
          // A close during the wait ends the turn, so the answer of the closed scope no longer counts.
          if (scope.closed) return undefined;
          if (answer === undefined) continue;
          if (
            typeof answer === "object" &&
            answer !== null &&
            typeof (answer as { block?: unknown }).block === "string"
          ) {
            return (answer as { block: string }).block;
          }
          return `tool.before of plugin ${scope.plugin} gave an answer that is not undefined or { block: string }`;
        } catch (error) {
          return `tool.before of plugin ${scope.plugin} failed: ${textOf(error)}`;
        }
      }
    }
    return undefined;
  });
}

/** A run of the handlers of one point, and the abort of its signal. */
interface Started<T> {
  readonly answer: Promise<T>;
  readonly abort: () => void;
}

/** Start `run` with a new signal. `abort` aborts the signal. */
function started<T>(run: (signal: AbortSignal) => Promise<T>): Started<T> {
  const { signal, abort } = hostSignal();
  const answer = run(signal);
  const cancel = (): void => {
    // The host stops its wait at a cancel, so a later failure of the run has no reader and is no fault.
    answer.catch(() => undefined);
    abort("the turn was cancelled");
  };
  return { answer, abort: cancel };
}

/** `value` with each object in it frozen. A JSON value has no cycle. */
function frozen(value: unknown): unknown {
  if (typeof value === "object" && value !== null) {
    for (const inner of Object.values(value)) frozen(inner);
    Object.freeze(value);
  }
  return value;
}

/** The text form of the thrown `error`. */
function textOf(error: unknown): string {
  try {
    return String(error);
  } catch {
    return "a value without a text form";
  }
}

/** The error of a `prompt.build` handler of `plugin` that threw `error`. It keeps the stack of `error`. */
function hookFailure(plugin: string, error: unknown): Error {
  const failure = new Error(`prompt.build of plugin ${plugin} failed: ${textOf(error)}`);
  // The stack of the host code tells the author nothing.
  if (error instanceof Error && error.stack !== undefined) failure.stack = error.stack;
  else delete failure.stack;
  return failure;
}

/** What is wrong with `sections` after a handler, or `undefined` for an object of valid keys and string texts. */
function sectionProblem(sections: unknown): string | undefined {
  if (typeof sections !== "object" || sections === null || Array.isArray(sections)) {
    return "set build.sections to a value that is not an object";
  }
  for (const [key, text] of Object.entries(sections)) {
    if (!sectionKey.test(key)) return `left the key '${key}', which does not match ${sectionKey}`;
    if (typeof text !== "string") return `left the section '${key}' with a text that is not a string`;
  }
  return undefined;
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
  const scope: Scope = {
    plugin,
    closed: false,
    abort,
    tools: [],
    hooks: { "prompt.build": [], "tool.before": [] },
    settled: Promise.resolve(undefined),
    clean,
  };
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
    hook<K extends keyof SessionHooks>(point: K, handler: SessionHooks[K]): () => void {
      if (scope.closed) throw new TypeError(`plugin ${plugin} adds a hook after the end of its session`);
      if (!Object.hasOwn(scope.hooks, point)) throw new TypeError(`hook: '${String(point)}' is no hook point`);
      if (typeof handler !== "function") throw new TypeError("hook: the handler is no function");
      const handlers: SessionHooks[K][] = scope.hooks[point];
      handlers.push(handler);
      let added = true;
      // A handler can be in the list twice, so each remover removes one entry once.
      return () => {
        if (!added) return;
        added = false;
        handlers.splice(handlers.indexOf(handler), 1);
      };
    },
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
      report(`the session setup failed, and its tools and hooks are gone: ${String(error)}`);
      return undefined;
    }
  })();
  return scope;
}
