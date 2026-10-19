/**
 * The plugin API. The entry module of a plugin exports `apply`, `session`, or both. `apply(ctx)` runs once per runtime,
 * for the parts that every session shares. `session(s)` runs once per session, for the tools and hooks of that
 * session. The declarations need TypeScript 5.4 or later.
 *
 * Errors: a misuse of the API throws a `TypeError`. A cancellation aborts a signal with a `DOMException` named
 * `AbortError`. A tool that throws, or a result with `isError: true`, gives the model an error result. A notice only
 * informs the user. It fails no tool and no turn.
 */
import type { ObjectSchema, Tool } from "yuke:tools";

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

/** What a `prompt.build` handler gets. The handler edits `sections` and returns nothing. */
export interface PromptBuild {
  /**
   * The system prompt sections of the turn, by key, in order. An assignment to a key replaces its text, or adds the
   * section at the end. A `delete` removes the section. A new object sets a new order. Each key matches
   * `^[a-z][a-z0-9_-]*$`, and each text is a string. The model reads each section between `<key>` and `</key>`, except
   * `base`. An empty text adds nothing.
   */
  sections: Record<string, string>;
  /** The host aborts this signal when the turn is cancelled. */
  readonly signal: AbortSignal;
}

/** What a `tool.before` handler gets: one tool call of the model before it runs. */
export interface ToolCallHook {
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
  /** The host aborts this signal when the turn is cancelled. */
  readonly signal: AbortSignal;
}

/** The answer of a `tool.before` handler that stops the call. */
export interface ToolBlock {
  /** Why the call does not run. The model gets this text as the error result of the call. */
  readonly block: string;
}

/** The hooks of a session, by point. The host awaits each handler. */
export interface SessionHooks {
  /**
   * Edit the system prompt of a turn. The handlers run once before each turn, after `session` of each plugin settles.
   * When a handler throws, the host sends a notice and starts no turn. The input stays pending until the next input.
   * The edits are for that turn only. A text that changes at each turn makes each turn miss the prompt cache of the
   * provider.
   */
  "prompt.build": (build: PromptBuild) => undefined | Promise<undefined>;
  /**
   * Decide whether a tool call runs. The handlers run before each call, in call order. They run in order until one
   * returns a `ToolBlock`. The call then does not run, and the turn goes on. `undefined` leaves the decision to the
   * next handler. A throw, or an answer of another shape, also stops the call, so a failed check never lets a call run.
   */
  "tool.before": (call: ToolCallHook) => undefined | ToolBlock | Promise<undefined | ToolBlock>;
}

/** What `session` of a plugin gets for one session. */
export interface SessionContext {
  /** The id of the session. */
  readonly sessionId: string;
  /** The workspace folder of the session at its open. A tool reads the folder of each call from its context. */
  readonly folder: string;
  /** The host aborts this signal when the session closes or `session` of this plugin fails. The plugin then stops. */
  readonly signal: AbortSignal;
  /** The tools of the plugin in this session. They stay until the session closes. */
  readonly tools: {
    /** Define `tool` for this session. `execute` gets the arguments with the types of `parameters`. */
    readonly define: <const S extends ObjectSchema>(tool: Tool<S>) => void;
  };
  /**
   * Add `handler` to the hook `point` of this session. The handlers of a point run in plugin order, then in the order
   * of their addition. The returned function removes the handler. An addition or a removal during a run of the point
   * changes the next run.
   */
  readonly hook: <K extends keyof SessionHooks>(point: K, handler: SessionHooks[K]) => () => void;
  /** Send a notice of this session with this plugin as its source. */
  readonly notify: (level: NoticeLevel, message: string) => void;
}

/** The `apply` export of the entry module. It runs once per runtime. */
export type PluginApply = (ctx: PluginContext) => undefined | Promise<undefined>;

/** What `session` can return: the work that the close of the session awaits. */
export type SessionCleanup = () => void | Promise<void>;

/**
 * The `session` export of the entry module. It runs once per session. The open of the session does not wait for it.
 * The first request for the tools of the session waits for it. A throw removes its tools and aborts its signal. The
 * close of the session waits for it to settle, so it must end when its signal aborts.
 */
export type PluginSession = (s: SessionContext) => undefined | SessionCleanup | Promise<undefined | SessionCleanup>;
