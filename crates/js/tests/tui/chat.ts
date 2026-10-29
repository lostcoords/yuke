// The fixtures of the tests of the bundled chat: a fake session store, a chat in a frame, and the rows of a frame.

import { apply } from "yuke:internal/bundled/chat";
import type { EventsPage, ViewEvent } from "yuke:plugins";
import type { Block, Commit, SessionSettings, SessionUpdate, StoredEvent } from "yuke:protocol";
import type { FrameTest } from "yuke:test";
import { type MouseEvent, TextView } from "yuke:tui";

export const MODIFIERS = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

export function mouse(column: number, row: number, action: MouseEvent["action"]): MouseEvent {
  return { type: "mouse", column, row, button: "left", action, modifiers: MODIFIERS };
}

/** One call of `sessions.open`: the session, the tail, the signal of its handle, and its event callback. */
export interface Opened {
  readonly id: string;
  readonly tail: number;
  readonly signal: AbortSignal;
  readonly event: (event: ViewEvent) => void;
}

export const SETTINGS: SessionSettings = {
  model: { provider: "p", model: "m" },
  settings: {
    maxOutputTokens: null,
    reasoning: { thinking: null, effort: null },
    temperature: null,
    topP: null,
    toolChoice: "auto",
    outputSchema: null,
  },
  cwd: "/w",
};

/** The saved event `seq` with `blocks` and the other commit fields of `fields`. */
export function commit(seq: number, blocks: Block[], fields: Partial<Commit> = {}): StoredEvent {
  return {
    seq,
    sessionUpdate: "commit",
    commit: { replaced: null, blocks, answer: null, end: null, ...fields },
    consumed: [],
  };
}

/** A session with the settings event 1, then a reply `reply <seq>` in each event up to `last`. */
export function replies(last: number): StoredEvent[] {
  const saved: StoredEvent[] = [{ seq: 1, sessionUpdate: "settings", ...SETTINGS }];
  for (let seq = 2; seq <= last; seq += 1) saved.push(commit(seq, [{ assistant_text: `reply ${seq}` }]));
  return saved;
}

/**
 * Sessions whose saved events are `saved`: an open gives a snapshot of the last `tail`, and `events` gives a page.
 * An open of the session `missing` rejects. With `failing`, each page rejects.
 */
export function fakeSessions(saved: StoredEvent[] = []) {
  const opened: Opened[] = [];
  const pages: EventsPage[] = [];
  const state = { failing: false };
  return {
    opened,
    pages,
    state,
    open(id: string, open: Opened): Promise<object> {
      opened.push({ id, tail: open.tail, signal: open.signal, event: open.event });
      if (id === "missing") return Promise.reject(new Error("no session missing"));
      open.event({ snapshot: { settings: SETTINGS, updates: saved.slice(-open.tail) } });
      return Promise.resolve({});
    },
    async events(_id: string, page: EventsPage): Promise<StoredEvent[]> {
      pages.push(page);
      if (state.failing) throw new Error("disk");
      const before = page.before ?? Number.POSITIVE_INFINITY;
      return saved.filter((event) => event.seq < before).slice(-page.limit);
    },
    /** Give the last handle the live update `update`. */
    push(update: SessionUpdate): void {
      if ("seq" in update) saved.push(update);
      opened.at(-1)?.event({ update });
    },
  };
}

/** Load the chat into `frame` with `options` and `sessions`. Return the surface of the chat and each notice. */
export function loadChat(
  frame: FrameTest,
  options: { readonly copyOnRelease?: boolean } = {},
  sessions: ReturnType<typeof fakeSessions> = fakeSessions(),
) {
  const surface = frame.surface("chat");
  const notices: string[] = [];
  apply({
    get: (name: string) => (name === "tui" ? surface.tui : sessions),
    options,
    notify: (level: string, text: string) => notices.push(`${level} ${text}`),
  } as never);
  const transcript = (): TextView =>
    surface.tui.widgets.list().find((mount) => mount.widget instanceof TextView)?.widget as TextView;
  return { tui: surface.tui, opened: sessions.opened, notices, transcript };
}

export const EMPTY = { text: "", selection: { anchor: 0, head: 0 }, spans: [] };

/** Wait for one timer of no delay, so the jobs before it run, such as the end of a page load. */
export function settle(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

export function rows(frame: FrameTest): string[] {
  return frame.frame.cells.map((row) =>
    row
      .map((cell) => cell.text || " ")
      .join("")
      .trimEnd(),
  );
}

/** The rows of the transcript of `frame` above its rule, which is the row before the last. */
export function transcriptRows(frame: FrameTest): string[] {
  return rows(frame).slice(0, -2);
}

/** Press and release the left button at `row` and `column` of `frame`. */
export function click(frame: FrameTest, column: number, row: number): void {
  frame.mouse(mouse(column, row, "press"));
  frame.mouse(mouse(column, row, "release"));
}
