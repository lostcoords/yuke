/** A mount: one close path for a pane, an overlay, or a root. */
import { failureOf } from "yuke:internal/failure";
import type { Mount, View } from "yuke:tui";

/**
 * A mount whose first `close()` aborts its signal, then runs `closed`. Later calls do nothing, so each close path (a
 * command, Escape, the stop of the owner) can call it.
 */
export function createMount(closed: () => void): Mount {
  const controller = new AbortController();
  return {
    signal: controller.signal,
    close(): void {
      if (controller.signal.aborted) return;
      controller.abort();
      closed();
    },
  };
}

/**
 * The view that `create` makes for `mount`, or `undefined` when the factory throws or closes its own mount. A throw
 * closes the mount and reports one fault as `owner`.
 */
export function startView<V extends View>(
  owner: string,
  create: (mount: Mount) => V,
  mount: Mount,
  report: (source: string, text: string) => void,
): V | undefined {
  try {
    const view = create(mount);
    // A factory that closed its own mount wants no view.
    return mount.signal.aborted ? undefined : view;
  } catch (error) {
    report(owner, `A view did not start: ${failureOf(error)}`);
    mount.close();
    return undefined;
  }
}
