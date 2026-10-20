/**
 * The plugin API. The entry module of a plugin exports `apply`, `session`, or both.
 * - `apply(ctx)` runs once per runtime, for the parts that every session shares.
 * - `session(s)` runs once per session, for the tools and hooks of that session.
 * - The declarations need TypeScript 5.4 or later.
 *
 * Errors:
 * - A misuse of the API throws a `TypeError`.
 * - A cancellation aborts a signal with a `DOMException` named `AbortError`.
 * - A tool that throws, or a result with `isError: true`, gives the model an error result.
 * - A notice only informs the user. It fails no tool and no turn.
 */
import type { ObjectSchema, Tool, ToolMedia } from "yuke:tools";

/** The severity of a notice. */
export type NoticeLevel = "debug" | "info" | "warn" | "error";

/**
 * The services of the plugins, by name. A provider ships a declaration file that adds its service to this interface:
 * `declare module "yuke:plugins" { interface Services { "acme.notes.v1": Notes } }`. Each plugin that uses the service
 * includes that file. A name without a declaration fails the type check.
 */
// biome-ignore lint/suspicious/noEmptyInterface: each provider adds its service to this interface.
export interface Services {}

/** What `apply` of a plugin gets. */
export interface PluginContext {
  /** The name of the plugin, from its `plugin.json`. */
  readonly name: string;
  /** The absolute folder of the plugin. */
  readonly root: string;
  /** The absolute data folder of the plugin. It exists, and it stays across reloads. */
  readonly dataDir: string;
  /**
   * The host aborts this signal when the plugin fails to load. The plugin must then clear its timers, because the host
   * does not clear them. A shutdown stops the JavaScript without an abort.
   */
  readonly signal: AbortSignal;
  /** Publish the service `name` once, during `apply`. The value is not null or undefined. `name` must be in `provides`. */
  readonly provide: <K extends keyof Services & string>(name: K, value: NonNullable<Services[NoInfer<K>]>) => void;
  /** The service `name` of an earlier plugin, never null. `name` must be in `uses` of the manifest. */
  readonly get: <K extends keyof Services & string>(name: K) => NonNullable<Services[K]>;
  /** Send a notice with this plugin as its source. */
  readonly notify: (level: NoticeLevel, message: string) => void;
}

/** What a `prompt.build` handler gets. */
export interface PromptBuildEvent {
  /** The system prompt sections of the turn, by key, in order, after the answers of the handlers before. */
  readonly sections: Readonly<Record<string, string>>;
  /**
   * The host aborts this signal when the turn is cancelled. After the abort, the host does not wait for the handler,
   * and it ignores the answer of the handler.
   */
  readonly signal: AbortSignal;
}

/** The answer of a `prompt.build` handler that changes the system prompt. */
export interface PromptBuildAnswer {
  /**
   * The new sections, by key. Their order is the order of the prompt. Each key matches `^[a-z][a-z0-9_-]*$`, and each
   * text is a string. The model reads each section between `<key>` and `</key>`, except `base`. An empty text adds
   * nothing.
   */
  readonly sections: Readonly<Record<string, string>>;
}

/** One tool call of the model. */
export interface ToolCall {
  /** The id of the call, from the model. */
  readonly id: string;
  /** The name of the tool. A call of a deferred tool through `tool_call` has the name of the deferred tool. */
  readonly name: string;
  /**
   * The arguments of the call: the parsed JSON of the model, frozen at each depth. A call of a deferred tool through
   * `tool_call` has the arguments of the deferred tool. The host checks them against the schema of the tool only after
   * the hooks, so check their shape before a use. A change throws a `TypeError`, because the call runs with the
   * arguments of the model. A JSON number becomes a JavaScript number, so an integer above 2^53 loses precision.
   */
  readonly arguments: unknown;
}

/** A media item that the result had before the `tool.after` handlers. The bytes stay in the host. */
export interface ResultMedia {
  /** The id of the item in this result. It is opaque: a `KeptMedia` uses it to keep the item. */
  readonly id: string;
  /** The media type, for example `image/png`. */
  readonly mimeType: string;
  /** The size of the bytes. */
  readonly size: number;
}

/** An item of a `tool.after` answer that keeps the `ResultMedia` with its `id`. A copy of that item is one. */
export interface KeptMedia {
  readonly id: string;
  /** When present, it equals the media type of the kept item. */
  readonly mimeType?: string | undefined;
  /** When present, it equals the size of the kept item. */
  readonly size?: number | undefined;
  readonly path?: never;
  readonly bytes?: never;
}

