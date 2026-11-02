/** The change listeners of the blocks of `yuke:chat`. */

/**
 * Call each listener of `listeners`. A listener that a call adds runs at the next change.
 * A listener that a call removes does not run.
 */
export function callEach(listeners: Set<() => void>): void {
  for (const listener of [...listeners]) {
    if (listeners.has(listener)) listener();
  }
}
