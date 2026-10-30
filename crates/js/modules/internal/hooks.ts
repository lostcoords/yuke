// The part of each plugin in each open session: its scope, its tools and hooks, and the runs of the hook points.

import { defineTool } from "yuke:internal/define";
import { hostOperation, hostSignal, signalOf, underSignal, underStop } from "yuke:internal/events";
import { failureOf, stackOf, textOf } from "yuke:internal/failure";
import { emit, notify, type Operation, type RoundNatives, unregister } from "yuke:internal/native";
import { type Options, sessionExports } from "yuke:internal/plugins";
import { frozen, jsonCopy } from "yuke:internal/values";
import type {
  AskOptions,
  Cleanup,
  FinishReason,
  InputKind,
  InputOptions,
  InputSource,
  KeptMedia,
  NoticeLevel,
  RequestOptions,
  ResultMedia,
  RoundAfterAnswer,
  RoundAfterEvent,
  RoundBeforeEvent,
  RoundFailure,
  SessionContext,
  SessionHooks,
  SideRequestOptions,
  SideRequestResult,
  ToolAfterAnswer,
  ToolCall,
  ToolCallResult,
} from "yuke:plugins";
import { ExtensionRequestError } from "yuke:plugins";
import type { Block, ExtensionRequestParams, ModelReference } from "yuke:protocol";
import type { DisplayBlock, ObjectSchema, Tool, ToolMedia } from "yuke:tools";

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
  settled: Promise<Cleanup | undefined>;
  /** Run `cleanup`. A failure is a notice. */
  readonly clean: (cleanup: Cleanup) => Promise<void>;
}

/** The scopes of each open session, by the open number of the host. */
const opens = new Map<number, { readonly scopes: readonly Scope[]; readonly ready: Promise<void> }>();

/** A question for the native `ask`, which reads it through JSON as an `InteractionRequest` of the protocol. */
type Question =
  | { readonly kind: "confirm"; readonly title: string; readonly message: string }
  | { readonly kind: "select"; readonly title: string; readonly options: readonly string[] }
  | {
      readonly kind: "input";
      readonly title: string;
      readonly placeholder: string | undefined;
      readonly secret: boolean;
    };

/** Ask the user `question` for the plugin `source`. The promise gives the answer, or `undefined` without one. */
type Ask = (source: string, question: Question) => Operation<boolean | string | undefined>;

/**
 * Send the request `request` of the plugin `source` with the JSON text `data` to the client. The promise gives the
 * result. A failure rejects with a record `{ code?, message, data? }`. A cancel rejects with `{ cancelled: true }`.
 */
type SendRequest = (source: string, request: string, data: string) => Operation<unknown>;

/** Answers the requests of the plugins in place of the client: the `respond` of `createHost` in a test. */
let responder: ((request: ExtensionRequestParams) => Operation<unknown>) | undefined;

/** Answer the requests of the plugins with `respond`, which gives what the native gives. `undefined` restores it. */
export function setResponder(respond: typeof responder): void {
  responder = respond;
}

/**
 * What `openSession` gets: the open number of the host, the id of the session, its workspace folder, and the natives
 * of the session.
 */
interface OpenRequest {
  readonly open: number;
  readonly sessionId: string;
  readonly folder: string;
  readonly ask: Ask;
  readonly request: SendRequest;
  /** The model that the settings of the session name now. */
  readonly model: () => ModelReference;
}

/**
 * Start `session(s)` of each loaded plugin for the session of `request`. Each call starts before any of them settles.
 * The open does not wait for them; `ready(open)` does.
 */