/** The result of one tool call. */
export interface ToolCallResult {
  /** The text for the model. */
  readonly text: string;
  /** `true` when the result is an error. */
  readonly isError: boolean;
  /** The media items: the items of the tool, and the new items of the answers before. */
  readonly media: readonly (ResultMedia | ToolMedia)[];
}

/** What a `tool.before` handler gets. */
export interface ToolBeforeEvent {
  readonly call: ToolCall;
  /**
   * The host aborts this signal when the turn is cancelled. After the abort, the host does not wait for the handler,
   * and it ignores the answer of the handler.
   */
  readonly signal: AbortSignal;
}

/** The answer of a `tool.before` handler that stops the call. */
export interface ToolBeforeAnswer {
  /** Why the call does not run. The model gets this text as the error result of the call. */
  readonly block: string;
}

/** What a `tool.after` handler gets. */
export interface ToolAfterEvent {
  readonly call: ToolCall;
  /** The result after the answers of the handlers before. */
  readonly result: ToolCallResult;
  /**
   * The host aborts this signal when the turn is cancelled. After the abort, the host does not wait for the handler,
   * and it ignores the answer of the handler.
   */
  readonly signal: AbortSignal;
}

/** The answer of a `tool.after` handler that changes the result. A field that is not `undefined` replaces its value. */
export interface ToolAfterAnswer {
  readonly text?: string | undefined;
  readonly isError?: boolean | undefined;
  /**
   * The new media list. A `KeptMedia` keeps an item of the result, and a `ToolMedia` adds a new item. A relative path
   * starts in the workspace folder of the session.
   */
  readonly media?: readonly (KeptMedia | (ToolMedia & { readonly id?: never }))[] | undefined;
}

/** Why a model answer ended: the name of the provider reason, in snake case. */
export type FinishReason = "stop" | "length" | "content_filter" | "refusal" | "tool_calls" | "pause" | "unknown";

/** What a `round.after` handler gets. */
export interface RoundAfterEvent {
  /** The assistant text of the answer of this round. It can be empty, for example for an answer with calls only. */
  readonly text: string;
  /**
   * Why the answer ended, when it needs no other request. `null` after a round of tool calls, because the turn then
   * goes on.
   */
  readonly finishReason: FinishReason | null;
  /** The `continue` answers of the `round.after` handlers in this turn. The host sets no limit, so guard a loop here. */
  readonly continues: number;
  /**
   * The host aborts this signal when the turn is cancelled. After the abort, the host does not wait for the handler,
   * and it ignores the answer of the handler.
   */
  readonly signal: AbortSignal;
}

/**
 * The answer of a `round.after` handler.
 * - `{ stop: true }` ends the turn. The input that the user sent during the turn stays for the next turn.
 * - `{ continue }` gives the session the text as a notification of the plugin, and the turn goes on with it. The user
 *   sees the text as a notice of the plugin. The model reads it in `<system_notification plugin="name">`.
 * - Input that the user sent during the turn goes with the text in the same request. The text is not empty.
 */
export type RoundAfterAnswer =
  | { readonly stop: true; readonly continue?: never }
  | { readonly continue: string; readonly stop?: never };

/**
 * The hooks of a session, by point.
 * - Each handler gets one frozen event, and the host awaits it.
 * - The handler returns `undefined` for no change, or an answer.
 * - A throw, or an answer of another shape, is a failure of the handler. Its error names the point and the plugin.
 */
