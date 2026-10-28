/** The text helpers of `yuke:tui`, with the native width rules. Offsets are UTF-16 units. Widths are terminal cells. */
import { termFit, termGraphemes, termMeasure, termWrap } from "yuke:internal/native";

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
