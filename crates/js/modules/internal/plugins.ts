import { checkArguments, checkParameters } from "yuke:internal/arguments";
import { hostSignal } from "yuke:internal/events";
import { failureOf } from "yuke:internal/failure";
import { emit, notify } from "yuke:internal/native";
import { catalog, sessionsOf } from "yuke:internal/sessions";
import { surfaceOf } from "yuke:internal/tui/host";
import { frozen } from "yuke:internal/values";
import type { Cleanup, NoticeLevel, PluginContext, PluginSession, ServiceOf, Services, Sessions } from "yuke:plugins";
import type { Tui } from "yuke:tui";

/** One plugin as the host gives it. The host checked the manifest, the order, and the providers before any plugin code. */
interface PluginSpec {
  readonly name: string;
  readonly dataDir: string;
  /** The options of `config.json`, or of `createHost` in a test. They are `{}` when none come. */
  readonly options: Readonly<Record<string, unknown>>;
  /** The absolute path or the `yuke:` name of the entry module, or `undefined` for a plugin without code. */
  readonly entry: string | undefined;
  /** The exports are the ones that `give` keeps for this name, not the ones of an entry module. */
  readonly given: boolean;
  readonly uses: readonly string[];
  readonly provides: readonly string[];
}

/** The type of the options in the loader. */
export type Options = Readonly<Record<string, unknown>>;

/**
 * Check the options `given` against `schema`, the `optionsSchema` export, and return them frozen. A plugin without a
 * schema takes no options.
 */
function optionsOf(given: Options, schema: unknown): Options {
  if (schema === undefined) {
    if (Object.keys(given).length > 0) {
      throw new TypeError("the plugin gets options, and it exports no optionsSchema");
    }
    return Object.freeze({});
  }
  checkParameters(schema, "optionsSchema");
  try {
    return frozen(checkArguments(schema, given));
  } catch (error) {
    // The check throws an `Error` whose message says what to change.
    throw new TypeError(`the options of the plugin: ${(error as Error).message}`);
  }
}

/** The services of the loaded plugins. A service enters only after its provider's `apply` succeeds. */
const services = new Map<string, unknown>();

/** Set at the start of the close of the plugins. A later load fails, so the close misses no plugin. */
let closing = false;

/** Each loaded plugin, in load order: the abort of its signal and the cleanup of its `apply`. */
const loaded: { readonly plugin: string; readonly abort: (reason: string) => void; readonly cleanup?: Cleanup }[] = [];

/** The `session` export of each loaded plugin, in load order. A new session runs each export. */
export const sessionExports: {
  readonly plugin: string;
  readonly session: PluginSession<Options>;
  readonly options: Options;
}[] = [];

/** The exports that a test host gives as values. The key is the name of the plugin. */
const given = new Map<string, object>();

/**
 * Keep `exports` as the exports of the plugin `name`. A later `load` uses them when its spec has `given` set to true.
 */
export function give(name: string, exports: object): void {
  given.set(name, exports);
}

/**
 * Load the plugin `spec`: import its entry, check its exports, and await `apply(ctx)`. A failure aborts the signal of
 * the plugin and throws. Only a loaded plugin runs `session`.
 */
export async function load(spec: PluginSpec): Promise<void> {
  if (closing) throw new TypeError(`plugin ${spec.name} loads after the close of the plugins`);
  const { signal, abort } = hostSignal();
  const pending = new Map<string, unknown>();
  let applying = true;
  // One surface per plugin activation: each call of `get("tui")` gives the same one, and its signal stops it.
  let tui: { readonly surface: Tui | undefined } | undefined;
  let sessions: Sessions | undefined;
  let cleanup: Cleanup | undefined;
  try {
    let apply: unknown;
    let session: PluginSession<Options> | undefined;
    let optionsSchema: unknown;
    // Each source waits one step, as an entry import does, so a failure of the load rejects after the caller waits.
    const source = await (spec.given
      ? given.get(spec.name)
      : spec.entry === undefined
        ? undefined
        : import(spec.entry));
    if (spec.given && source === undefined) throw new TypeError(`plugin ${spec.name} has no given exports`);
    if (source !== undefined) {
      const exports = source as {
        readonly apply?: unknown;
        readonly session?: unknown;
        readonly optionsSchema?: unknown;
      };
      if (exports.apply === undefined && exports.session === undefined) {
        if (spec.entry === undefined) {
          throw new TypeError(`the given exports of plugin ${spec.name} hold neither apply nor session`);
        }
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
    const ctx: PluginContext<Options> = Object.freeze({
      name: spec.name,
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
      get<K extends keyof Services & string>(name: K): ServiceOf<K> {
        if (name === "tui") {
          tui ??= { surface: surfaceOf(spec.name, signal) };
          return tui.surface as ServiceOf<K>;
        }
        if (name === "sessions") {
          sessions ??= sessionsOf(spec.name, signal);
          return sessions as ServiceOf<K>;
        }
        if (name === "catalog") return catalog as ServiceOf<K>;
        if (!spec.uses.includes(name)) throw new TypeError(`get: plugin ${spec.name} has no '${name}' in uses`);
        const service = services.get(name);
        if (service === undefined) throw new Error(`get: no loaded plugin provides '${name}'`);
        return service as ServiceOf<K>;
      },
      notify(level: NoticeLevel, message: string): void {
        notify(spec.name, level, String(message), undefined);
      },
      emit(event: string, data?: unknown): void {
        emit(spec.name, String(event), JSON.stringify(data) ?? "null", undefined);
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
