/**
 * The plugin API. The entry module of a plugin exports `apply`, `session`, or both.
 * - `apply(ctx)` runs once per runtime, for the parts that every session shares.
 * - `session(s)` runs once per session, for the tools and hooks of that session.
 * - `optionsSchema` is the `ObjectSchema` of the options that the user gives in `config.json`. Without it, the plugin
 *   takes no options. Type the contexts with `PluginContext<Infer<typeof optionsSchema>>`.
 * - The declarations need TypeScript 5.4 or later.
 *
 * Errors:
 * - A cancellation aborts a signal with a `DOMException` named `AbortError`.
 * - A tool that throws, or a result with `isError: true`, gives the model an error result.
 * - A notice only informs the user. It fails no tool and no turn.
 */
import type { TextAnswer } from "yuke:ai";
import type { ChatService } from "yuke:chat";
import type {
  Blob,
  Block,
  DisplayBlock,
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
  NoticeParams,
  Question,
  QuestionAnswer,
  RequestSettings,
  SessionId,
  SessionRow,
  SessionSettings,
  SessionSnapshot,
  SessionState,
  SessionUpdate,
  StoredEvent,
} from "yuke:protocol";
import type { ObjectSchema, Tool, ToolMedia } from "yuke:tools";

import type { Tui } from "yuke:tui";

/**
 * The services of the plugins, by name. A provider ships a declaration file that adds its service to this interface:
 * `declare module "yuke:plugins" { interface Services { "acme.notes.v1": Notes } }`. Each plugin that uses the service
 * includes that file. A name without a declaration fails the type check. Three services belong to yuke itself and
 * need no `uses` entry:
 * - `tui`: the terminal interface, or `undefined` in `yuke --rpc` and `yuke -p`.
 * - `sessions`: the sessions, in each mode.
 * - `catalog`: the providers and their models, in each mode.
 *
 * The bundled chat provides `chat`, the chat panes of the terminal interface. A plugin that uses it needs a `uses`
 * entry.
 */
export interface Services {
  readonly tui: Tui | undefined;
  readonly sessions: Sessions;
  readonly catalog: Catalog;
  readonly chat: ChatService;
}

/**
 * The sessions of yuke. A session that a plugin creates is an ordinary session: each client can load it and send it
 * input. A session with a parent stays out of the default list. A failed request rejects with an `Error` that tells why.
 */
export interface Sessions {
  /**
   * Create a session with `settings`, and open it. It closes by itself when nothing holds it and it has no work.
   * With `options.parent`, the session works for that session. It stays out of the default list, and the removal of the
   * parent removes it. An unknown parent rejects.
   */
  readonly create: (settings: SessionSettings, options?: { readonly parent?: SessionId }) => Promise<SessionId>;
  /** Fork session `id` through the end of the completed turn `through`, or its newest one, and open the fork. */
  readonly fork: (id: SessionId, through?: EventNumber) => Promise<SessionId>;
  /**
   * A page of the saved sessions, newest first. `nextCursor` continues the list. Without `parent`, the page holds only
   * the sessions without a parent. With `parent`, it holds the sessions of that parent.
   */
  readonly list: (params?: ListSessionsParams) => Promise<ListSessionsResult>;
  /** The row of the saved session `id`, with its state now. */
  readonly get: (id: SessionId) => Promise<SessionRow>;
  /**
   * Rename an open or closed session without changing its history or activity times.
   * The call normalizes whitespace and rejects empty titles or titles above 200 Unicode scalar values.
   */
  readonly rename: (id: SessionId, title: string) => Promise<void>;
  /** Delete the saved session `id` and its descendants. The call fails while one of these sessions is open. */
  readonly remove: (id: SessionId) => Promise<void>;
  /**
   * Open session `id`, also a closed one, and hold it: it does not close by itself until the handle ends.
   * `options.onEvent` gets a snapshot of the session first, then each later update, in order. The open resolves after
   * the snapshot.
   */
  readonly open: (id: SessionId, options: OpenOptions) => Promise<SessionHandle>;
  /**
   * At most `page.limit` saved events of session `id` before the event `page.before`, or its last ones, in order. The
   * session can be closed. A newest commit with no `end` is an unfinished turn, for example after a crash of yuke.
   */
  readonly events: (id: SessionId, page: EventsPage) => Promise<readonly Frozen<StoredEvent>[]>;
  /**
   * Close session `id` at once for each holder, end each handle on it, and stop its jobs. A cleanup of the session must
   * not await the close of its own session.
   */
  readonly closeForAll: (id: SessionId) => Promise<void>;
}

