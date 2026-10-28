/** The code of the public module `yuke:tui`. Its declaration is `types/tui.d.ts`, and the check at the end compares the two. */

import { TextEditor } from "yuke:internal/tui/editor";
import { parseKeys, strokeOf } from "yuke:internal/tui/keys";
import { stack } from "yuke:internal/tui/layout";
import { fit, graphemes, measure, wrap } from "yuke:internal/tui/text";

export { fit, graphemes, measure, parseKeys, stack, strokeOf, TextEditor, wrap };

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
} satisfies typeof import("yuke:tui");
void declared;
