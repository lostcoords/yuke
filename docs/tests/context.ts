import type { PluginContext, ServiceOf, Services } from "yuke:plugins";
import type { TestSurface } from "yuke:test";

// The test host has no terminal. Use a real frame surface for UI registrations and close it with the host plugin.
export function withSurface(ctx: PluginContext, surface: TestSurface): PluginContext {
  ctx.signal.addEventListener("abort", () => surface.close(), { once: true });
  return {
    ...ctx,
    get<K extends keyof Services & string>(name: K): ServiceOf<K> {
      return name === "tui" ? (surface.tui as ServiceOf<K>) : ctx.get(name);
    },
  };
}