/** How `Sessions.open` watches a session. */
export interface OpenOptions {
  /** The number of the last saved events in the snapshot. */
  readonly tail: number;
  /** Ends the handle: `onEvent` gets no more calls, and the hold ends. The session stays open for its other holders. */
  readonly signal?: AbortSignal;
  /** Gets the snapshot, then each later update, in order. A throw is a fault of the plugin, and the next event still comes. */
  readonly onEvent: (event: SessionHandleEvent) => void;
}

/** One event of an open session: its snapshot first, then each later update. */
export type SessionHandleEvent =
  | { readonly kind: "snapshot"; readonly snapshot: Frozen<SessionSnapshot> }
  | { readonly kind: "update"; readonly update: Frozen<SessionUpdate> };

/** A page of the saved events of a session. */
export interface EventsPage {
  /** The page ends before this event. Without it, the page holds the last events. */
  readonly before?: EventNumber;
  /** The most events of the page. */
  readonly limit: number;
}

/**
 * An open session that a plugin holds. After the end of the handle, each async request rejects and each sync request
 * throws. `using` closes it.
 */
export interface SessionHandle extends Disposable {
  readonly id: SessionId;
  /**
   * Aborts at the end of the handle: by the signal of the open, by `close`, by the stop of the plugin, or by the close
   * of the session. Its reason tells which.
   */
  readonly signal: AbortSignal;
  /**
   * Send `content` as a message of the user. The model reads `modelContent` in place of `content` when it is set. A
   * turn starts when the session is idle.
   */
  readonly sendMessage: (message: {
    readonly content: readonly Block[];
    readonly modelContent?: readonly Block[] | undefined;
  }) => Promise<InputId>;
  /** Send a notification of this plugin: the user sees `display`, and the model reads `text`. */
  readonly notifyModel: (notification: { readonly display: string; readonly text: string }) => Promise<InputId>;
  /**
   * End the handle: `onEvent` gets no more calls, and the hold ends. The session stays open for its other holders. A
   * second close does nothing.
   */
  readonly close: () => void;
  /** Cancel the running turn. A session without a turn has nothing to cancel. */
  readonly cancel: () => void;
  /** Move each tool call that waits for a job, such as a running command, to the background. The turn goes on. */
  readonly moveJobsToBackground: () => void;
  /** Whether `moveJobsToBackground` moves a job now. */
  readonly canMoveJobsToBackground: () => boolean;
  /**
   * Wait until the session runs no turn and has handled each input that it accepted before the call, or until its close.
   * A failed turn counts as handled, and its input waits for the next input.
   * Each view and host-event listener in this runtime receives the queued events before the promise resolves.
   */
  readonly waitForIdle: () => Promise<void>;
  /** Save `settings`. It fails while a turn runs or input waits. */
  readonly setSettings: (settings: SessionSettings) => Promise<void>;
  /**
   * Save `bytes` in the store of the session, and get the blob that names them, as for the image of an input. The
   * blob stays until the session is removed.
   */
  readonly putBlob: (bytes: Uint8Array) => Promise<Blob>;
  /** Remove the pending input `inputId` from the queue of the session. `false` when it is not pending: a turn took it, or a removal came first. */
  readonly removeInput: (inputId: InputId) => Promise<boolean>;
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
  /** Every provider with `options.all`, else only the providers that are ready. Only a ready provider has models. */
  readonly list: (options?: { readonly all?: boolean }) => Promise<ListCatalogResult>;
}

/** The value of `ctx.get(name)`. A service in `uses` is present, because its provider loads first. `tui` can be `undefined`. */
export type ServiceOf<K extends keyof Services> = K extends "tui" ? Services[K] : NonNullable<Services[K]>;

