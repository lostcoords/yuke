/**
 * The rows of a diff block of a tool result: the path, then each line of the patch in the style of its kind. A hunk
 * header gives the numbers of its lines, and a `⋮` replaces the header of each later hunk. The source holds the whole
 * patch. A copy gives the path and the lines with their signs, without the numbers, the headers, and the `⋮`.
 */

import { rangedRows, STYLE, shifted } from "yuke:internal/chat/rows";
import type { TextRow } from "yuke:tui";

/** A hunk header: the first old line and the first new line. Each count can be absent. */
const HUNK_HEADER = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/;

/** One line of a patch. A `\ No newline` mark has no number. */
interface PatchLine {
  readonly from: number;
  readonly text: string;
  readonly style: string;
  readonly number: number | undefined;
  /** True for the header of a later hunk. A `⋮` row replaces it. */
  readonly gap?: boolean;
}

/** The source of the block `path` with `patch`: the path on the first line, then the patch. */
export function diffSource(path: string, patch: string): string {
  return `${path}\n${patch}`;
}

/** The rows of the block `path` with `patch` at `width`. Each source offset indexes `diffSource(path, patch)`. */
export function diffRows(path: string, patch: string, width: number): TextRow[] {
  const lines = patchLines(patch, path.length + 1);
  let digits = 0;
  for (const line of lines) if (line.number !== undefined) digits = Math.max(digits, String(line.number).length);
  const rows = rangedRows(path, width, [{ from: 0, to: path.length, style: STYLE.diffHeader, link: path }]);
  for (const line of lines) {
    if (line.gap === true) {
      const text = `${" ".repeat(digits + 2)}⋮`;
      const source = { kind: "replacement", from: line.from, to: line.from + line.text.length } as const;
      // An empty join keeps this row out of a copy.
      rows.push({ segments: [{ text, style: STYLE.diffGutter, source, copy: false }], join: "" });
      continue;
    }
    const wrapped = rangedRows(line.text, width - digits - 1, [{ from: 0, to: line.text.length, style: line.style }]);
    for (const [at, row] of wrapped.entries()) {
      const moved = shifted(row, line.from);
      const number = at === 0 && line.number !== undefined ? String(line.number) : "";
      const gutter = { text: `${number.padStart(digits)} `, style: STYLE.diffGutter, copy: false };
      rows.push({ segments: [...moved.segments.slice(0, 1), gutter, ...moved.segments.slice(1)], join: moved.join });
    }
  }
  return rows;
}

/** The lines of `patch` that have a row. The first line of `patch` starts at the source offset `start`. */
function patchLines(patch: string, start: number): PatchLine[] {
  const lines: PatchLine[] = [];
  let oldLine: number | undefined;
  let newLine = 0;
  let from = start;
  // The last line end of a patch does not make an empty row.
  for (const text of (patch.endsWith("\n") ? patch.slice(0, -1) : patch).split("\n")) {
    const hunk = HUNK_HEADER.exec(text);
    if (hunk !== null) {
      if (oldLine !== undefined) lines.push({ from, text, style: STYLE.diffGutter, number: undefined, gap: true });
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
    } else {
      const sign = text[0];
      const style = sign === "+" ? STYLE.diffAdd : sign === "-" ? STYLE.diffDelete : STYLE.diffContext;
      let number: number | undefined;
      if (oldLine !== undefined && sign !== "\\") {
        number = sign === "-" ? oldLine : newLine;
        if (sign !== "+") oldLine += 1;
        if (sign !== "-") newLine += 1;
      }
      lines.push({ from, text, style, number });
    }
    from += text.length + 1;
  }
  return lines;
}