export function openSession(request: OpenRequest): void {
  const { open, sessionId, folder, ask, model } = request;
  const scopes = sessionExports.map((entry) => start(open, sessionId, folder, ask, request.request, model, entry));
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

/** The abort message of a hook run at a cancel. */
const TURN_CANCELLED = "the turn was cancelled";

/**
 * Start the `prompt.build` handlers of the open session `open` on `sections`. Each handler gets the sections of the
 * answer before it. The answer is the sections after the last handler, and `sections` for a closed session. `cancel`
 * aborts the signal of the build.
 */
export function startPromptBuild(request: PromptBuildRequest): Operation<Section[]> {
  const { open, sections } = request;
  return hostOperation(async (signal) => {
    let current: Readonly<Record<string, string>> = Object.freeze(
      Object.fromEntries(sections.map((section) => [section.key, section.text])),
    );
    await runHandlers(
      open,
      "prompt.build",
      (handler) => handler(Object.freeze({ sections: current, signal })),
      (answer) => {
        current = Object.freeze({ ...answer.sections });
        return false;
      },
    );
    return Object.entries(current).map((entry) => {
      const [key, text] = entry;
      return { key, text };
    });
  }, TURN_CANCELLED);
}

/** What `startToolBefore` gets. The host gives the arguments of the call as their parsed JSON. */
interface ToolBeforeRequest {
  readonly open: number;
  readonly call: ToolCall;
}

/**
 * Start the `tool.before` handlers of the open session `open` on `call`. The answer is the reason of the first block,
 * or `undefined` when the call runs. A closed session blocks nothing. A failed handler throws. `cancel` aborts the
 * signal of the call.
 */
export function startToolBefore(request: ToolBeforeRequest): Operation<string | undefined> {
  const { open, call } = request;
  return hostOperation(async (signal) => {
    const event = Object.freeze({ call: frozen(call), signal });
    let reason: string | undefined;
    await runHandlers(
      open,
      "tool.before",
      (handler) => handler(event),
      (answer) => {
        reason = answer.block;
        return true;
      },
    );
    return reason;
  }, TURN_CANCELLED);
}

/** What `startInputBefore` gets. */
interface InputBeforeRequest {
  readonly open: number;
  readonly sessionId: string;
  readonly source: InputSource;
  readonly kind: InputKind;
  readonly blocks: readonly Block[];
}

/**
 * Start the `input.before` handlers of the open session `open` for one input. The answer is `undefined` for no change,
 * `{ blocks }` for new blocks, or `{ blocks: undefined }` for a removal. A failed handler removes the input and sends a
 * notice. `cancel` aborts the signal of the turn.
 */
export function startInputBefore(
  request: InputBeforeRequest,
): Operation<{ blocks: readonly (Block | ToolMedia)[] | undefined } | undefined> {
  const { open, sessionId, source, kind, blocks } = request;
  return hostOperation(async (signal) => {
    let current: readonly (Block | ToolMedia)[] = blocks;
    let replaced = false;
    let removed = false;
    try {
      await runHandlers(
        open,
        "input.before",
        (handler) => handler(Object.freeze({ source: frozen(source), kind, blocks: frozen(current), signal })),
        (answer, plugin) => {
          if (answer.block !== undefined) {
            notify(plugin, "warn", `the plugin blocked the input: ${answer.block}`, sessionId);
            removed = true;
            return true;
          }
          if (answer.handled !== undefined) {
            removed = true;
            return true;
          }
          current = answer.replace.blocks.map((item) =>
            "mimeType" in item
              ? item.path !== undefined
                ? { mimeType: item.mimeType, path: item.path }
                : { mimeType: item.mimeType, bytes: new Uint8Array(item.bytes) }
              : jsonCopy(item, "the answer"),
          );
          replaced = true;
          return false;
        },
      );
    } catch (error) {
      notify("host:plugins", "error", error instanceof Error ? error.message : textOf(error), sessionId);
      return { blocks: undefined };
    }
    if (removed) return { blocks: undefined };
    return replaced ? { blocks: current } : undefined;
  }, TURN_CANCELLED);
}

/** What `startRoundBefore` gets. A Rust `None` crosses as `undefined`. */
interface RoundBeforeRequest {
  readonly open: number;
  readonly window: number | undefined;
  readonly inputTokens: number | undefined;
  /** The estimated input tokens of the context before the round. It adds to `inputTokens` when that count is set. */
  readonly contextTokens: number;
  readonly blocks: number;
  readonly round: RoundNatives;
}

/** What `startRoundRetry` gets: the facts of `startRoundBefore`, and why the round failed. */
interface RoundRetryRequest extends RoundBeforeRequest {
  readonly failure: RoundFailure;
  readonly retries: number;
}

/** The hook points whose handlers plan a round. */
type RoundPoint = "round.before" | "round.retry";

/** The event of a handler of `K`. */
type EventOf<K extends RoundPoint> = Parameters<SessionHooks[K]>[0];

/**
 * The plan of the `round.before` or the `round.retry` handlers as the host reads it. Each part names the plugin of its
 * last change.
 */
interface RoundBeforePlan {
  replace?: { readonly plugin: string; readonly head: readonly Block[]; readonly keep: number };
  model?: { readonly plugin: string; readonly provider: string; readonly model: string };
  settings?: { readonly plugin: string; readonly changes: Readonly<Record<string, unknown>> };
}

/** Send the side request of `round` for a handler that sees `head`, then the last `kept` blocks of the round. */
async function sideRequest(
  round: RoundNatives,
  head: readonly Block[],
  kept: number,
  options: SideRequestOptions,
): Promise<SideRequestResult> {
  const { prompt, blocks = head.length + kept, maxOutputTokens, abortSignal } = options;
  const request = { head: jsonCopy(head, "the answer"), kept, blocks, prompt, maxOutputTokens };
  return Object.freeze(await underStop(abortSignal, () => round.sideRequest(request)));
}

/** Start the `round.before` handlers of the open session `open` before one round, as `startRoundPlan` says. */
export function startRoundBefore(request: RoundBeforeRequest): Operation<RoundBeforePlan | undefined> {
  return startRoundPlan("round.before", request, {});
}

/** Start the `round.retry` handlers of the open session `open` after a failed round, as `startRoundPlan` says. */
export function startRoundRetry(request: RoundRetryRequest): Operation<RoundBeforePlan | undefined> {
  const { failure, retries, ...facts } = request;
  return startRoundPlan("round.retry", facts, { failure: Object.freeze({ ...failure }), retries });
}

/**
 * Start the handlers of `point` of the open session `open`. Each handler gets the facts of the round, `facts`, and the
 * context after the replacements before it. The answer is the plan of all handlers, or `undefined` when no handler
 * answered. A closed session answers nothing. A failed handler throws. `cancel` aborts the signal of the turn.
 */
function startRoundPlan<K extends RoundPoint>(
  point: K,
  request: RoundBeforeRequest,
  facts: Omit<EventOf<K>, keyof RoundBeforeEvent>,
): Operation<RoundBeforePlan | undefined> {
  const { open, window, inputTokens, contextTokens, blocks, round } = request;
  return hostOperation(async (signal) => {
    // The replacements so far make the context `head`, then the last `kept` blocks of the context before the round.
    let head: readonly Block[] = [];
    let kept = blocks;
    const plan: RoundBeforePlan = {};
    let answered = false;
    await runHandlers(
      open,
      point,
      (handler) => {
        // The event shows the context that this handler sees, also after the answers of the later handlers.
        const seen = { head, kept };
        const tokens = () => round.tokens(jsonCopy(seen.head, "the answer"), seen.kept);
        // `inputTokens` counts the old context, so after a replacement only the estimate of each block holds.
        const replaced = seen.head.length > 0 || seen.kept !== blocks;
        const event = Object.freeze({
          ...facts,
          window: window ?? null,
          inputTokens: inputTokens ?? null,
          contextTokens: replaced ? tokens().reduce((sum, count) => sum + count, 0) : contextTokens,
          blocks: seen.head.length + seen.kept,
          blockTokens: tokens,
          context: () => {
            const before = round.context();
            return [...jsonCopy(seen.head, "the answer"), ...before.slice(before.length - seen.kept)];
          },
          sideRequest: (options: SideRequestOptions) => sideRequest(round, seen.head, seen.kept, options),
          signal,
        }) as EventOf<K>;
        return (handler as (event: EventOf<K>) => ReturnType<SessionHooks[K]>)(event);
      },
      (answer, plugin) => {
        if (answer.replace !== undefined) {
          const keep = answer.replace.keep;
          const given = jsonCopy(answer.replace.head, "the answer");
          // A keep past the kept blocks also keeps the end of the earlier head.
          const keeps = Math.min(keep, head.length + kept);
          head = keeps <= kept ? given : [...given, ...head.slice(head.length - (keeps - kept))];
          kept = Math.min(kept, keeps);
          plan.replace = { plugin, head, keep: kept };
        }
        if (answer.model !== undefined) {
          plan.model = { plugin, provider: answer.model.provider, model: answer.model.model };
        }
        if (answer.settings !== undefined) {
          plan.settings = {
            plugin,
            changes: { ...plan.settings?.changes, ...jsonCopy(answer.settings, "the answer") },
          };
        }
        answered = true;
        return false;
      },
    );
    return answered ? plan : undefined;
  }, TURN_CANCELLED);
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
 * handler, with the plugin that sent a `continue`, or `undefined` when no handler answered. A closed session answers
 * nothing. A failed handler throws. `cancel` aborts the signal of the turn.
 */
export function startRoundAfter(request: RoundAfterRequest): Operation<RoundDecision | undefined> {
  const { open, text, finishReason, continues } = request;
  return hostOperation(async (signal) => {
    const event: RoundAfterEvent = Object.freeze({ text, finishReason: finishReason ?? null, continues, signal });
    let decision: RoundDecision | undefined;
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
  }, TURN_CANCELLED);
}

/** What the host reads of a `round.after` answer: a stop, or the text of a continue and the plugin that sent it. */
type RoundDecision = { readonly stop: true } | { readonly continue: string; readonly plugin: string };

/** The `round.after` answer with the source of a continue. */
function roundOf(answer: RoundAfterAnswer, plugin: string): RoundDecision {
  return answer.stop === true ? { stop: true } : { continue: answer.continue, plugin };
}

/** A media item of a changed result as the host reads it: the index of an original item, or a new item. */
type ChangedMedia = number | ToolMedia;

/** The result after the `tool.after` handlers, as the host reads it. */
interface ChangedResult {
  readonly text: string;
  readonly isError: boolean;
  readonly media: readonly ChangedMedia[];
  readonly display: readonly DisplayBlock[];
}

/** What `startToolAfter` gets: the call as for `startToolBefore`, and its result with each media item as its facts. */
interface ToolAfterRequest {
  readonly open: number;
  readonly call: ToolCall;
  readonly result: {
    readonly text: string;
    readonly isError: boolean;
    readonly media: readonly { readonly mimeType: string; readonly size: number }[];
    readonly display: readonly DisplayBlock[];
  };
}

/**
 * Start the `tool.after` handlers of the open session `open` on the result of `call`. The answer is the result after
 * the last handler, or `undefined` when no handler answered. A closed session changes nothing. A failed handler throws.
 * `cancel` aborts the signal of the call.
 */
export function startToolAfter(request: ToolAfterRequest): Operation<ChangedResult | undefined> {
  const { open, call, result: given } = request;
  return hostOperation(async (signal) => {
    frozen(call);
    // The index is the id, and a kept item crosses back to the host as its index.
    const originals: readonly ResultMedia[] = given.media.map((item, index) =>
      Object.freeze({ id: String(index), mimeType: item.mimeType, size: item.size }),
    );
    let result: ToolCallResult = Object.freeze({
      text: given.text,
      isError: given.isError,
      media: Object.freeze([...originals]),
      display: frozen(given.display),
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
      display: result.display,
    };
  }, TURN_CANCELLED);
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
  call: (handler: SessionHooks[K]) => ReturnType<SessionHooks[K]>,
  take: (answer: NonNullable<Awaited<ReturnType<SessionHooks[K]>>>, plugin: string) => boolean,
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
        const answer = await call(handler);
        // A close during the wait ends the turn, so the answer of the closed scope no longer counts.
        if (scope.closed) return;
        if (answer !== undefined && take(answer, scope.plugin)) return;
      } catch (error) {
        throw hookFailure(point, scope.plugin, error);
      }
    }
  }
}

