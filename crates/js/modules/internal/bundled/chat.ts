/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript view (empty
 * until the transcript comes), composer, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session and the
 * draft of each pane.
 */

import type { PluginContext } from "yuke:plugins";
import type { SessionId } from "yuke:protocol";
import type { Infer } from "yuke:tools";
import {
  type Canvas,
  type EditorState,
  type JsonValue,
  type Mount,
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

/** The saved state of a pane: the session that it shows, and the draft of its composer. */
interface PaneState {
  readonly session?: SessionId | undefined;
  readonly draft?: EditorState | undefined;
}

export function apply(ctx: PluginContext<Options>): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const copyOnRelease = ctx.options.copyOnRelease ?? true;
  tui.views.register("pane", (state, mount) => {
    if (typeof state !== "object" || state === null) throw new TypeError("the state of a chat pane is an object");
    const saved = state as { readonly session?: unknown; readonly draft?: EditorState };
    if (saved.session !== undefined && typeof saved.session !== "string") {
      throw new TypeError("the session of a chat pane is a session id");
    }
    return chatPane(ctx, copyOnRelease, mount, { session: saved.session, draft: saved.draft });
  });
  tui.panes.setDefault((mount, reason) =>
    chatPane(ctx, copyOnRelease, mount, { session: reason === "start" ? tui.startup.session : undefined }),
  );
  return undefined;
}

/**
 * A chat pane: the transcript above a rule and the composer. The composer takes at most half the pane height. A pane
 * with a session holds its own handle until the mount closes.
 */
function chatPane(ctx: PluginContext<Options>, copyOnRelease: boolean, mount: Mount, state: PaneState): View {
  const session = state.session;
  if (session !== undefined) {
    // The pane draws no transcript yet, so it takes no events.
    ctx
      .get("sessions")
      .open(session, { tail: 0, signal: mount.signal, event() {} })
      .catch((error: unknown) => {
        if (!mount.signal.aborted) ctx.notify("error", `the session ${session} did not open: ${String(error)}`);
      });
  }
  const draft = state.draft;
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
    snapshot: () => ({
      type: "pane",
      state: { ...(session === undefined ? {} : { session }), draft: composer.state as unknown as JsonValue },
    }),
  };
}
