import { checkArguments, checkParameters } from "yuke:internal/arguments";
import { defineTool, fieldsOf, jsonCopy, mediaOf } from "yuke:internal/define";
import { addAbortStep, hostOperation, hostSignal, signalOf, underStop } from "yuke:internal/events";
import { failureOf, stackOf, textOf } from "yuke:internal/failure";
import { notify, type Operation, type RoundNatives, unregister } from "yuke:internal/native";
import type {
  AskOptions,
  Cleanup,
  FinishReason,
  InputKind,
  InputOptions,
  InputSource,
  NoticeLevel,
  PluginContext,
  PluginSession,
  ResultMedia,
  RoundAfterEvent,
  RoundBeforeEvent,
  RoundFailure,
  Services,
  SessionContext,
  SessionHooks,
  SideRequestOptions,
  SideRequestResult,
  ToolCall,
  ToolCallResult,
} from "yuke:plugins";
import type { Block, ModelReference } from "yuke:protocol";
import type { ObjectSchema, Tool, ToolMedia } from "yuke:tools";

/** One plugin as the host gives it. The host checked the manifest, the order, and the providers before any plugin code. */
interface PluginSpec {
  readonly name: string;
  /** The folder of the plugin, or `undefined` for a bundled plugin. */
  readonly root: string | undefined;
  readonly dataDir: string;
  /** The options of `config.json`. They are `{}` when the user gives none. */
  readonly options: Readonly<Record<string, unknown>>;
  /** The absolute path or the `yuke:` name of the entry module, or `undefined` for a plugin without code. */
  readonly entry: string | undefined;
  readonly uses: readonly string[];
  readonly provides: readonly string[];
}

/**
 * The context of a bundled plugin: a `PluginContext` without `root`, because a bundled plugin has no folder. Only yuke
 * writes bundled plugins, so the public `PluginContext` keeps `root` a string.
 */
export type BundledContext = Omit<PluginContext<Options>, "root">;

/** The type of the options in the loader. */
type Options = Readonly<Record<string, unknown>>;

/**
 * Check the options `given` against `schema`, the `optionsSchema` export, and return them frozen. A plugin without a
 * schema takes no options.
 */
function optionsOf(given: Options, schema: unknown): Options {
  if (schema === undefined) {
    if (Object.keys(given).length > 0) {
      throw new TypeError("config.json gives options, and the plugin exports no optionsSchema");
    }
    return Object.freeze({});
  }
  checkParameters(schema, "optionsSchema");
  try {
    return frozen(checkArguments(schema, given));
  } catch (error) {
    // The check throws an `Error` whose message says what to change.
    throw new TypeError(`the options of config.json: ${(error as Error).message}`);
  }
}

/** The services of the loaded plugins. A service enters only after its provider's `apply` succeeds. */
const services = new Map<string, unknown>();

/** Set at the start of the close of the plugins. A later load fails, so the close misses no plugin. */
let closing = false;

/** Each loaded plugin, in load order: the abort of its signal and the cleanup of its `apply`. */
const loaded: { readonly plugin: string; readonly abort: (reason: string) => void; readonly cleanup?: Cleanup }[] = [];

/** The `session` export of each loaded plugin, in load order. */
const sessionExports: {
  readonly plugin: string;
  readonly session: PluginSession<Options>;
  readonly options: Options;
}[] = [];

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
  settled: Promise<Cleanup | undefined>;
  /** Run `cleanup`. A failure is a notice. */
  readonly clean: (cleanup: Cleanup) => Promise<void>;
}

/** The scopes of each open session, by the open number of the host. */
const opens = new Map<number, { readonly scopes: readonly Scope[]; readonly ready: Promise<void> }>();

/**
 * Load the plugin `spec`: import its entry, check its exports, and await `apply(ctx)`. A failure aborts the signal of
 * the plugin and throws. Only a loaded plugin runs `session`.
 */
