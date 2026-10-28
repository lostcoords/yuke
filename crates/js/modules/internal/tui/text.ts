/** The text helpers of `yuke:tui`, with the native width rules. Offsets are UTF-16 units. Widths are terminal cells. */
import { termFit, termGraphemes, termMeasure, termWrap } from "yuke:internal/native";
import type { Bias, ColumnUnit } from "yuke:tui";

export function measure(text: string): number {
  return termMeasure(String(text).toWellFormed());
}

export function graphemes(text: string): Int32Array {
  return termGraphemes(String(text).toWellFormed());
}

export function fit(text: string, cells: number): number {
  return termFit(String(text).toWellFormed(), cells);
}

export function wrap(text: string, width: number, head = 0): Int32Array {
  return termWrap(String(text).toWellFormed(), width, head);
}

/**
 * The UTF-16 offset in `text` at `column`, in cells or graphemes. A column inside a grapheme snaps to its start, or to
 * its end for `after`. A column past the text gives its length.
 */
export function offsetAtColumn(text: string, column: number, unit: ColumnUnit, bias: Bias): number {
  const triples = graphemes(text);
  let cells = 0;
  for (let at = 0; at < triples.length; at += 3) {
    const width = unit === "cell" ? (triples[at + 2] as number) : 1;
    const start = triples[at] as number;
    if (column === cells) return start;
    if (column < cells + width) return bias === "before" ? start : start + (triples[at + 1] as number);
    cells += width;
  }
  return text.length;
}
