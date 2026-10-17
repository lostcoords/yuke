/**
 * The plugin API. The entry module of a plugin exports `apply`, `session`, or both. `apply(ctx)` runs once per runtime,
 * for the parts that every session shares. `session(s)` runs once per session, for the tools of that session. The
 * declarations need TypeScript 5.4 or later.
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
  /** Send a notice of this session with this plugin as its source. */
  readonly notify: (level: NoticeLevel, message: string) => void;
}

/** The `apply` export of the entry module. It runs once per runtime. */
export type PluginApply = (ctx: PluginContext) => undefined | Promise<undefined>;

/** What `session` can return: the work that the close of the session awaits. */
export type SessionCleanup = () => void | Promise<void>;

/**
 * The `session` export of the entry module. It runs once per session. The open of the session does not wait for it.
 * The first request for the tools of the session waits for it. A throw removes its tools and aborts its signal.
 */
export type PluginSession = (s: SessionContext) => undefined | SessionCleanup | Promise<undefined | SessionCleanup>;
