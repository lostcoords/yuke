/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript, composer,
 * folds, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session,
 * the draft, the folds, and the scroll place of each pane.
 */

import { ChatDocument, STYLE, STYLES } from "yuke:internal/bundled/chat/transcript";
import type { EventsPage, PluginContext, ViewEvent } from "yuke:plugins";
import type { SessionId } from "yuke:protocol";
import type { Infer } from "yuke:tools";
import { Transcript } from "yuke:transcript";
import {
  type Canvas,
  type EditorState,
  type JsonValue,
  type Mount,
  type Placement,
  type Size,
  TextEditor,
  TextView,
  type Tui,
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

/** The count of saved events that a pane gets when it opens its session. Older events come in pages. */
const TAIL = 200;

/** The most saved events of one page of history. */
const PAGE = 100;

/** The item at the top of a scrolled transcript, and its row there. */
interface Viewport {
  readonly key: string;
  readonly row: number;
}

/**
 * The saved state of a pane: the session that it shows, the draft of its composer, its fold choices, and the place of
 * a transcript that does not follow the tail.
 */
interface PaneState {
  readonly session?: SessionId | undefined;
  readonly draft?: EditorState | undefined;
  readonly folds?: readonly (readonly [string, boolean])[] | undefined;
  readonly viewport?: Viewport | undefined;
}

export function apply(ctx: PluginContext<Options>): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const copyOnRelease = ctx.options.copyOnRelease ?? true;
  for (const [name, style] of Object.entries(STYLES)) tui.styles.set(name, style);
  tui.views.register("pane", (state, mount) => chatPane(ctx, tui, copyOnRelease, mount, paneState(state)));
  tui.panes.setDefault((mount, reason) =>
    chatPane(ctx, tui, copyOnRelease, mount, { session: reason === "start" ? tui.startup.session : undefined }),
  );
  return undefined;
}

/** Check the session, the folds, and the viewport of a saved `state`. A bad field throws a `TypeError`. The editor checks the draft. */
function paneState(state: unknown): PaneState {
  if (typeof state !== "object" || state === null) throw new TypeError("the state of a chat pane is an object");
  const saved = state as { readonly session?: unknown; readonly folds?: unknown; readonly viewport?: unknown };
  if (saved.session !== undefined && typeof saved.session !== "string") {
    throw new TypeError("the session of a chat pane is a session id");
  }
  const folds = saved.folds ?? [];
  const fold = (pair: unknown): boolean =>
    Array.isArray(pair) && pair.length === 2 && typeof pair[0] === "string" && typeof pair[1] === "boolean";
  if (!Array.isArray(folds) || !folds.every(fold))
    throw new TypeError("the folds of a chat pane are [key, open] pairs");
  const viewport = saved.viewport as Partial<Viewport> | undefined;
  const row = viewport?.row;
  if (viewport !== undefined && (typeof viewport.key !== "string" || !Number.isInteger(row) || (row as number) < 0)) {
    throw new TypeError("the viewport of a chat pane has a key and a row");
  }
  return state as PaneState;
}

/**
 * A chat pane: the transcript above a rule and the composer. The composer takes at most half the pane height. A pane
 * with a session holds its own handle until the mount closes.
 */
