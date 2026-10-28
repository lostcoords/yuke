/** The code of the public module `yuke:tui`. Its declaration is `types/tui.d.ts`, and the check at the end compares the two. */

import { TextEditor } from "yuke:internal/tui/editor";
import { parseKeys, strokeOf } from "yuke:internal/tui/keys";
import { stack } from "yuke:internal/tui/layout";
import { Markdown } from "yuke:internal/tui/markdown";
import { ScrollList } from "yuke:internal/tui/scroll";
import { fit, graphemes, measure, wrap } from "yuke:internal/tui/text";
import { TextView } from "yuke:internal/tui/text-view";

export { fit, graphemes, Markdown, measure, parseKeys, ScrollList, stack, strokeOf, TextEditor, TextView, wrap };

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
} satisfies typeof import("yuke:tui");
void declared;
