/**
 * The name of the source `source` for the user. The prefix `host:` marks a source inside yuke, and the protocol keeps it.
 * The user does not need this mark.
 */
export function sourceName(source: string): string {
  return source.replace(/^host:/, "");
}