/** `T` with each field read-only at each depth. */
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
  /**
   * Publish the service `name` during `apply`. `name` is one of `provides` of the manifest, so the plugins that use the
   * service load after this plugin. Another name throws a `TypeError`.
   */
  readonly provide: <K extends Exclude<keyof Services & string, "tui" | "sessions" | "catalog">>(
    name: K,
    value: NonNullable<Services[NoInfer<K>]>,
  ) => void;
  /**
   * The service `name`. Declare `name` in `uses` of the manifest, so this plugin loads after its provider. `get("tui")`
   * gives the terminal interface of this plugin, or `undefined` outside it. It needs no `uses` entry.
   */
  readonly get: <K extends keyof Services & string>(name: K) => ServiceOf<K>;
  /** Send a notice with this plugin as its source. */
  readonly notify: (level: NoticeLevel, text: string) => void;
  /** Send an event of the whole process to the client. See {@link SendClientEvent}. */
  readonly sendClientEvent: SendClientEvent;
  /**
   * Call `listener` with each fact of the kind `event` in the whole process, and give the remover. A fact reports what
   * happened. The host does not wait for the listener, and the return of the listener does nothing.
   * - A listener of `session.opened` first gets each session that is open now, then each later open.
   * - A listener holds no session.
   * - A throw gives a notice, and the listener stays. The abort of `ctx.signal` removes it.
   *
   * ```ts
   * ctx.addListener("session.update", ({ sessionId, update }) => {
   *   if (update.sessionUpdate === "state") report(sessionId, update.state);
   * });
   * ```
   */
  readonly addListener: <K extends keyof HostEvents>(event: K, listener: (data: HostEvents[K]) => void) => () => void;
}

/** The facts of `ctx.addListener`, by event. */
export interface HostEvents {
  /** An update of an open session, as a handle of `sessions.open` gets it. */
  readonly "session.update": { readonly sessionId: SessionId; readonly update: Frozen<SessionUpdate> };
  /**
   * A session is open, with its state now. `parent` is the session that it works for, as a subagent does. The running
   * jobs and the open interactions come oldest first. A later job change comes as a `job` update.
   */
  readonly "session.opened": {
    readonly sessionId: SessionId;
    readonly parent?: SessionId;
    readonly state: SessionState;
    readonly jobs: readonly Frozen<Job>[];
    readonly interactions: readonly InteractionId[];
  };
  /** A session closed. No update of it follows. A later open gives a new `session.opened`. */
  readonly "session.closed": { readonly sessionId: SessionId };
  /**
   * A notice of yuke or of a plugin, when it happens. The terminal interface also keeps a history of the notices from
   * before a listener: `tui.notices`.
   */
  readonly notice: Frozen<NoticeParams>;
  /**
   * A login, a logout, or a credential changed the providers that are ready, so `catalog.list` can give other models.
   * A reload of the profile restarts the plugins, so it gives no such event.
   */
  readonly "catalog.changed": undefined;
  /**
   * The active theme or its look changed: another name, a change of that theme, or another background of the terminal.
   * Only the terminal interface sends it. A listener gets nothing for the theme from before it, so read
   * `tui.styles.theme` at its start.
   */
  readonly "theme.changed": { readonly name: string; readonly background: "dark" | "light" };
}

/**
 * Send the event `event` with `data` to the active client of `yuke --rpc`.
 * - The extension of the event is the name of this plugin. A client ignores an extension that it does not know.
 * - `data` follows `JSON.stringify`. A value with no JSON form, such as `undefined`, sends `null`. Put a version in
 *   `data` when its shape changes.
 * - The event is transient. A client that connects later does not get it. With no client, the host drops it.
 */
export type SendClientEvent = (event: string, data?: unknown) => void;

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
   * The new sections, by key.
   * Their order is the order of the prompt.
   * The model reads each section between `<key>` and `</key>`, except `base`.
   * An empty text adds nothing.
   */
  readonly sections: Readonly<Record<string, string>>;
}

/** One tool call of the model. */
export interface ToolCall {
  /** The id of the call, from the model. */
  readonly callId: string;
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
  /** What a chat shows in place of the text. The model never sees it. */
  readonly display: readonly DisplayBlock[];
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
  readonly deny: string;
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
  /**
   * The new display list. Keep it in step with a changed text, for example a redaction, because a chat shows the
   * display in place of the text. `[]` removes it.
   */
  readonly display?: readonly DisplayBlock[] | undefined;
}

