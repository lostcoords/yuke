// Long-lived children over `yuke:process`. Tie a child to a plugin with `ctx.effect(() => () => child.kill())`.

import * as native from "yuke:process";

/** @typedef {import("yuke:process").ProcessExit} ProcessExit */
/** @typedef {{ cwd?: string, env?: Record<string, string>, workspaceRoot?: string }} SpawnOptions */
/** @typedef {{ onStdout(listener: (text: string) => void): void, onStderr(listener: (text: string) => void): void, write(text: string): Promise<void>, closeStdin(): void, kill(): boolean, exited: Promise<ProcessExit> }} ChildProcess */

/** @param {string[]} argv @param {SpawnOptions} [options] @returns {ChildProcess} */
export function spawn(argv, options = {}) {
  /** @type {[((text: string) => void)[], ((text: string) => void)[]]} */
  const listeners = [[], []];
  const env = options.env ? Object.entries(options.env).flat() : undefined;
  const child = native.spawn(argv, { ...(options.cwd !== undefined ? { cwd: options.cwd } : {}), ...(env ? { env } : {}) }, (stream, text) => {
    for (const listener of listeners[stream === 1 ? 0 : 1]) listener(text);
  }, options.workspaceRoot);
  return {
    onStdout(listener) { listeners[0].push(listener); },
    onStderr(listener) { listeners[1].push(listener); },
    write(text) { return native.write(child.id, text); },
    closeStdin() { native.closeStdin(child.id); },
    kill() { return native.kill(child.id); },
    exited: child.exited,
  };
}

// The longest line a child may send. A longer one is dropped up to its newline, so a stuck line cannot grow forever.
const MAX_LINE_CHARS = 1024 * 1024;

// Join chunks into lines and strip one CR before each LF, as MCP stdio framing does.
/** @param {(line: string) => void} onLine @returns {(text: string) => void} */
export function lines(onLine) {
  let rest = "";
  let dropping = false;
  return (text) => {
    if (dropping) {
      const end = text.indexOf("\n");
      if (end < 0) return;
      text = text.slice(end + 1);
      dropping = false;
    }
    rest += text;
    // Walk with a cursor and cut the tail once, so a chunk with many lines copies the tail one time.
    let start = 0;
    let end;
    try {
      while ((end = rest.indexOf("\n", start)) >= 0) {
        const line = rest.slice(start, end);
        start = end + 1;
        onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
      }
    } finally {
      rest = rest.slice(start);
      if (rest.length > MAX_LINE_CHARS) { rest = ""; dropping = true; }
    }
  };
}