/** `result` after the `tool.after` answer `answer`. An item of `originals` stays as it is. */
function applied(result: ToolCallResult, answer: ToolAfterAnswer, originals: readonly ResultMedia[]): ToolCallResult {
  return Object.freeze({
    text: answer.text ?? result.text,
    isError: answer.isError ?? result.isError,
    media:
      answer.media === undefined
        ? result.media
        : Object.freeze(
            answer.media.map((item) =>
              item.id !== undefined
                ? keptOf(item, originals)
                : Object.freeze(
                    item.path !== undefined
                      ? { mimeType: item.mimeType, path: item.path }
                      : { mimeType: item.mimeType, bytes: new Uint8Array(item.bytes) },
                  ),
            ),
          ),
    display: answer.display === undefined ? result.display : frozen(answer.display.map((block) => ({ ...block }))),
  });
}

/** The item of `originals` that the answer item `value` keeps by its `id`. */
function keptOf(value: KeptMedia, originals: readonly ResultMedia[]): ResultMedia {
  return originals.find((item) => item.id === value.id) as ResultMedia;
}

/** The error of a `point` handler of `plugin` that failed with `error`. It keeps the stack of `error`. */
function hookFailure(point: string, plugin: string, error: unknown): Error {
  const failure = new Error(`${point} of plugin ${plugin} failed: ${textOf(error)}`);
  // The stack of the host code tells the author nothing.
  const stack = stackOf(error);
  if (stack !== undefined) failure.stack = stack;
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

/** The value that a failed request rejects with, from the record of the native, or `error` as it is. */
function requestFailureOf(error: unknown, signal: AbortSignal): unknown {
  if (typeof error !== "object" || error === null || error instanceof Error) return error;
  const record = error as Readonly<Record<string, unknown>>;
  if (record.cancelled === true) return signal.reason;
  const message = String(record.message);
  if (typeof record.code !== "number") return new Error(message);
  return new ExtensionRequestError(message, { code: record.code, data: record.data });
}

/** Run `session(s)` of the plugin of `entry` in its own scope. */
function start(
  open: number,
  sessionId: string,
  folder: string,
  ask: Ask,
  send: SendRequest,
  model: () => ModelReference,
  entry: (typeof sessionExports)[number],
): Scope {
  const { plugin, session, options } = entry;
  const { signal, abort } = hostSignal();
  // The end of the scope and an abort of `stop` end a wait of the plugin.
  const endedBy = (stop: AbortSignal | undefined): AbortSignal => {
    const caller = signalOf(stop);
    return caller === undefined ? signal : AbortSignal.any([signal, caller]);
  };
  // An ended wait closes the question, and it answers `undefined`.
  const question = async <T extends boolean | string>(
    asked: Question,
    stop: AbortSignal | undefined,
  ): Promise<T | undefined> => {
    const ended = endedBy(stop);
    if (ended.aborted) return undefined;
    // The host answers with the type of the kind of the question.
    return (await underSignal(ended, () => ask(plugin, asked))) as T | undefined;
  };
  const report = (message: string): void => notify(plugin, "error", message, sessionId);
  const clean = async (cleanup: Cleanup): Promise<void> => {
    try {
      await cleanup();
    } catch (error) {
      report(`the cleanup of the session failed: ${failureOf(error)}`);
    }
  };
  const scope: Scope = {
    plugin,
    closed: false,
    abort,
    tools: [],
    hooks: {
      "input.before": [],
      "round.before": [],
      "round.retry": [],
      "prompt.build": [],
      "tool.before": [],
      "tool.after": [],
      "round.after": [],
    },
    settled: Promise.resolve(undefined),
    clean,
  };
  const s: SessionContext<Options> = Object.freeze({
    sessionId,
    folder,
    get model(): ModelReference {
      return Object.freeze(model());
    },
    options,
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
    emit(event: string, data?: unknown): void {
      emit(plugin, String(event), JSON.stringify(data) ?? "null", sessionId);
    },
    async request(request: string, data?: unknown, options?: RequestOptions): Promise<unknown> {
      const text = JSON.stringify(data) ?? "null";
      const ended = endedBy(options?.signal);
      ended.throwIfAborted();
      const start = (): Operation<unknown> =>
        responder === undefined
          ? send(plugin, String(request), text)
          : responder(
              Object.freeze({ sessionId, extension: plugin, request: String(request), data: JSON.parse(text) }),
            );
      try {
        return await underSignal(ended, start);
      } catch (error) {
        throw requestFailureOf(error, ended);
      }
    },
    confirm(title: string, message?: string, options?: AskOptions): Promise<boolean | undefined> {
      return question<boolean>({ kind: "confirm", title, message: message ?? "" }, options?.signal);
    },
    select(title: string, choices: readonly string[], options?: AskOptions): Promise<string | undefined> {
      if (choices.length === 0) return Promise.reject(new TypeError("select: choices is empty"));
      if (new Set(choices).size !== choices.length) {
        return Promise.reject(new TypeError("select: choices has a choice twice"));
      }
      return question<string>({ kind: "select", title, options: [...choices] }, options?.signal);
    },
    input(title: string, options?: InputOptions): Promise<string | undefined> {
      const { placeholder, secret, signal: stop } = options ?? {};
      return question<string>({ kind: "input", title, placeholder, secret: secret ?? false }, stop);
    },
  });
  scope.settled = (async () => {
    try {
      const result: unknown = await session(s);
      if (result !== undefined && typeof result !== "function") {
        throw new TypeError("session must return nothing or a cleanup function");
      }
      return result as Cleanup | undefined;
    } catch (error) {
      // The close owns the scope, so a failure after the close needs no rollback.
      if (scope.closed) return undefined;
      scope.closed = true;
      unregister(scope.tools);
      abort(`session of plugin ${plugin} failed`);
      report(`the session setup failed, and its tools and hooks are gone: ${failureOf(error)}`);
      return undefined;
    }
  })();
  return scope;
}
