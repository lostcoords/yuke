/**
 * The bundled plugin `sessions`. Its command `sessions:open` lists the recent sessions in a picker. Enter shows the
 * chosen session in a chat pane through the service `chat`. The list starts with the folder of the focused pane. Tab
 * switches to the sessions of every folder.
 */

import type { PluginContext } from "yuke:plugins";
import type { SessionActivity, SessionRow } from "yuke:protocol";
import { fuzzyMatch, Picker, type PickerMatch, strokeOf, type Tui, type View } from "yuke:tui";

/** The list shows at most this count of sessions. */
const PAGE = 100;

/** The overlay has at most this count of rows, with its head row. */
const ROWS = 13;

/** The mark of each activity: a running turn, an open session, and a closed one. */
const MARK: Readonly<Record<SessionActivity, string>> = { running: "●", idle: "○", closed: " " };

const HEAD = Object.freeze({ dim: true });

export function apply(ctx: PluginContext): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  tui.commands.add({
    name: "open",
    description: "Show a recent session in the pane",
    run: () =>
      open(ctx, tui).catch((error: unknown) => ctx.notify("error", `the sessions did not load: ${String(error)}`)),
  });
  return undefined;
}

/** The age of the time `at`, in milliseconds since the Unix epoch, at the time `now`: `now`, `5m`, `3h`, or `2d`. */
function age(at: number, now: number): string {
  const minutes = Math.floor((now - at) / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 24 * 60) return `${Math.floor(minutes / 60)}h`;
  return `${Math.floor(minutes / (24 * 60))}d`;
}

/** The label of `row`: its activity mark and its first prompt on one line. */
function labelOf(row: SessionRow): string {
  const preview = row.session.preview?.replaceAll(/\s+/g, " ") ?? "(no message)";
  return `${MARK[row.activity]} ${preview}`;
}

/**
 * The rows that match `query`. A fuzzy match of the label comes first, by score. A row whose model, folder, or id holds
 * the query follows, in list order.
 */
function rank(query: string, rows: readonly SessionRow[]): readonly PickerMatch<SessionRow>[] {
  if (query === "") return rows.map((item) => ({ item }));
  const lower = query.toLowerCase();
  const fuzzy: { readonly match: PickerMatch<SessionRow>; readonly score: number; readonly index: number }[] = [];
  const plain: PickerMatch<SessionRow>[] = [];
  for (const [index, item] of rows.entries()) {
    const match = fuzzyMatch(query, labelOf(item));
    const session = item.session;
    if (match !== undefined) fuzzy.push({ match: { item, ranges: match.ranges }, score: match.score, index });
    else if ([session.model.model, session.cwd, session.sessionId].some((text) => text.toLowerCase().includes(lower))) {
      plain.push({ item });
    }
  }
  fuzzy.sort((a, b) => b.score - a.score || a.index - b.index);
  return [...fuzzy.map((entry) => entry.match), ...plain];
}

/**
 * Open the list over the focused pane. The scope starts with the folder of the session of that pane. The ages are the
 * ones at the time of the load.
 */
async function open(ctx: PluginContext, tui: Tui): Promise<void> {
  const chat = ctx.get("chat");
  const sessions = ctx.get("sessions");
  const pane = tui.panes.active?.view;
  const shown = pane === undefined ? undefined : chat.session(pane);
  // Another client can remove the session of the pane, and the list then starts with the start folder.
  const folder =
    shown === undefined
      ? tui.startup.cwd
      : await sessions.get(shown).then(
          (row) => row.session.cwd,
          () => tui.startup.cwd,
        );
  let all = false;
  // Each load counts, so the answer of an earlier scope does not replace the list of a later one.
  let loads = 0;
  let loadedAt = Date.now();
  const picker = new Picker<SessionRow>({
    items: [],
    key: (row) => row.session.sessionId,
    label: labelOf,
    detail: (row) => {
      const session = row.session;
      const place = all ? ` · ${session.cwd.split("/").findLast((part) => part !== "") ?? session.cwd}` : "";
      return `${age(session.updatedAt, loadedAt)} · ${session.model.model}${place}`;
    },
    rank,
    choose: (row) => {
      overlay.close();
      const id = row.session.sessionId;
      chat.show(id).catch((error: unknown) => ctx.notify("error", `the session ${id} did not show: ${String(error)}`));
    },
    cancel: () => overlay.close(),
  });
  const view: View = {
    layout: (size) => [
      { view: picker, rect: { column: 0, row: 1, width: size.width, height: Math.max(0, size.height - 1) } },
    ],
    draw: (canvas) => {
      const scope = all ? "every folder · tab: this folder" : `${folder} · tab: every folder`;
      canvas.text(1, 0, scope, HEAD);
    },
    initialFocus: picker.input,
  };
  const overlay = tui.overlay(() => view, {
    place: (size) => {
      const height = Math.min(ROWS, size.height);
      return { column: 0, row: size.height - height, width: size.width, height };
    },
  });
  /** Load the list of the scope. A failure closes the list and gives a notice. */
  const load = async (): Promise<void> => {
    loads += 1;
    const current = loads;
    let page: Awaited<ReturnType<typeof sessions.list>>;
    try {
      page = await sessions.list(all ? { limit: PAGE } : { cwd: folder, limit: PAGE });
    } catch (error) {
      if (current !== loads || overlay.signal.aborted) return;
      overlay.close();
      ctx.notify("error", `the sessions did not load: ${String(error)}`);
      return;
    }
    if (current !== loads || overlay.signal.aborted) return;
    loadedAt = Date.now();
    picker.setItems(page.sessions);
    tui.requestFrame();
  };
  picker.input.extend(overlay.signal).onKey((event) => {
    if (strokeOf(event) !== "tab") return false;
    all = !all;
    void load();
    return true;
  });
  void load();
}
