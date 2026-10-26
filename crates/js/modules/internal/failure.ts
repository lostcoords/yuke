/** The text forms of a thrown value, for its author. */

/** The text form of the thrown `error`. */
export function textOf(error: unknown): string {
  try {
    return String(error);
  } catch {
    return "a value without a text form";
  }
}

/** The text form of the thrown `error` for its author: an `Error` adds the frames of the plugin on the next lines. */
export function failureOf(error: unknown): string {
  const text = textOf(error);
  const stack = stackOf(error);
  if (stack === undefined) return text;
  // The frames of the host code tell the author nothing.
  const frames = stack.split("\n").filter((line) => line.trim() !== "" && !/\((yuke:[^()]*|native)\)$/.test(line));
  return frames.length === 0 ? text : `${text}\n${frames.join("\n")}`;
}

/** The stack of the thrown `error`, or `undefined` for a value with no stack or with a `stack` getter that throws. */
export function stackOf(error: unknown): string | undefined {
  if (!(error instanceof Error)) return undefined;
  try {
    const stack: unknown = error.stack;
    return typeof stack === "string" ? stack : undefined;
  } catch {
    return undefined;
  }
}
