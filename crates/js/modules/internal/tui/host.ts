/**
 * The link between the plugin loader and the core of the terminal interface. The boot sets it in TUI mode; in the
 * RPC and the print mode it stays unset, so `ctx.get("tui")` gives `undefined`.
 */
import type { Tui } from "yuke:tui";

let bind: ((owner: string, signal: AbortSignal) => Tui) | undefined;

/** Set the function that makes the surface of each plugin. The boot calls it once. */
export function setSurfaces(surface: (owner: string, signal: AbortSignal) => Tui): void {
  bind = surface;
}

/** The surface of the plugin `owner`, which stops with `signal`, or `undefined` outside the terminal interface. */
export function surfaceOf(owner: string, signal: AbortSignal): Tui | undefined {
  return bind?.(owner, signal);
}
