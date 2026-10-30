/**
 * The rows of a diff block of a tool result: the path, then each line of the patch in the style of its kind. A copy
 * gives the path and the patch as they are.
 */

import { type Range, rangedRows, STYLE } from "yuke:internal/chat/rows";
import type { TextRow } from "yuke:tui";

/** The source of the block `path` with `patch`: the path on the first line, then the patch. */
export function diffSource(path: string, patch: string): string {
  return `${path}\n${patch}`;
}

/** The rows of the block `path` with `patch` at `width`. Each source offset indexes `diffSource(path, patch)`. */
export function diffRows(path: string, patch: string, width: number): TextRow[] {
  const ranges: Range[] = [{ from: 0, to: path.length, style: STYLE.diffHeader, link: path }];
  let from = path.length + 1;
  for (const line of patch.split("\n")) {
    const style = lineStyle(line);
    if (style !== undefined) ranges.push({ from, to: from + line.length, style });
    from += line.length + 1;
  }
  return rangedRows(diffSource(path, patch), width, ranges);
}

/** The style of a line of a patch: a file header, a hunk header, an added line, or a removed line. Context has none. */
function lineStyle(line: string): string | undefined {
  // The file headers come first, because they start with the marks of the lines.
  if (line.startsWith("+++") || line.startsWith("---")) return STYLE.diffHeader;
  if (line.startsWith("@@")) return STYLE.diffHunk;
  if (line.startsWith("+")) return STYLE.diffAdd;
  if (line.startsWith("-")) return STYLE.diffDelete;
  return undefined;
}