/** What a `round.before` handler gets. */
export interface RoundBeforeEvent {
  /** The context window of the model of the round in tokens. It is absent when the catalog names none. */
  readonly contextWindow?: number;
  /**
   * The input tokens of the newest answer of the session. It is absent before an answer, without a provider count, or
   * after a newer replacement.
   */
  readonly inputTokens?: number;
  /**
   * The estimated input tokens of the context that this handler sees. It adds the estimate of the newest assistant run
   * and each later block to `inputTokens`. Without `inputTokens`, or after an earlier replacement, it sums
   * `blockTokens()`. It needs no copy of the context, so read it in place of a count over `blocks()`.
   */
  readonly contextTokens: number;
  /** The number of blocks of the context, after the replacements of the earlier handlers of this round. */
  readonly blockCount: number;
  /**
   * The estimated tokens of each block of `blocks()`, in the same order. Text bytes divide by 4 and round up. A tool
   * call counts its name and its arguments. Reasoning counts the larger of its text and its provider state. Each media
   * item adds 1600.
   */
  readonly blockTokens: () => number[];
  /** The blocks of the context, oldest first, after the replacements of the earlier handlers. Each call gives a copy. */
  readonly blocks: () => Block[];
  /**
   * Send the request of this round with other blocks, and wait for the first answer.
   * - The request has the model, the system prompt, the tools, and the settings of the round.
   * - Its blocks are the first `blockCount` blocks of `blocks()`, then `prompt` as a user block.
   * - It repeats the bytes and the cache marker of the round, so it can reuse the prompt cache of the earlier rounds.
   * - No tool runs, and the session keeps nothing of the request.
   * - A failed request rejects with an `Error`.
   */
  readonly sideRequest: (options: SideRequestOptions) => Promise<TextAnswer>;
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
  /** The number of the oldest blocks of `blocks()` to send, from 0 to `event.blockCount`. The default sends each block. */
  readonly blockCount?: number | undefined;
  /** The output limit of the request in tokens. Without it, the request has the limit of the round. */
  readonly maxOutputTokens?: number | undefined;
  /** An abort stops the request, and the promise rejects with the reason of the signal. */
  readonly signal?: AbortSignal | undefined;
}

/**
 * The answer of a `round.before` handler. Each part is optional.
 * - `replace` makes the context `head`, then the last `keep` blocks of the context. The session keeps the replacement.
 * - `model` sends this round to another model of the catalog. An unknown model fails the turn.
 * - `settings` replaces these settings for this round. Each field replaces its whole value, so a field that a new
 *   `reasoning` leaves out has no value. An unknown field has no effect. A value of another shape fails the turn.
 */
export interface RoundBeforeAnswer {
  readonly replace?: { readonly head: readonly Block[]; readonly keep: number } | undefined;
  readonly model?: ModelReference | undefined;
  readonly settings?: Partial<RequestSettings> | undefined;
}

/**
 * The kind of a failure of a round.
 * - The provider kinds come from the status, the error code, or the error message of the provider. `contextOverflow`
 *   means that the input does not fit the context window of the model.
 * - `transport`, `protocol`, `responseTooLarge`, and `incompleteStream` are failures of the connection or the stream.
 * - `encode` means that yuke could not build the request, for example for a media type that the provider refuses.
 * - `credential` means that yuke could not get a credential, for example after a failed refresh of a login.
 */
export type RoundFailureKind =
  | "contextOverflow"
  | "rateLimited"
  | "rateLimitUnknown"
  | "quotaExhausted"
  | "serverError"
  | "timeout"
  | "conflict"
  | "authFailed"
  | "permissionDenied"
  | "badStatus"
  | "providerFailed"
  | "transport"
  | "protocol"
  | "responseTooLarge"
  | "incompleteStream"
  | "encode"
  | "credential";

/** Why a round failed. */
export interface RoundFailure {
  readonly kind: RoundFailureKind;
  /** The text of the failure, as the user sees it. */
  readonly text: string;
}

