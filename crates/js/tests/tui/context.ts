import type { Frozen, HostEvents, PluginContext, ServiceOf, Services } from "yuke:plugins";
import { folder } from "yuke:test";

/**
 * The context of a bundled plugin on fake services, for a test that needs a fault that a real host cannot give. A test
 * on a real host uses `createHost` with a frame instead. Each notice is `level text`. `fact` sends an event to the
 * listeners of the plugin.
 */
export function fakeContext<O = Record<string, never>>(fake: {
  readonly name: string;
  readonly services: { readonly [K in keyof Services]?: unknown };
  readonly signal?: AbortSignal;
  readonly options?: O;
  readonly dataDir?: string;
}) {
  const notices: string[] = [];
  const provided = new Map<string, unknown>();
  const listeners = new Map<string, Set<(data: never) => void>>();
  const ctx: PluginContext<O> = {
    name: fake.name,
    dataDir: fake.dataDir ?? folder(),
    options: (fake.options ?? {}) as Frozen<O>,
    signal: fake.signal ?? new AbortController().signal,
    provide: (name, value) => {
      provided.set(name, value);
    },
    get: <K extends keyof Services & string>(name: K) => fake.services[name] as ServiceOf<K>,
    notify: (level, text) => {
      notices.push(`${level} ${text}`);
    },
    sendClientEvent: () => {},
    addListener: <K extends keyof HostEvents>(event: K, listener: (data: HostEvents[K]) => void) => {
      const added = listeners.get(event) ?? new Set();
      listeners.set(event, added.add(listener));
      return () => {
        added.delete(listener);
      };
    },
  };
  /** Send the event `event` with `data` to the listeners of the plugin. */
  const fact = (event: string, data: unknown): void => {
    for (const listener of listeners.get(event) ?? []) listener(data as never);
  };
  return { ctx, notices, provided, fact };
}
