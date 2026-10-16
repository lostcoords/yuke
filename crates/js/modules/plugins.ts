import type { Signal, Tool } from "yuke:tools";

/** The severity of a notice. */
export type NoticeLevel = "debug" | "info" | "warn" | "error";

/**
 * The services of the plugins, by name. A plugin adds the type of its service through module augmentation:
 * `declare module "yuke:plugins" { interface Services { notes: Notes } }`.
 */
export interface Services {
  [name: string]: unknown;
}

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
  readonly signal: Signal;
  /** The tools of the plugin. */
  readonly tools: {
    /** Define `tool` for this plugin. A second tool with the same name throws a `TypeError`. */
    readonly define: (tool: Tool) => void;
  };
  /** Publish the service `name` once, during `apply`, with a value that is not null. `name` must be in `provides`. */
  readonly provide: <K extends string>(name: K, value: Services[K]) => void;
  /** The service `name` of an earlier plugin, never null. `name` must be in `uses` of the manifest. */
  readonly get: <K extends string>(name: K) => Services[K];
  /** Send a notice with this plugin as its source. A `sessionId` binds the notice to that session. */
  readonly notify: (level: NoticeLevel, message: string, sessionId?: string) => void;
}

/** The default export of the entry module of a plugin. */
export type PluginApply = (ctx: PluginContext) => void | Promise<void>;
