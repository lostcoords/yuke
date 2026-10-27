/**
 * The plugin API. The entry module of a plugin exports `apply`, `session`, or both.
 * - `apply(ctx)` runs once per runtime, for the parts that every session shares.
 * - `session(s)` runs once per session, for the tools and hooks of that session.
 * - `optionsSchema` is the `ObjectSchema` of the options that the user gives in `config.json`. Without it, the plugin
 *   takes no options. Type the contexts with `PluginContext<Infer<typeof optionsSchema>>`.
 * - The declarations need TypeScript 5.4 or later.
 *
 * Errors:
 * - A misuse of the API throws a `TypeError`.
 * - A cancellation aborts a signal with a `DOMException` named `AbortError`.
 * - A tool that throws, or a result with `isError: true`, gives the model an error result.
 * - A notice only informs the user. It fails no tool and no turn.
 */
import type {
  Block,
  EventNumber,
  FinishReason,
  InputId,
  InputKind,
  InputSource,
  InteractionId,
  InteractionResponse,
  Job,
  ListCatalogResult,
  ListSessionsParams,
  ListSessionsResult,
  McpServer,
  ModelReference,
  NoticeLevel,
  SessionId,
  SessionRow,
  SessionSettings,
  SessionSnapshot,
  SessionUpdate,
  Settings,
  StoredEvent,
  Usage,
} from "yuke:protocol";
import type { ObjectSchema, Tool, ToolMedia } from "yuke:tools";

import type { Tui } from "yuke:tui";

export type {
  Block,
  EventNumber,
  FinishReason,
  InputId,
  InputKind,
  InputSource,
  InteractionId,
  InteractionResponse,
  Job,
  ListCatalogResult,
  ListSessionsParams,
  ListSessionsResult,
  McpServer,
  ModelReference,
  NoticeLevel,
  SessionId,
  SessionRow,
  SessionSettings,
  SessionSnapshot,
  SessionUpdate,
  Settings,
  StoredEvent,
  Usage,
} from "yuke:protocol";

/**
 * The services of the plugins, by name. A provider ships a declaration file that adds its service to this interface:
 * `declare module "yuke:plugins" { interface Services { "acme.notes.v1": Notes } }`. Each plugin that uses the service
 * includes that file. A name without a declaration fails the type check. Three services belong to yuke itself and
 * need no `uses` entry:
 * - `tui`: the terminal interface, or `undefined` in `yuke --rpc` and `yuke -p`.
 * - `sessions`: the sessions, in each mode.
 * - `catalog`: the providers and their models, in each mode.
 */
export interface Services {
  readonly tui: Tui | undefined;
  readonly sessions: Sessions;
  readonly catalog: Catalog;
}

/**
 * The sessions of yuke. A session that a plugin creates is an ordinary session: each client sees it, can load it, and
 * can send it input. A failed request rejects with an `Error` that tells why.
 */
export interface Sessions {
  /** Create a session with `settings`, and open it. It closes by itself when nothing holds it and it has no work. */
  readonly create: (settings: SessionSettings) => Promise<SessionId>;
  /** Fork session `id` through the event `through`, or through its last event, and open the fork. */
  readonly fork: (id: SessionId, through?: EventNumber) => Promise<SessionId>;
  /** A page of the saved sessions, newest first. `nextCursor` continues the list. */
  readonly list: (params?: ListSessionsParams) => Promise<ListSessionsResult>;
  /** The row of the saved session `id`, with its activity now. */
  readonly get: (id: SessionId) => Promise<SessionRow>;
  /** Delete the saved session `id`. An open session cannot be removed. */
  readonly remove: (id: SessionId) => Promise<void>;
  /**
   * Open session `id`, also a closed one, and hold it: it does not close by itself until the handle ends. The handle
   * starts with a snapshot of the session. `options.update` then gets each later update, in order.
   */
  readonly open: (id: SessionId, options: OpenOptions) => Promise<SessionHandle>;
  /** At most `page.limit` saved events of session `id` before the event `page.before`, or its last ones, in order. */
  readonly events: (id: SessionId, page: EventsPage) => Promise<readonly StoredEvent[]>;
  /**
   * Close session `id` at once for each holder, and end each handle on it. A close with running jobs fails unless
   * `options.stopJobs` is true. A cleanup of the session must not await the close of its own session.
   */
  readonly close: (id: SessionId, options?: { readonly stopJobs?: boolean }) => Promise<void>;
}

