/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript and
 * composer, and a reload keeps its draft.
 */

import type { PluginContext } from "yuke:plugins";
import type { Infer } from "yuke:tools";
import {
  type Canvas,
  type EditorState,
  type JsonValue,
  type Placement,
  type Size,
  TextEditor,
  TextView,
  type View,
} from "yuke:tui";

export const optionsSchema = {
  type: "object",
  properties: {
    copyOnRelease: {
      type: "boolean",
      description: "Copy a mouse selection of the transcript when the button goes up. The default is true.",
    },
  },
} as const;

type Options = Infer<typeof optionsSchema>;

const RULE = Object.freeze({ dim: true });

export function apply(ctx: PluginContext<Options>): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const copyOnRelease = ctx.options.copyOnRelease ?? true;
  tui.views.register("pane", (state) => {
    if (typeof state !== "object" || state === null) throw new TypeError("the state of a chat pane is an object");
    return chatPane(copyOnRelease, (state as { draft?: EditorState }).draft);
  });
  tui.panes.setDefault(() => chatPane(copyOnRelease, undefined));
  return undefined;
}

/** A chat pane: the transcript above a rule and the composer. The composer takes at most half the pane height. */
function chatPane(copyOnRelease: boolean, draft: EditorState | undefined): View {
  const group = {};
  const transcript = new TextView({ document: { key: "chat", items: [] }, role: "transcript", group, copyOnRelease });
  const composer = new TextEditor({
    role: "composer",
    group,
    placeholder: "Message…",
    ...(draft === undefined ? {} : { state: draft }),
  });
  // The layout keeps the row of the rule for the draw.
  let ruleRow = 0;
  return {
    layout(size: Size): readonly Placement[] {
      const composerRows = Math.min(composer.heightFor(size.width), Math.floor(size.height / 2));
      ruleRow = Math.max(0, size.height - composerRows - 1);
      return [
        { view: transcript, rect: { column: 0, row: 0, width: size.width, height: ruleRow } },
        { view: composer, rect: { column: 0, row: ruleRow + 1, width: size.width, height: composerRows } },
      ];
    },
    draw(canvas: Canvas): void {
      if (canvas.height > ruleRow) canvas.text(0, ruleRow, "─".repeat(canvas.width), RULE);
    },
    initialFocus: composer,
    snapshot: () => ({ type: "pane", state: { draft: composer.state as unknown as JsonValue } }),
  };
}