export interface SessionHooks {
  /**
   * Change the system prompt of a turn.
   * - The handlers run once before each turn, after `session` of each plugin settles.
   * - Each handler gets the sections after the answers of the handlers before it.
   * - When a handler fails, the host sends a notice and starts no turn. The input stays pending until the next input.
   * - The answers are for that turn only.
   * - A text that changes at each turn makes each turn miss the prompt cache of the provider.
   */
  "prompt.build": (event: PromptBuildEvent) => undefined | PromptBuildAnswer | Promise<undefined | PromptBuildAnswer>;
  /**
   * Decide whether a tool call runs.
   * - The handlers run before each call, in call order.
   * - They run in order until one answers. The call then does not run, and the turn goes on.
   * - A failed handler also stops the call, so a failed check never lets a call run.
   */
  "tool.before": (event: ToolBeforeEvent) => undefined | ToolBeforeAnswer | Promise<undefined | ToolBeforeAnswer>;
  /**
   * Change the result of a tool call before the model reads it.
   * - The handlers run after each call that started, also after a failed call and a call of an unknown tool.
   * - A call that `tool.before` stopped gets no `tool.after`.
   * - Each handler gets the result after the answers of the handlers before it.
   * - A failed handler makes the result an error without media, so it never shows the original result.
   * - A cancel during the handlers keeps the original result.
   * - The handlers of two calls can run at the same time.
   */
  "tool.after": (event: ToolAfterEvent) => undefined | ToolAfterAnswer | Promise<undefined | ToolAfterAnswer>;
  /**
   * Decide whether the turn goes on after a model answer.
   * - The handlers run after each round: after a final answer, and after the results of the calls of an answer.
   * - They run in order until one answers.
   * - A failed handler ends the turn with its error. The round stays in the context.
   */
  "round.after": (event: RoundAfterEvent) => undefined | RoundAfterAnswer | Promise<undefined | RoundAfterAnswer>;
}

/** The options of a question to the user. */
export interface AskOptions {
  /** An abort of this signal closes the question, and the question answers `undefined`. */
  readonly signal?: AbortSignal | undefined;
}

/** The options of `input`. */
export interface InputOptions extends AskOptions {
  /** The text that an empty field shows. */
  readonly placeholder?: string | undefined;
  /** The field hides what the user types, as for a password. */
  readonly secret?: boolean | undefined;
}

/** What `session` of a plugin gets for one session. */
export interface SessionContext {
  /** The id of the session. */
  readonly sessionId: string;
  /** The workspace folder of the session at its open. A tool reads the folder of each call from its context. */
  readonly folder: string;
  /** The host aborts this signal when the session closes or `session` of this plugin fails. The plugin then stops. */
  readonly signal: AbortSignal;
  /** The tools of the plugin in this session. They stay until their removal or the close of the session. */
  readonly tools: {
    /**
     * Define `tool` for this session. `execute` gets the arguments with the types of `parameters`.
     * - The returned function removes the tool: the next turn does not have it, and a call of it fails.
     * - A change of the tools makes the next turn miss the prompt cache of the provider.
     */
    readonly define: <const S extends ObjectSchema>(tool: Tool<S>) => () => void;
  };
  /**
   * Add `handler` to the hook `point` of this session. The handlers of a point run in plugin order, then in the order
   * of their addition. The returned function removes the handler. An addition or a removal during a run of the point
   * changes the next run.
   */
  readonly hook: <K extends keyof SessionHooks>(point: K, handler: SessionHooks[K]) => () => void;
  /** Send a notice of this session with this plugin as its source. */
  readonly notify: (level: NoticeLevel, message: string) => void;
  /**
   * Ask the user a yes or no question with this plugin as its source, and wait for the answer.
   * - The answer is `undefined` when the user cancels, the signal aborts, the session closes, or no client can answer,
   *   as in `yuke -p`.
   * - The turn waits while a hook or a tool waits for the answer. Pass the signal of the hook or the tool, so that a
   *   cancel of the turn closes the question.
   */
  readonly confirm: (title: string, message?: string, options?: AskOptions) => Promise<boolean | undefined>;
  /**
   * Ask the user to choose one of `choices`, and wait for the answer. `choices` is not empty, and each choice is unique.
   * The answer is `undefined` as for `confirm`.
   */
  readonly select: (title: string, choices: readonly string[], options?: AskOptions) => Promise<string | undefined>;
  /** Ask the user for one line of text, and wait for the answer. The answer is `undefined` as for `confirm`. */
  readonly input: (title: string, options?: InputOptions) => Promise<string | undefined>;
}

/** The `apply` export of the entry module. It runs once per runtime. */
export type PluginApply = (ctx: PluginContext) => undefined | Promise<undefined>;

/** What `session` can return: the work that the close of the session awaits. */
export type SessionCleanup = () => void | Promise<void>;

/**
 * The `session` export of the entry module. It runs once per session.
 * - The open of the session does not wait for it. The first request for the tools of the session waits for it.
 * - A throw removes its tools and aborts its signal.
 * - The close of the session waits for it to settle, so it must end when its signal aborts.
 */
export type PluginSession = (s: SessionContext) => undefined | SessionCleanup | Promise<undefined | SessionCleanup>;