/** How `Sessions.open` watches a session. */
export interface OpenOptions {
  /** The number of the last saved events in the snapshot. */
  readonly tail: number;
  /** Ends the handle: `update` gets no more calls, and the hold ends. The session stays open for its other holders. */
  readonly signal?: AbortSignal;
  /** Gets each update after the snapshot, in order. A throw is a fault of the plugin, and the next update still comes. */
  readonly update: (update: SessionUpdate) => void;
}

/** A page of the saved events of a session. */
export interface EventsPage {
  /** The page ends before this event. Without it, the page holds the last events. */
  readonly before?: EventNumber;
  /** The most events of the page. */
  readonly limit: number;
}

/**
 * An open session that a plugin holds. After the end of the handle, each async request rejects and each sync request
 * throws.
 */
export interface SessionHandle {
  readonly id: SessionId;
  /**
   * Aborts at the end of the handle: by the signal of the open, by the stop of the plugin, or by the close of the
   * session. Its reason tells which.
   */
  readonly signal: AbortSignal;
  /** The session when the handle starts: its settings, its last saved events, and its live state. */
  readonly snapshot: SessionSnapshot;
  /** Send `content` as a message of the user. A turn starts when the session is idle. */
  readonly input: (content: readonly Block[]) => Promise<InputId>;
  /** Send a notification of this plugin: the user sees `display`, and the model reads `text`. */
  readonly notify: (display: string, text: string) => Promise<InputId>;
  /** Cancel the running turn. A session without a turn has nothing to cancel. */
  readonly cancel: () => void;
  /**
   * Wait until the session runs no turn and has handled each input that it accepted before the call, or until its close.
   * A failed turn counts as handled, and its input waits for the next input.
   */
  readonly idle: () => Promise<void>;
  /** Save `settings`. It fails while a turn runs or input waits. */
  readonly setSettings: (settings: SessionSettings) => Promise<void>;
  /** Remove the pending input `inputId`. */
  readonly removeInput: (inputId: InputId) => Promise<void>;
  /** Answer the open question `interactionId`. */
  readonly respond: (interactionId: InteractionId, response: InteractionResponse) => void;
  /** The running background jobs, oldest first. */
  readonly jobs: () => readonly Job[];
  /** Stop the job `jobId`, and wait for its end. */
  readonly stopJob: (jobId: string) => Promise<void>;
  /** The MCP servers of the session and their states. */
  readonly mcpServers: () => readonly McpServer[];
}

/** The providers of the profile and their models. */
export interface Catalog {
  /** Every provider with `options.all`, else only the providers that are ready. */
  readonly list: (options?: { readonly all?: boolean }) => Promise<ListCatalogResult>;
}

/** The value of `ctx.get(name)`: never null, except `tui`, which can be `undefined`. */
export type ServiceOf<K extends keyof Services> = K extends "tui" ? Services[K] : NonNullable<Services[K]>;

/** `T` with each field read-only at each depth, as the host freezes it. */
export type Frozen<T> = T extends readonly (infer U)[]
  ? readonly Frozen<U>[]
  : T extends object
    ? { readonly [K in keyof T]: Frozen<T[K]> }
    : T;

/**
 * What `apply` of a plugin gets. `O` is the type of the options. A plugin without options keeps the default type,
 * `Record<string, never>`.
 */