function chatPane(ctx: PluginContext<Options>, tui: Tui, copyOnRelease: boolean, mount: Mount, state: PaneState): View {
  const session = state.session;
  const transcript = new Transcript();
  const document = new ChatDocument(`session:${session ?? "new"}`, state.folds);
  // The events of the session change the transcript, and the next layout projects it once.
  let dirty = true;
  // The first snapshot came, so a page can load.
  let opened = false;
  let loading = false;
  // The oldest saved event is in the transcript.
  let complete = false;
  let historyError: string | undefined;
  // The saved place waits until its item loads.
  let restore = state.viewport;
  const changed = (): void => {
    dirty = true;
    tui.requestFrame();
  };

  /** Load one page: the newest part of a gap first, else the page before the first held event. */
  const load = async (): Promise<void> => {
    if (session === undefined || !opened || loading || historyError !== undefined) return;
    const gap = transcript.gap;
    const first = transcript.first;
    let page: EventsPage;
    if (gap !== undefined) page = { ...gap, limit: Math.min(PAGE, gap.limit) };
    else if (complete || first === undefined) return;
    else page = { before: first, limit: PAGE };
    loading = true;
    try {
      const events = await ctx.get("sessions").events(session, page);
      if (mount.signal.aborted) return;
      transcript.insert(events);
      // A page that adds nothing older ends the history, so a load never repeats it.
      if (gap === undefined && transcript.first === first) complete = true;
    } catch (error) {
      if (mount.signal.aborted) return;
      historyError = `the history did not load: ${String(error)}`;
    } finally {
      loading = false;
    }
    changed();
  };

  const group = {};
  const view = new TextView({
    document: document.project(transcript),
    role: "transcript",
    group,
    copyOnRelease,
    followTail: true,
    activate: (position) => {
      if (position.section === "title" && document.toggle(transcript, position.item)) changed();
    },
    requestOlder: load,
  });
  const draft = state.draft;
  const composer = new TextEditor({
    role: "composer",
    group,
    placeholder: "Message…",
    ...(draft === undefined ? {} : { state: draft }),
  });

  if (session !== undefined) {
    const event = (update: ViewEvent): void => {
      transcript.apply(update);
      if ("snapshot" in update) opened = true;
      changed();
      if (transcript.gap !== undefined) void load();
    };
    ctx
      .get("sessions")
      .open(session, { tail: TAIL, signal: mount.signal, event })
      .catch((error: unknown) => {
        if (!mount.signal.aborted) ctx.notify("error", `the session ${session} did not open: ${String(error)}`);
      });
  }

  // The layout keeps the row of the rule for the draw.
  let ruleRow = 0;
  return {
    layout(size: Size): readonly Placement[] {
      if (dirty) {
        dirty = false;
        view.setDocument(document.project(transcript));
      }
      const composerRows = Math.min(composer.heightFor(size.width), Math.floor(size.height / 2));
      ruleRow = Math.max(0, size.height - composerRows - 1);
      const placements = [
        { view, rect: { column: 0, row: 0, width: size.width, height: ruleRow } },
        { view: composer, rect: { column: 0, row: ruleRow + 1, width: size.width, height: composerRows } },
      ];
      // The view has rows only after its own first layout. The saved place waits for a height, then for its item or
      // the end of the history.
      if (restore !== undefined && opened && view.scroll.state.height > 0) {
        const key = restore.key;
        if (view.document.items.some((item) => item.key === key)) {
          // A row past the end of a changed item gives its first row.
          if (!view.scroll.scrollToItem(key, restore.row)) view.scroll.scrollToItem(key);
          restore = undefined;
        } else if (complete || historyError !== undefined) restore = undefined;
        else void load();
      }
      return placements;
    },
    draw(canvas: Canvas): void {
      if (canvas.height <= ruleRow) return;
      canvas.text(0, ruleRow, "─".repeat(canvas.width), RULE);
      // The rule shows a failed history load, so the text stays in sight at any scroll place.
      if (historyError !== undefined) canvas.text(1, ruleRow, ` ${historyError} `, STYLE.error);
      else if (view.scroll.state.changedBelow) canvas.text(1, ruleRow, " new output ↓ ", STYLE.hint);
    },
    initialFocus: composer,
    snapshot: () => {
      const scroll = view.scroll.state;
      const viewport = restore ?? (scroll.following ? undefined : scroll.anchor);
      return {
        type: "pane",
        state: {
          ...(session === undefined ? {} : { session }),
          draft: composer.state as unknown as JsonValue,
          folds: document.folds,
          ...(viewport === undefined ? {} : { viewport: { key: viewport.key, row: viewport.row } }),
        },
      };
    },
  };
}