/** What a `round.retry` handler gets: the facts of `round.before` for the failed round, and the failure. */
export interface RoundRetryEvent extends RoundBeforeEvent {
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
 * - `deny` removes the input. A notice shows the reason to the user.
 * - `replace` gives the model these blocks in place of the input. The user still sees the sent input. The list has at
 *   least one item. A `ToolMedia` adds a media item, and its relative path starts in the workspace folder of the session.
 * - `handled` removes the input with no notice, because the plugin acted on it.
 */
export type InputBeforeAnswer =
  | { readonly deny: string; readonly replace?: never; readonly handled?: never }
  | {
      readonly replace: { readonly blocks: readonly [Block | ToolMedia, ...(Block | ToolMedia)[]] };
      readonly deny?: never;
      readonly handled?: never;
    }
  | { readonly handled: true; readonly deny?: never; readonly replace?: never };

/** What a `round.after` handler gets. */
export interface RoundAfterEvent {
  /** The assistant text of the answer of this round. It can be empty, for example for an answer with calls only. */
  readonly text: string;
  /**
   * Why the answer ended, when it needs no other request. It is absent after a round of tool calls, because the turn
   * then goes on.
   */
  readonly finishReason?: FinishReason;
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
 * - Input that the user sent during the turn goes with the text in the same request. Give a text that is not empty.
 */
export type RoundAfterAnswer =
  | { readonly stop: true; readonly continue?: never }
  | { readonly continue: string; readonly stop?: never };

/**
 * The hooks of a session, by point.
 * - Each handler gets one frozen event, and the host awaits it.
 * - The handler returns `undefined` for no change, or an answer.
 * - A throw is a failure of the handler. Its error names the point and the plugin.
 * - The host trusts the declared answer type.
 */
export interface SessionHooks {
  /**
   * Check an input before a turn takes it: an input of the user, the end of a job, or a `continue` text.
   * - The store saves the input first.
   * - The handlers run when a turn takes the input. A turn takes it at its start, or after a round.
   * - Each handler gets the blocks after the replacements of the handlers before it.
   * - `deny` and `handled` end the run. A removed input starts no turn.
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

/** The options of `sendClientRequest`. */
export interface ClientRequestOptions {
  /** An abort of this signal ends the wait, and the request rejects with the abort reason. */
  readonly signal?: AbortSignal | undefined;
}

/** The error answer of the client to `sendClientRequest`. `message` is the message of the client. */
export class ClientRequestError extends Error {
  /** The JSON-RPC error code of the client. */
  readonly code: number;
  /** More facts about the error, when the client gave them. */
  readonly data: unknown;