export async function load(spec: PluginSpec): Promise<void> {
  if (closing) throw new TypeError(`plugin ${spec.name} loads after the close of the plugins`);
  const { signal, abort } = hostSignal();
  const pending = new Map<string, unknown>();
  let applying = true;
  let cleanup: Cleanup | undefined;
  try {
    let apply: unknown;
    let session: PluginSession<Options> | undefined;
    let optionsSchema: unknown;
    if (spec.entry !== undefined) {
      const exports = (await import(spec.entry)) as {
        readonly apply?: unknown;
        readonly session?: unknown;
        readonly optionsSchema?: unknown;
      };
      if (exports.apply === undefined && exports.session === undefined) {
        throw new TypeError(`${spec.entry} exports neither apply nor session: a plugin entry exports one or both`);
      }
      if (exports.apply !== undefined && typeof exports.apply !== "function") {
        throw new TypeError("the apply export is no function");
      }
      if (exports.session !== undefined && typeof exports.session !== "function") {
        throw new TypeError("the session export is no function");
      }
      apply = exports.apply;
      session = exports.session as PluginSession<Options> | undefined;
      optionsSchema = exports.optionsSchema;
    }
    const options = optionsOf(spec.options, optionsSchema);
    // A bundled plugin has no folder, so its context has no `root`.
    const ctx: BundledContext & { readonly root?: string } = Object.freeze({
      name: spec.name,
      ...(spec.root === undefined ? {} : { root: spec.root }),
      dataDir: spec.dataDir,
      options,
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
    if (typeof apply === "function") {
      const result: unknown = await apply(ctx);
      if (result !== undefined && typeof result !== "function") {
        throw new TypeError("apply must return nothing or a cleanup function");
      }
      cleanup = result as Cleanup | undefined;
    }
    applying = false;
    if (closing) throw new TypeError(`plugin ${spec.name} loads after the close of the plugins`);
    const missing = spec.provides.filter((name) => !pending.has(name));
    if (missing.length > 0) throw new TypeError(`apply did not provide ${missing.join(", ")} of provides`);
    for (const [name, value] of pending) services.set(name, value);
    if (session !== undefined) sessionExports.push({ plugin: spec.name, session, options });
    loaded.push(cleanup === undefined ? { plugin: spec.name, abort } : { plugin: spec.name, abort, cleanup });
  } catch (error) {
    applying = false;
    abort(`plugin ${spec.name} did not load`);
    if (cleanup !== undefined) await clean(spec.name, cleanup);
    throw error;
  }
}

/**
 * Close the loaded plugins after each session closed: abort each signal, then await the cleanup of each `apply`, newest
 * plugin first. A failed cleanup sends a notice, and the next cleanup still runs. A second close does nothing.
 */
export async function closePlugins(): Promise<void> {
  closing = true;
  const plugins = loaded.splice(0).reverse();
  for (const { plugin, abort } of plugins) abort(`the runtime of plugin ${plugin} closed`);
  for (const { plugin, cleanup } of plugins) if (cleanup !== undefined) await clean(plugin, cleanup);
}

/** Run the cleanup of the `apply` of `plugin`. A failure is a notice. */
async function clean(plugin: string, cleanup: Cleanup): Promise<void> {
  try {
    await cleanup();
  } catch (error) {
    notify(plugin, "error", `the cleanup of the plugin failed: ${failureOf(error)}`, undefined);
  }
}

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
 * What `openSession` gets: the open number of the host, the id of the session, its workspace folder, and the natives
 * of the session.
 */
interface OpenRequest {
  readonly open: number;
  readonly sessionId: string;
  readonly folder: string;
  readonly ask: Ask;
  /** The model that the settings of the session name now. */
  readonly model: () => ModelReference;
}

/**
 * Start `session(s)` of each loaded plugin for the session of `request`. Each call starts before any of them settles.
 * The open does not wait for them; `ready(open)` does.
 */
export function openSession(request: OpenRequest): void {
  const { open, sessionId, folder, ask, model } = request;
  const scopes = sessionExports.map((entry) => start(open, sessionId, folder, ask, model, entry));
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
        current = sectionsOf(answer);
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
        reason = blockOf(answer);
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

/** The fields of an `input.before` answer. */
const INPUT_BEFORE_FIELDS = ["block", "replace", "handled"];

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
          const fields = fieldsOf(answer, "the answer", INPUT_BEFORE_FIELDS);
          if (INPUT_BEFORE_FIELDS.filter((name) => Object.hasOwn(fields, name)).length !== 1) {
            throw new TypeError("the answer needs exactly one of block, replace, and handled");
          }
          if (Object.hasOwn(fields, "block")) {
            if (typeof fields.block !== "string") throw new TypeError("the block of the answer is not a string");
            notify(plugin, "warn", `the plugin blocked the input: ${fields.block}`, sessionId);
            removed = true;
            return true;
          }
          if (Object.hasOwn(fields, "handled")) {
            if (fields.handled !== true) throw new TypeError("the handled of the answer is not true");
            removed = true;
            return true;
          }
          if (Object.hasOwn(fields, "replace")) {
            const { blocks: given } = fieldsOf(fields.replace, "the replace of the answer", ["blocks"]);
            if (!Array.isArray(given) || given.length === 0) {
              throw new TypeError("the blocks of the replace are not a list with a block");
            }
            current = given.map((item: unknown, index) =>
              typeof item === "object" && item !== null && "mimeType" in item
                ? mediaOf(item, `blocks[${index}]`)
                : jsonCopy(item as Block, "the answer"),
            );
            replaced = true;
          }
          return false;
        },
      );
    } catch (error) {
      // A failed check never lets the input through.
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

/** The fields of a `round.before` or a `round.retry` answer. */
const ROUND_BEFORE_FIELDS = ["replace", "model", "settings"];

/** The names of the options of `sideRequest`. */
const SIDE_OPTIONS = ["prompt", "blocks", "maxOutputTokens", "abortSignal"];

/** The largest output limit that the host takes. */
const MAX_OUTPUT_TOKENS = 2 ** 32 - 1;

/** Send the side request of `round` for a handler that sees `head`, then the last `kept` blocks of the round. */
async function sideRequest(
  round: RoundNatives,
  head: readonly Block[],
  kept: number,
  options: SideRequestOptions,
): Promise<SideRequestResult> {
  const {
    prompt,
    blocks = head.length + kept,
    maxOutputTokens,
    abortSignal,
  } = fieldsOf(options, "the options", SIDE_OPTIONS);
  if (typeof prompt !== "string") throw new TypeError("the option prompt is not a string");
  const total = head.length + kept;
  if (typeof blocks !== "number" || !Number.isSafeInteger(blocks) || blocks < 0 || blocks > total) {
    throw new TypeError(`the option blocks is not a whole number from 0 to ${total}`);
  }
  if (
    maxOutputTokens !== undefined &&
    (typeof maxOutputTokens !== "number" ||
      !Number.isSafeInteger(maxOutputTokens) ||
      maxOutputTokens < 1 ||
      maxOutputTokens > MAX_OUTPUT_TOKENS)
  ) {
    throw new TypeError(`the option maxOutputTokens is not a whole number from 1 to ${MAX_OUTPUT_TOKENS}`);
  }
  const stop = signalOf(abortSignal);
  const request = { head: jsonCopy(head, "the answer"), kept, blocks, prompt, maxOutputTokens };
  return Object.freeze(await underStop(stop, () => round.sideRequest(request)));
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
        return (handler as (event: EventOf<K>) => unknown)(event);
      },
      (answer, plugin) => {
        const fields = fieldsOf(answer, "the answer", ROUND_BEFORE_FIELDS);
        if (fields.replace !== undefined) {
          const replace = fieldsOf(fields.replace, "the replace of the answer", ["head", "keep"]);
          if (!Array.isArray(replace.head)) throw new TypeError("the head of the replace is not an array");
          const { keep } = replace;
          if (typeof keep !== "number" || !Number.isSafeInteger(keep) || keep < 0) {
            throw new TypeError("the keep of the replace is not a whole number");
          }
          const given = jsonCopy(replace.head as Block[], "the answer");
          // A keep past the kept blocks also keeps the end of the earlier head.
          const keeps = Math.min(keep, head.length + kept);
          head = keeps <= kept ? given : [...given, ...head.slice(head.length - (keeps - kept))];
          kept = Math.min(kept, keeps);
          plan.replace = { plugin, head, keep: kept };
        }
        if (fields.model !== undefined) {
          const { provider, model } = fieldsOf(fields.model, "the model of the answer", ["provider", "model"]);
          if (typeof provider !== "string" || typeof model !== "string") {
            throw new TypeError("the model of the answer needs a provider and a model text");
          }
          plan.model = { plugin, provider, model };
        }
        if (fields.settings !== undefined) {
          const { settings } = fields;
          if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
            throw new TypeError("the settings of the answer are not an object");
          }
          plan.settings = { plugin, changes: { ...plan.settings?.changes, ...jsonCopy(settings, "the answer") } };
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

/** The fields of a `round.after` answer. */
const ROUND_FIELDS = ["stop", "continue"];

/** What the host reads of a `round.after` answer: a stop, or the text of a continue and the plugin that sent it. */
type RoundDecision = { readonly stop: true } | { readonly continue: string; readonly plugin: string };

/** The checked `round.after` answer of `plugin`. Another shape throws a `TypeError`. */
function roundOf(answer: unknown, plugin: string): RoundDecision {
  const fields = fieldsOf(answer, "the answer", ROUND_FIELDS);
  if (Object.hasOwn(fields, "stop") === Object.hasOwn(fields, "continue")) {
    throw new TypeError("the answer needs exactly one of stop and continue");
  }
  if (Object.hasOwn(fields, "stop")) {
    if (fields.stop !== true) throw new TypeError("the stop of the answer is not true");
    return { stop: true };
  }
  if (typeof fields.continue !== "string") throw new TypeError("the continue of the answer is not a string");
  if (fields.continue === "") throw new TypeError("the continue of the answer is empty");
  return { continue: fields.continue, plugin };
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

/** `value` with each object in it frozen. A JSON value has no cycle. */
function frozen<T>(value: T): T {
  // A typed array with items cannot freeze, so the bytes of a `ToolMedia` stay as they are.
  if (typeof value === "object" && value !== null && !ArrayBuffer.isView(value)) {
    for (const inner of Object.values(value)) frozen(inner);
    Object.freeze(value);
  }
  return value;
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

/** Run `session(s)` of the plugin of `entry` in its own scope. */
function start(
  open: number,
  sessionId: string,
  folder: string,
  ask: Ask,
  model: () => ModelReference,
  entry: (typeof sessionExports)[number],
): Scope {
  const { plugin, session, options } = entry;
  const { signal, abort } = hostSignal();
  // The end of the scope and an abort of `stop` close the question, and it answers `undefined`.
  const question = async <T extends boolean | string>(
    asked: Question,
    stop: AbortSignal | undefined,
  ): Promise<T | undefined> => {
    if (scope.closed || signalOf(stop)?.aborted) return undefined;
    const { promise, cancel } = ask(plugin, asked);
    const removes = [addAbortStep(signal, cancel)];
    if (stop !== undefined) removes.push(addAbortStep(stop, cancel));
    try {
      // The host answers with the type of the kind of the question.
      return (await promise) as T | undefined;
    } finally {
      for (const remove of removes) remove();
    }
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
