/** The code of the public module `yuke:tui`. Its declaration is `types/tui.d.ts`, and the check at the end compares the two. */

import { TextEditor } from "yuke:internal/tui/editor";
import { fuzzyMatch } from "yuke:internal/tui/fuzzy";
import { parseKeys, strokeOf } from "yuke:internal/tui/keys";
import { stack } from "yuke:internal/tui/layout";
import { Markdown } from "yuke:internal/tui/markdown";
import { Picker } from "yuke:internal/tui/picker";
import { ScrollList } from "yuke:internal/tui/scroll";
import { fit, graphemes, measure, wrap as wrapPacked } from "yuke:internal/tui/text";
import { TextView } from "yuke:internal/tui/text-view";
import type { WrappedRow } from "yuke:tui";

export {
  fit,
  fuzzyMatch,
  graphemes,
  Markdown,
  measure,
  Picker,
  parseKeys,
  ScrollList,
  stack,
  strokeOf,
  TextEditor,
  TextView,
};

// A plugin wraps a few rows at a time, so objects cost little here. The editor and the text view keep the packed form.
export function wrap(text: string, width: number, head?: number): WrappedRow[] {
  const packed = wrapPacked(text, width, head);
  const rows: WrappedRow[] = [];
  for (let at = 0; at < packed.length; at += 3) {
    rows.push({ start: packed[at] as number, end: packed[at + 1] as number, soft: packed[at + 2] === 1 });
  }
  return rows;
}

// The check against `types/tui.d.ts` keeps this code and the declarations of the authors in step.
const declared = {
  measure,
  graphemes,
  fit,
  wrap,
  parseKeys,
  strokeOf,
  stack,
  TextEditor,
  Markdown,
  ScrollList,
  TextView,
  fuzzyMatch,
  Picker,
} satisfies typeof import("yuke:tui");
void declared;
