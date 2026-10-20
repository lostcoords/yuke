import { defineTool, fieldsOf, mediaOf } from "yuke:internal/define";
import { hostSignal } from "yuke:internal/events";
import { notify, unregister } from "yuke:internal/native";
import type {
  FinishReason,
  NoticeLevel,
  PluginContext,
  PluginSession,
  ResultMedia,
  RoundAfterAnswer,
  RoundAfterEvent,
  Services,
  SessionCleanup,
  SessionContext,
  SessionHooks,
  ToolCall,
  ToolCallResult,
} from "yuke:plugins";
import type { ObjectSchema, Tool, ToolMedia } from "yuke:tools";

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

/** What `openSession` gets: the open number of the host, the id of the session, and its workspace folder. */
interface OpenRequest {
  readonly open: number;
  readonly sessionId: string;
  readonly folder: string;
}

/**
 * Start `session(s)` of each loaded plugin for the session of `request`. Each call starts before any of them settles.
 * The open does not wait for them; `ready(open)` does.
 */
export function openSession({ open, sessionId, folder }: OpenRequest): void {
  const scopes = sessionExports.map(({ plugin, session }) => start(open, sessionId, folder, plugin, session));
  const ready = Promise.all(scopes.map((scope) => scope.settled)).then(() => undefined);
  opens.set(open, { scopes, ready });
}

/** Settles when `session` of each plugin of the open session `open` settles. It never rejects. */
export function ready(open: number): Promise<void> {
  return opens.get(open)?.ready ?? Promise.resolve();
}

/** One system prompt section, as the host gives it and reads it. */
interface Section {
  readonly key: string;
  readonly text: string;
}

/** What `startPromptBuild` gets. */
interface PromptBuildRequest {
  readonly open: number;
  readonly sections: readonly Section[];
}

/**
 * Start the `prompt.build` handlers of the open session `open` on `sections`. Each handler gets the sections of the
 * answer before it. The answer is the sections after the last handler, and `sections` for a closed session. `abort`
 * aborts the signal of the build.
 */
export function startPromptBuild({ open, sections }: PromptBuildRequest): Started<Section[]> {
  return started(async (signal) => {
    let current: Readonly<Record<string, string>> = Object.freeze(
      Object.fromEntries(sections.map(({ key, text }) => [key, text])),
    );
    await runHandlers(
      open,
      "prompt.build",
      (handler) => handler(Object.freeze({ sections: current, signal })),
      (answer) => {
        current = sectionsOf(answer);
        return false;
      },
    );
    return Object.entries(current).map(([key, text]) => ({ key, text }));
  });
}

/** What `startToolBefore` gets. The host gives the arguments of the call as their parsed JSON. */
interface ToolBeforeRequest {
  readonly open: number;
  readonly call: ToolCall;
}

/**
 * Start the `tool.before` handlers of the open session `open` on `call`. The answer is the reason of the first block,
 * or `undefined` when the call runs. A closed session blocks nothing. A failed handler throws. `abort` aborts the
 * signal of the call.
 */
export function startToolBefore({ open, call }: ToolBeforeRequest): Started<string | undefined> {
  return started(async (signal) => {
    const event = Object.freeze({ call: frozen(call), signal });
    let reason: string | undefined;
    await runHandlers(
      open,
      "tool.before",
      (handler) => handler(event),
      (answer) => {
        reason = blockOf(answer);
        return true;
      },
    );
    return reason;
  });
}

/** What `startRoundAfter` gets. */
interface RoundAfterRequest {
  readonly open: number;
  readonly text: string;
  /** `undefined` after a tool round: a Rust `None` crosses as `undefined`. */
  readonly finishReason: FinishReason | undefined;
  readonly continues: number;
}

/**
 * Start the `round.after` handlers of the open session `open` after one round. The answer is the first answer of a
 * handler, with the text of a `continue` wrapped in a `hook_feedback` tag that names the plugin, or `undefined` when no
 * handler answered. A closed session answers nothing. A failed handler throws. `abort` aborts the signal of the turn.
 */
export function startRoundAfter({
  open,
  text,
  finishReason,
  continues,
}: RoundAfterRequest): Started<RoundAfterAnswer | undefined> {
  return started(async (signal) => {
    const event: RoundAfterEvent = Object.freeze({ text, finishReason: finishReason ?? null, continues, signal });
    let decision: RoundAfterAnswer | undefined;
    await runHandlers(
      open,
      "round.after",
      (handler) => handler(event),
      (answer, plugin) => {
        decision = roundOf(answer, plugin);
        return true;
      },
    );
    return decision;
  });
}

