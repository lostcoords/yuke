import { defineTool } from "yuke:internal/define";
import { notify, removeTools } from "yuke:internal/native";
import { CallSignal } from "yuke:internal/signal";
import type { NoticeLevel, PluginApply, PluginContext, Services } from "yuke:plugins";
import type { Tool } from "yuke:tools";

/** One plugin as the host gives it. The host checked the manifest, the order, and the providers before any plugin code. */
export interface PluginSpec {
  readonly name: string;
  readonly root: string;
  readonly dataDir: string;
  /** The absolute path of the entry module, or `undefined` for a plugin without code. */
  readonly entry: string | undefined;
  readonly uses: readonly string[];
  readonly provides: readonly string[];
}

/** The services of the loaded plugins. A service enters only after its provider's `apply` succeeds. */
const services = new Map<string, unknown>();

/**
 * Load the plugin `spec`: import its entry, and await `apply(ctx)`. A failure aborts the signal of the plugin, removes
 * its tools, and throws.
 */
export async function load(spec: PluginSpec): Promise<void> {
  const signal = new CallSignal();
  const pending = new Map<string, unknown>();
  let applying = true;
  const ctx: PluginContext = Object.freeze({
    name: spec.name,
    root: spec.root,
    dataDir: spec.dataDir,
    signal,
    tools: Object.freeze({
      define(tool: Tool): void {
        if (signal.aborted) throw new TypeError(`plugin ${spec.name} did not load`);
        defineTool(tool, spec.name);
      },
    }),
    provide(name: string, value: unknown): void {
      if (!spec.provides.includes(name))
        throw new TypeError(`provide: plugin ${spec.name} has no '${name}' in provides`);
      if (!applying) throw new TypeError(`provide: plugin ${spec.name} provides '${name}' after its apply`);
      if (pending.has(name)) throw new TypeError(`provide: plugin ${spec.name} provides '${name}' twice`);
      if (value === undefined || value === null)
        throw new TypeError(`provide: plugin ${spec.name} cannot provide '${name}' as null or undefined`);
      pending.set(name, value);
    },
    get<K extends string>(name: K): Services[K] {
      if (!spec.uses.includes(name)) throw new TypeError(`get: plugin ${spec.name} has no '${name}' in uses`);
      if (!services.has(name)) throw new Error(`get: no loaded plugin provides '${name}'`);
      return services.get(name) as Services[K];
    },
    notify(level: NoticeLevel, message: string, sessionId?: string): void {
      notify(spec.name, level, String(message), sessionId);
    },
  });

  try {
    if (spec.entry !== undefined) {
      const module = (await import(spec.entry)) as { readonly default?: unknown };
      if (typeof module.default !== "function") {
        throw new TypeError(
          `${spec.entry} has no default export function: a plugin entry exports apply(ctx) as default`,
        );
      }
      const result: unknown = (module.default as PluginApply)(ctx);
      if (result !== undefined && (await result) !== undefined) {
        throw new TypeError("apply must return nothing or a promise of nothing");
      }
    }
    applying = false;
    const missing = spec.provides.filter((name) => !pending.has(name));
    if (missing.length > 0) throw new TypeError(`apply did not provide ${missing.join(", ")} of provides`);
    for (const [name, value] of pending) services.set(name, value);
  } catch (error) {
    applying = false;
    signal.abort(new DOMException(`plugin ${spec.name} did not load`, "AbortError"));
    removeTools(spec.name);
    throw error;
  }
}
