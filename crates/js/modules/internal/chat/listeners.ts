/** The change listeners of the blocks of `yuke:chat`. */

const { reportError } = globalThis;

/**
 * Call each listener of `listeners`. A throw removes that listener and reports the error, and the others still run. A
 * listener that a call adds runs at the next change, and a listener that a call removes does not run.
 */
export function callEach(listeners: Set<() => void>): void {
  for (const listener of [...listeners]) {
    if (!listeners.has(listener)) continue;
    try {
      listener();
    } catch (error) {
      listeners.delete(listener);
      reportError(error);
    }
  }
}