/** The fields of a `round.after` answer. */
const ROUND_FIELDS = ["stop", "continue"];

/** The checked `round.after` answer of `plugin`. Another shape throws a `TypeError`. */
function roundOf(answer: unknown, plugin: string): RoundAfterAnswer {
  const fields = fieldsOf(answer, "the answer", ROUND_FIELDS);
  if (Object.hasOwn(fields, "stop") === Object.hasOwn(fields, "continue")) {
    throw new TypeError("the answer needs exactly one of stop and continue");
  }
  if (Object.hasOwn(fields, "stop")) {
    if (fields.stop !== true) throw new TypeError("the stop of the answer is not true");
    return { stop: true };
  }
  if (typeof fields.continue !== "string") throw new TypeError("the continue of the answer is not a string");
  return { continue: `<hook_feedback plugin="${plugin}">\n${fields.continue}\n</hook_feedback>` };
}

/** A media item of a changed result as the host reads it: the index of an original item, or a new item. */
type ChangedMedia = number | ToolMedia;

/** The result after the `tool.after` handlers, as the host reads it. */
interface ChangedResult {
  readonly text: string;
  readonly isError: boolean;
  readonly media: readonly ChangedMedia[];
}

/** What `startToolAfter` gets: the call as for `startToolBefore`, and its result with each media item as its facts. */
interface ToolAfterRequest {
  readonly open: number;
  readonly call: ToolCall;
  readonly result: {
    readonly text: string;
    readonly isError: boolean;
    readonly media: readonly { readonly mimeType: string; readonly size: number }[];
  };
}

/**
 * Start the `tool.after` handlers of the open session `open` on the result of `call`. The answer is the result after
 * the last handler, or `undefined` when no handler answered. A closed session changes nothing. A failed handler throws.
 * `abort` aborts the signal of the call.
 */
export function startToolAfter({ open, call, result: given }: ToolAfterRequest): Started<ChangedResult | undefined> {
  return started(async (signal) => {
    frozen(call);
    // The index is the id, and a kept item crosses back to the host as its index.
    const originals: readonly ResultMedia[] = given.media.map(({ mimeType, size }, index) =>
      Object.freeze({ id: String(index), mimeType, size }),
    );
    let result: ToolCallResult = Object.freeze({
      text: given.text,
      isError: given.isError,
      media: Object.freeze([...originals]),
    });
    let answered = false;
    await runHandlers(
      open,
      "tool.after",
      (handler) => handler(Object.freeze({ call, result, signal })),
      (answer) => {
        result = applied(result, answer, originals);
        answered = true;
        return false;
      },
    );
    if (!answered) return undefined;
    return {
      text: result.text,
      isError: result.isError,
      media: result.media.map((item) => {
        const index = originals.indexOf(item as ResultMedia);
        return index === -1 ? (item as ToolMedia) : index;
      }),
    };
  });
}

/**
 * Run the `point` handlers of the open session `open` in plugin order, then in the order of their addition, after
 * `session` of each plugin settles. `call` runs one handler. `take` gets each answer that is not `undefined`, and a
 * `true` from it ends the run. A throw of either names the point and the plugin. A closed session runs no handler, and
 * a close during a handler ends the run without its answer.
 */
async function runHandlers<K extends keyof SessionHooks>(
  open: number,
  point: K,
  call: (handler: SessionHooks[K]) => unknown,
  take: (answer: unknown, plugin: string) => boolean,
): Promise<void> {
  const state = opens.get(open);
  if (state === undefined) return;
  await state.ready;
  // One copy of every list at the start, so an addition or a removal during the run changes only the next run.
  const lists = state.scopes.map((scope) => ({ scope, handlers: [...scope.hooks[point]] as SessionHooks[K][] }));
  for (const { scope, handlers } of lists) {
    for (const handler of handlers) {
      if (scope.closed) break;
      try {
        const answer: unknown = await call(handler);
        // A close during the wait ends the turn, so the answer of the closed scope no longer counts.
        if (scope.closed) return;
        // A getter in the answer is code of the plugin, so the check runs in the same `try`.
        if (answer !== undefined && take(answer, scope.plugin)) return;
      } catch (error) {
        throw hookFailure(point, scope.plugin, error);
      }
    }
  }
}

