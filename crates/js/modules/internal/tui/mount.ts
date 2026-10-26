/** A mount: one close path for a pane, an overlay, or a root. */
import { failureOf } from "yuke:internal/failure";
import type { Mount, View, ViewFactory } from "yuke:tui";

/**
 * A mount whose first `close()` aborts its signal, then runs `closed`. Later calls do nothing, so each close path (a
 * command, Escape, the stop of the owner) can call it.
 */
export function createMount(closed: () => void): Mount {
  const controller = new AbortController();
  return Object.freeze({
    signal: controller.signal,
    close(): void {
      if (controller.signal.aborted) return;
      controller.abort();
      closed();
    },
  });
}

/**
 * The view that `create` makes for `mount`, or `undefined` when the factory throws, returns no view, or closes its own
 * mount. A throw or a bad value closes the mount and reports one fault as `owner`.
 */
export function startView(
  owner: string,
  create: ViewFactory,
  mount: Mount,
  report: (source: string, text: string) => void,
): View | undefined {
  if (typeof create !== "function") throw new TypeError("a mount takes a function that makes its view");
  try {
    const view: unknown = create(mount);
    if (typeof view !== "object" || view === null || typeof (view as View).draw !== "function") {
      throw new TypeError("the factory returned no view: a view is an object with a draw function");
    }
    // A factory that closed its own mount wants no view.
    return mount.signal.aborted ? undefined : (view as View);
  } catch (error) {
    report(owner, `a view did not start: ${failureOf(error)}`);
    mount.close();
    return undefined;
  }
}
