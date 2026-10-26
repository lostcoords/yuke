/** The code of the public module `yuke:tui`. Its declaration is `types/tui.d.ts`, and the check at the end compares the two. */

import { termFit, termGraphemes, termMeasure, termWrap } from "yuke:internal/native";
import { parseKeys, strokeOf } from "yuke:internal/tui/keys";

export { parseKeys, strokeOf };

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

// The check against `types/tui.d.ts` keeps this code and the declarations of the authors in step.
const declared = { measure, graphemes, fit, wrap, parseKeys, strokeOf } satisfies typeof import("yuke:tui");
void declared;
