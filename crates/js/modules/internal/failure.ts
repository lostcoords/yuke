/**
 * The text form of the thrown `error` for its author: an `Error` adds the frames of the plugin on the next lines. Use
 * it for a fault of plugin code, such as a throw of a listener or a factory. A notice of a failed request of the host,
 * such as an open or a send, reads `String(error)`, because its frames tell the user nothing.
 */
export function failureOf(error: unknown): string {
  const text = String(error);
  const stack = stackOf(error);
  if (stack === undefined) return text;
  // The frames of the host code tell the author nothing.
  const frames = stack.split("\n").filter((line) => line.trim() !== "" && !/\((yuke:[^()]*|native)\)$/.test(line));
  return frames.length === 0 ? text : `${text}\n${frames.join("\n")}`;
}

/** The stack of the thrown `error`, or `undefined` for a value with no stack. */
export function stackOf(error: unknown): string | undefined {
  return error instanceof Error ? error.stack : undefined;
}