/** The checked copy of the sections of a `prompt.build` answer. Another shape throws a `TypeError`. */
function sectionsOf(answer: unknown): Readonly<Record<string, string>> {
  const { sections } = fieldsOf(answer, "the answer", ["sections"]);
  if (typeof sections !== "object" || sections === null || Array.isArray(sections)) {
    throw new TypeError("the sections of the answer are not an object");
  }
  const copy: Record<string, string> = {};
  for (const [key, text] of Object.entries(sections)) {
    if (!sectionKey.test(key)) throw new TypeError(`the section key '${key}' does not match ${sectionKey}`);
    if (typeof text !== "string") throw new TypeError(`the text of the section '${key}' is not a string`);
    copy[key] = text;
  }
  return Object.freeze(copy);
}

/** The reason of a `tool.before` answer. Another shape throws a `TypeError`. */
function blockOf(answer: unknown): string {
  const { block } = fieldsOf(answer, "the answer", ["block"]);
  if (typeof block !== "string") throw new TypeError("the block of the answer is not a string");
  return block;
}

/** The fields of a `tool.after` answer. */
const AFTER_FIELDS = ["text", "isError", "media"];

/** `result` after the `tool.after` answer `answer`. An item of `originals` stays as it is. Another shape throws. */
function applied(result: ToolCallResult, answer: unknown, originals: readonly ResultMedia[]): ToolCallResult {
  const fields = fieldsOf(answer, "the answer", AFTER_FIELDS);
  if (fields.text !== undefined && typeof fields.text !== "string") {
    throw new TypeError("the text of the answer is not a string");
  }
  if (fields.isError !== undefined && typeof fields.isError !== "boolean") {
    throw new TypeError("the isError of the answer is not a boolean");
  }
  let media = result.media;
  if (fields.media !== undefined) {
    const list = fields.media;
    if (!Array.isArray(list)) throw new TypeError("the media of the answer is not an array");
    const items: (ResultMedia | ToolMedia)[] = [];
    // An index loop, so a hole of a sparse array fails as a value that is not an object.
    for (let index = 0; index < list.length; index += 1) {
      const item: unknown = list[index];
      const place = `the answer media[${index}]`;
      // A `ToolMedia` has no `id`, so the field tells the two forms apart.
      const kept = typeof item === "object" && item !== null && Object.hasOwn(item, "id");
      items.push(kept ? keptOf(item, place, originals) : Object.freeze(mediaOf(item, place)));
    }
    media = Object.freeze(items);
  }
  return Object.freeze({
    text: (fields.text as string | undefined) ?? result.text,
    isError: (fields.isError as boolean | undefined) ?? result.isError,
    media,
  });
}

/** The fields of a `KeptMedia`. */
const KEPT_FIELDS = ["id", "mimeType", "size"];

/** The item of `originals` that the answer item `value` keeps by its `id`. An unknown id or a changed fact throws. */
function keptOf(value: unknown, place: string, originals: readonly ResultMedia[]): ResultMedia {
  const fields = fieldsOf(value, place, KEPT_FIELDS);
  const original = originals.find((item) => item.id === fields.id);
  if (original === undefined) throw new TypeError(`${place}.id names no media item of the result`);
  if (fields.mimeType !== undefined && fields.mimeType !== original.mimeType) {
    throw new TypeError(`${place}.mimeType differs from the kept item`);
  }
  if (fields.size !== undefined && fields.size !== original.size) {
    throw new TypeError(`${place}.size differs from the kept item`);
  }
  return original;
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
function frozen<T>(value: T): T {
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

/** The error of a `point` handler of `plugin` that failed with `error`. It keeps the stack of `error`. */
function hookFailure(point: string, plugin: string, error: unknown): Error {
  const failure = new Error(`${point} of plugin ${plugin} failed: ${textOf(error)}`);
  // The stack of the host code tells the author nothing.
  if (error instanceof Error && error.stack !== undefined) failure.stack = error.stack;
  else delete failure.stack;
  return failure;
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
    hooks: { "prompt.build": [], "tool.before": [], "tool.after": [], "round.after": [] },
    settled: Promise.resolve(undefined),
    clean,
  };
  const s: SessionContext = Object.freeze({
    sessionId,
    folder,
    signal,
    tools: Object.freeze({
      define<const S extends ObjectSchema>(tool: Tool<S>): () => void {
        if (scope.closed) throw new TypeError(`plugin ${plugin} defines a tool after the end of its session`);
        const id = defineTool(tool, open);
        scope.tools.push(id);
        // Each id is new, so a second removal finds nothing, and the removal at a failure skips a removed id.
        return () => unregister([id]);
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
