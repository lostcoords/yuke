// Long-lived child processes over `yuke:process`. A plugin ties a child to its scope with `ctx.effect(() => () => child.kill())`.

import * as native from "yuke:process";

/** @typedef {import("yuke:process").ProcessExit} ProcessExit */
/** @typedef {{ cwd?: string, env?: Record<string, string>, workspaceRoot?: string }} SpawnOptions */
/** @typedef {{ onStdout(listener: (text: string) => void): void, onStderr(listener: (text: string) => void): void, write(text: string): Promise<void>, closeStdin(): void, kill(): boolean, exited: Promise<ProcessExit> }} ChildProcess */

/** @param {string[]} argv @param {SpawnOptions} [options] @returns {ChildProcess} */
export function spawn(argv, options = {}) {
  /** @type {((text: string) => void)[][]} */
  const listeners = [[], []];
  const env = options.env ? Object.entries(options.env).flat() : undefined;
  const child = native.spawn(argv, { ...(options.cwd !== undefined ? { cwd: options.cwd } : {}), ...(env ? { env } : {}) }, (stream, text) => {
    for (const listener of listeners[stream - 1] ?? []) listener(text);
  }, options.workspaceRoot);
  return {
    onStdout(listener) { listeners[0]?.push(listener); },
    onStderr(listener) { listeners[1]?.push(listener); },
    write(text) { return native.write(child.id, text); },
    closeStdin() { native.closeStdin(child.id); },
    kill() { return native.kill(child.id); },
    exited: child.exited,
  };
}

// Join chunks into lines; it strips one CR before each LF, as MCP stdio framing does, and holds a partial line until its LF arrives.
/** @param {(line: string) => void} onLine @returns {(text: string) => void} */
export function lines(onLine) {
  let rest = "";
  return (text) => {
    rest += text;
    let end;
    while ((end = rest.indexOf("\n")) >= 0) {
      const line = rest.slice(0, end);
      rest = rest.slice(end + 1);
      onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
    }
  };
}