export interface PluginContext<O = Record<string, never>> {
  /** The name of the plugin, from its `plugin.json`, or the name of a bundled plugin of yuke. */
  readonly name: string;
  /** The absolute folder of the plugin. A bundled plugin of yuke has no folder, and its context has no `root`. */
  readonly root: string;
  /** The absolute data folder of the plugin. It exists, and it stays across reloads. */
  readonly dataDir: string;
  /**
   * The options of `config.json` after the check against `optionsSchema`. They are `{}` when `config.json` gives none.
   * - A field that the schema does not require can be absent. The plugin then picks its value.
   * - A `null` field that the schema does not require counts as absent.
   * - A reload reads the options again.
   */
  readonly options: Frozen<O>;
  /**
   * The host aborts this signal when the plugin fails to load, and when the runtime closes, before the cleanup of
   * `apply`. The plugin must then clear its timers, because the host does not clear them.
   */
  readonly signal: AbortSignal;
  /** Publish the service `name` once, during `apply`. The value is not null or undefined. `name` must be in `provides`. */
  readonly provide: <K extends Exclude<keyof Services & string, "tui">>(
    name: K,
    value: NonNullable<Services[NoInfer<K>]>,
  ) => void;
  /**
   * The service `name`. The service of a plugin must be in `uses` of the manifest and is never null. `get("tui")` gives
   * the terminal interface of this plugin, or `undefined` outside it; it needs no `uses` entry.
   */
  readonly get: <K extends keyof Services & string>(name: K) => ServiceOf<K>;
  /** Send a notice with this plugin as its source. */
  readonly notify: (level: NoticeLevel, message: string) => void;
  /** Send an event of the whole process. See {@link Emit}. */
  readonly emit: Emit;
}

/**
 * Send the event `event` with `data` to the active client of `yuke --rpc`.
 * - The extension of the event is the name of this plugin. A client ignores an extension that it does not know.
 * - `data` follows `JSON.stringify`. A value with no JSON form, such as `undefined`, sends `null`. Put a version in
 *   `data` when its shape changes.
 * - The event is transient. A client that connects later does not get it. With no client, the host drops it.
 */
export type Emit = (event: string, data?: unknown) => void;

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

/** What a `round.before` handler gets. */
export interface RoundBeforeEvent {
  /** The context window of the model of the session in tokens, or `null` when the catalog names none. */
  readonly window: number | null;
  /**
   * The input tokens of the newest answer of the session. It is `null` before an answer, without a provider count, or
   * after a newer replacement.
   */
  readonly inputTokens: number | null;
  /**
   * The estimated input tokens of the context that this handler sees. It adds the estimate of the newest assistant run
   * and each later block to `inputTokens`. Without `inputTokens`, or after an earlier replacement, it sums
   * `blockTokens()`. It needs no copy of the context, so read it in place of a count over `context()`.
   */
  readonly contextTokens: number;
  /** The number of blocks of the context, after the replacements of the earlier handlers of this round. */
  readonly blocks: number;
  /**
   * The estimated tokens of each block of `context()`, in the same order. Text bytes divide by 4 and round up. A tool
   * call counts its name and its arguments. Reasoning counts the larger of its text and its provider state. Each media
   * item adds 1600.
   */
  readonly blockTokens: () => number[];
  /** The blocks of the context, oldest first, after the replacements of the earlier handlers. Each call gives a copy. */
  readonly context: () => Block[];
  /**
   * Send the request of this round with other blocks, and wait for the first answer.
   * - The request has the model, the system prompt, the tools, and the settings of the round.
   * - Its blocks are the first `blocks` blocks of `context()`, then `prompt` as a user block.
   * - It repeats the bytes and the cache marker of the round, so it can reuse the prompt cache of the earlier rounds.
   * - No tool runs, and the session keeps nothing of the request.
   * - A failed request rejects with an `Error`.
   */
  readonly sideRequest: (options: SideRequestOptions) => Promise<SideRequestResult>;
  /**
   * The host aborts this signal when the turn is cancelled. After the abort, the host does not wait for the handler,
   * and it ignores the answer of the handler.
   */
  readonly signal: AbortSignal;
}