  constructor(message: string, details: { readonly code: number; readonly data: unknown }) {
    super(message);
    this.code = details.code;
    this.data = details.data;
  }
}
ClientRequestError.prototype.name = "ClientRequestError";

/** The options of `ask`. */
export interface AskOptions {
  /** An abort of this signal closes the request, and the request answers `undefined`. */
  readonly signal?: AbortSignal | undefined;
}

/** What `ask` puts to the user: one or more questions, which the user answers together. */
export interface AskRequest {
  /**
   * The questions, in display order. The ids are unique. The labels of a question are unique, and each question has an
   * option or `other`. Only a question without options has `secret`.
   */
  readonly questions: readonly Frozen<Question>[];
}

/** What `s.jobs.start` takes. */
export interface JobOptions {
  /** The id of the job, unique among the running jobs of the session. It can stay the same across restarts of the work. */
  readonly id: string;
  /** A short text for display. yuke keeps the first line, at most 60 characters. */
  readonly label: string;
}

/** What `context.jobs.run` of a tool takes. */
export interface CallJobOptions extends JobOptions {
  /** Run without the call from the start. */
  readonly background?: boolean | undefined;
}

/** The report of a job. */
export interface JobReport {
  /** The end in words, for example `completed`. A notification shows the user `{label} · {status}`. */
  readonly status: string;
  /** The text for the model. A notification puts the id, the label, and the status before it. */
  readonly text: string;
}

/**
 * The work of a job. `signal` aborts at a stop of the job, at the close of the session, and at a cancel of the call that
 * waits for the job, so end the work at the abort. A move out of the call does not abort it. The returned report goes to
 * the call that waits, else to the session as one notification, and a turn starts when the session is idle. After a stop,
 * the host drops the report. Nothing returned sends no report. A throw rejects the wait of the call, else it reports
 * `failed`.
 */
export type JobWork = (signal: AbortSignal) => JobReport | undefined | Promise<JobReport | undefined>;

/** How `context.jobs.run` ended: the work ended while the call waited, or it runs on without the call. */
export type JobOutcome =
  | { readonly kind: "completed"; readonly report: JobReport | undefined }
  | { readonly kind: "background"; readonly id: string };

/** What `session` of a plugin gets for one session. `O` is the type of the options, as in `PluginContext`. */
export interface SessionContext<O = Record<string, never>> {
  /** The id of the session. */
  readonly sessionId: SessionId;
  /** The parent session. A fork has no parent. */
  readonly parent: SessionId | undefined;
  /** The workspace folder of the session at its open. A tool reads the folder of each call from its context. */
  readonly cwd: string;
  /** A frozen copy of the settings of the session now. Each read gives a new copy. */
  readonly settings: Frozen<SessionSettings>;
  /** The options of the plugin. They are the same object as `options` of `PluginContext`. */
  readonly options: Frozen<O>;
  /** The host aborts this signal when the session closes or `session` of this plugin fails. The plugin then stops. */
  readonly signal: AbortSignal;
  /**
   * This plugin's tool definitions and name removals in this session. The last successful call for a name wins.
   * Calls after an `await` follow call order, not plugin configuration order. A failed setup withdraws its changes.
   */
  readonly tools: {
    /**
     * Define or replace `tool` for this session. `execute` gets the arguments with the types of `parameters`.
     * - The returned function removes only this definition and reveals the previous definition or name removal.
     * - A replacement of another plugin's tool sends an info notice. A built-in or same-plugin replacement sends none.
     * - The next turn uses the new tool list. A change can invalidate the provider's prompt cache.
     */
    readonly add: <const S extends ObjectSchema>(tool: Tool<S>) => () => void;
    /**
     * Remove `name` from this session's tool list. A later definition restores it. An unknown name does not fail.
     * - The returned function ends only this removal and reveals the previous definition or name removal.
     * - The removal ends when this plugin's session scope ends. It does not affect other sessions.
     * - An invalid or reserved name throws a `TypeError`.
     */
    readonly remove: (name: string) => () => void;
  };
  /** The background jobs of the plugin in this session. */
  readonly jobs: {
    /**
     * Run `work` as a job without a call, and list it with the jobs of the session. For work inside a tool call, use
     * `context.jobs.run`. The start rejects in three cases: the id still runs in this session, the session closed, or
     * the run is `yuke -p`.
     * - The `stop` tool, `job/stop`, and `stopJob` of a handle abort the signal of `work`, and wait for its end.
     * - A close of the session and a reload abort the signal too, and they wait for `work` to end.
     * - During a reload the old job still runs while the new `session` starts, so start the same id later.
     */
    readonly start: (job: JobOptions, work: JobWork) => Promise<void>;
  };
  /**
   * Add `handler` to the hook `point` of this session. The handlers of a point run in plugin order, then in the order
   * of their addition. The returned function removes the handler. An addition or a removal during a run of the point
   * changes the next run.
   */
  readonly addHook: <K extends keyof SessionHooks>(point: K, handler: SessionHooks[K]) => () => void;
  /** Send a notice of this session with this plugin as its source. */
  readonly notify: (level: NoticeLevel, text: string) => void;
  /** Send an event of this session to the client. See {@link SendClientEvent}. */
  readonly sendClientEvent: SendClientEvent;
  /**
   * Send the request `request` with `data` to the active client of `yuke --rpc`, and wait for the answer.
   * - The extension of the request is the name of this plugin. A client answers an extension that it does not know
   *   with the code -32601.
   * - `data` follows `JSON.stringify`, as for `sendClientEvent`. The promise gives the result of the client.
   * - An error answer of the client rejects with an `ClientRequestError`.
   * - With no client, as in `yuke -p` and in the interface, the request rejects with an `Error` at once. A disconnect of
   *   the client rejects with an `Error` too.
   * - An abort of the signal or the close of the session rejects with the abort reason. A request that the client got
   *   and did not answer sends a cancel to the client.
   * - The host sets no time limit. Pass the signal of the tool or the hook, so that a cancel of the turn ends the wait.
   */
  readonly sendClientRequest: (request: string, data?: unknown, options?: ClientRequestOptions) => Promise<unknown>;
  /**
   * Ask the user `request` with this plugin as its source, and wait for the answers: one per question, in question
   * order.
   * - A yes or no question is a question with two options. A text field is a question without options and with `other`.
   * - The answer is `undefined` when the user cancels, the signal aborts, the session closes, or no client can answer,
   *   as in `yuke -p`.
   * - The turn waits while a hook or a tool waits for the answer. Pass the signal of the hook or the tool, so that a
   *   cancel of the turn closes the request.
   */
  readonly ask: (request: AskRequest, options?: AskOptions) => Promise<QuestionAnswer[] | undefined>;
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
