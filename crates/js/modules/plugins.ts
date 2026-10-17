/**
 * The plugin API. The entry module of a plugin exports `apply(ctx)` as default. The declarations need TypeScript 5.4
 * or later.
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

/** What `apply` of a plugin gets. A plugin that fails to load loses its tools. */
export interface PluginContext {
  /** The name of the plugin, from its `plugin.json`. */
  readonly name: string;
  /** The absolute folder of the plugin. */
  readonly root: string;
  /** The absolute data folder of the plugin. It exists, and it stays across reloads. */
  readonly dataDir: string;
  /**
   * Aborts when the plugin fails to load. Then clear your timers: a failed plugin keeps them. A shutdown stops the
   * JavaScript without an abort.
   */
  readonly signal: AbortSignal;
  /** The tools of the plugin. */
  readonly tools: {
    /** Define `tool` for this plugin. `execute` gets the arguments with the types of `parameters`. */
    readonly define: <const S extends ObjectSchema>(tool: Tool<S>) => void;
  };
  /** Publish the service `name` once, during `apply`. The value is not null or undefined. `name` must be in `provides`. */
  readonly provide: <K extends keyof Services & string>(name: K, value: NonNullable<Services[NoInfer<K>]>) => void;
  /** The service `name` of an earlier plugin, never null. `name` must be in `uses` of the manifest. */
  readonly get: <K extends keyof Services & string>(name: K) => NonNullable<Services[K]>;
  /** Send a notice with this plugin as its source. A `sessionId` binds the notice to that session. */
  readonly notify: (level: NoticeLevel, message: string, sessionId?: string) => void;
}

/** The default export of the entry module of a plugin. */
export type PluginApply = (ctx: PluginContext) => void | Promise<void>;