/** The options of `sideRequest`. */
export interface SideRequestOptions {
  /** The text of the last user block. The request offers the tools of the round, so tell the model to call none. */
  readonly prompt: string;
  /** The number of the oldest blocks of `context()` to send, from 0 to `event.blocks`. The default sends each block. */
  readonly blocks?: number | undefined;
  /** The output limit of the request in tokens. Without it, the request has the limit of the round. */
  readonly maxOutputTokens?: number | undefined;
  /** An abort stops the request, and the promise rejects with the reason of the signal. */
  readonly abortSignal?: AbortSignal | undefined;
}

/** The answer of `sideRequest`. */
export interface SideRequestResult {
  /** The text of the answer. A call of a tool is not in it. */
  readonly text: string;
  /** Why the answer stopped. A call of a tool stops it with `tool_calls`. */
  readonly finishReason: FinishReason;
  /** The token counts of the request. */
  readonly usage: Usage;
}

/**
 * The answer of a `round.before` handler. Each part is optional.
 * - `replace` makes the context `head`, then the last `keep` blocks of the context. The session keeps the replacement.
 *   A replacement with a tool result without its call before it fails the turn.
 * - `model` sends this round to another model of the catalog. An unknown model fails the turn.
 * - `settings` replaces these settings for this round. Each field replaces its whole value, so a field that a new
 *   `reasoning` leaves out has no value. An unknown field or a value of another shape fails the turn.
 */
export interface RoundBeforeAnswer {
  readonly replace?: { readonly head: readonly Block[]; readonly keep: number } | undefined;
  readonly model?: ModelReference | undefined;
  readonly settings?: Partial<Settings> | undefined;
}

/**
 * The kind of a failure of a round.
 * - The provider kinds come from the status, the error code, or the error message of the provider. `context_overflow`
 *   means that the input does not fit the context window of the model.
 * - `transport`, `protocol`, `response_too_large`, and `incomplete_stream` are failures of the connection or the stream.
 * - `encode` means that yuke could not build the request, for example for a media type that the provider refuses.
 * - `credential` means that yuke could not get a credential, for example after a failed refresh of a login.
 */
export type RoundFailureKind =
  | "context_overflow"
  | "rate_limited"
  | "rate_limit_unknown"
  | "quota_exhausted"
  | "server_error"
  | "timeout"
  | "conflict"
  | "auth_failed"
  | "permission_denied"
  | "bad_status"
  | "provider_failed"
  | "transport"
  | "protocol"
  | "response_too_large"
  | "incomplete_stream"
  | "encode"
  | "credential";

/** Why a round failed. */
export interface RoundFailure {
  readonly kind: RoundFailureKind;
  /** The text of the failure, as the user sees it. */
  readonly message: string;
}

/** What a `round.retry` handler gets: the facts of `round.before` for the failed round, and the failure. */
export interface RoundRetryEvent extends RoundBeforeEvent {
  /** The context window of the model of the failed round in tokens, or `null` when the catalog names none. */
  readonly window: number | null;
  readonly failure: RoundFailure;
  /** The `round.retry` answers that sent this round again. The host sets no limit, so guard a loop here. */
  readonly retries: number;
}

/** The answer of a `round.retry` handler: the plan of the next attempt of the round, as for `round.before`. */
export type RoundRetryAnswer = RoundBeforeAnswer;

/** What an `input.before` handler gets. */
export interface InputBeforeEvent {
  /** Who sent the input. The inputs of yuke itself have plugin names that start with `host:`. */
  readonly source: InputSource;
  /** A message of a person, or a notification, for example the end of a job. */
  readonly kind: InputKind;
  /** The blocks that the model reads, after the replacements of the earlier handlers. */
  readonly blocks: readonly (Block | ToolMedia)[];
  /** The host aborts this signal when the turn is cancelled. */
  readonly signal: AbortSignal;
}

/**
 * The answer of an `input.before` handler. It has exactly one field.
 * - `block` removes the input. A notice shows the reason to the user.
 * - `replace` gives the model these blocks in place of the input. The user still sees the sent input. The list has at
 *   least one item. A `ToolMedia` adds a media item, and its relative path starts in the workspace folder of the session.
 * - `handled` removes the input with no notice, because the plugin acted on it.
 */
export type InputBeforeAnswer =
  | { readonly block: string; readonly replace?: never; readonly handled?: never }
  | {
      readonly replace: { readonly blocks: readonly [Block | ToolMedia, ...(Block | ToolMedia)[]] };
      readonly block?: never;
      readonly handled?: never;
    }
  | { readonly handled: true; readonly block?: never; readonly replace?: never };

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
   * Check an input before a turn takes it: an input of the user, the end of a job, or a `continue` text.
   * - The store saves the input first.
   * - The handlers run when a turn takes the input. A turn takes it at its start, or after a round.
   * - Each handler gets the blocks after the replacements of the handlers before it.
   * - `block` and `handled` end the run. A removed input starts no turn.
   * - A failed handler removes the input, and a notice names the plugin.
   */
  "input.before": (event: InputBeforeEvent) => undefined | InputBeforeAnswer | Promise<undefined | InputBeforeAnswer>;
  /**
   * Prepare the request of a round: replace the context, or change the model or the settings of the round.
   * - The handlers run once before each round, not before a retry of the round.
   * - Each handler gets the context after the replacements of the earlier handlers.
   * - A later model wins. For each setting, the later value wins.
   * - A failed handler ends the turn with its error, and the round sends no request.
   */
  "round.before": (event: RoundBeforeEvent) => undefined | RoundBeforeAnswer | Promise<undefined | RoundBeforeAnswer>;
  /**
   * Decide whether a failed round runs again.
   * - The handlers run after the last attempt of the round fails. Before that, the host sends the request again after
   *   an error that can go away by itself, such as an overload.
   * - The handlers run as the handlers of `round.before`. Any answer sends the round again with the plan.
   * - Without an answer, the turn ends with the failure, as without a handler.
   * - A failed handler ends the turn with its error, and the error names the failure of the round.
   */
  "round.retry": (event: RoundRetryEvent) => undefined | RoundRetryAnswer | Promise<undefined | RoundRetryAnswer>;
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

/** What `session` of a plugin gets for one session. `O` is the type of the options, as in `PluginContext`. */
export interface SessionContext<O = Record<string, never>> {
  /** The id of the session. */
  readonly sessionId: string;
  /** The workspace folder of the session at its open. A tool reads the folder of each call from its context. */
  readonly folder: string;
  /** The model of the session now. A change of the settings changes it at once. */
  readonly model: ModelReference;
  /** The options of the plugin. They are the same object as `options` of `PluginContext`. */
  readonly options: Frozen<O>;
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
  /** Send an event of this session. See {@link Emit}. */
  readonly emit: Emit;
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

/**
 * The `apply` export of the entry module. It runs once per runtime.
 * - The close of the runtime awaits its cleanup after each session closed, newest plugin first, with no time limit.
 * - A plugin that fails to load after its `apply` returned still runs the cleanup.
 */
export type PluginApply<O = Record<string, never>> = (
  ctx: PluginContext<O>,
) => undefined | Cleanup | Promise<undefined | Cleanup>;

/** What `apply` or `session` can return: the work that the close awaits. A throw is a notice. */
export type Cleanup = () => void | Promise<void>;

/**
 * The `session` export of the entry module. It runs once per session.
 * - The open of the session does not wait for it. The first request for the tools of the session waits for it.
 * - A throw removes its tools and aborts its signal.
 * - The close of the session waits for it to settle, so it must end when its signal aborts.
 */
export type PluginSession<O = Record<string, never>> = (
  s: SessionContext<O>,
) => undefined | Cleanup | Promise<undefined | Cleanup>;
