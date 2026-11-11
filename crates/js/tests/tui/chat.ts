// The fixtures of the tests of the bundled chat: a fake session store, a chat in a frame, and the rows of a frame.

import type { ChatService } from "yuke:chat";
import { apply } from "yuke:internal/bundled/chat";
import type { EventsPage, SessionHandle, ViewEvent } from "yuke:plugins";
import type {
  Block,
  Commit,
  InteractionResponse,
  Job,
  ListCatalogResult,
  ListSessionsParams,
  SessionRow,
  SessionSettings,
  SessionUpdate,
  StoredEvent,
} from "yuke:protocol";
import { createFrame, type FrameTest, folder } from "yuke:test";
import { type MouseEvent, TextView } from "yuke:tui";
import { rows } from "./rows.ts";

const MODIFIERS = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

export function mouse(column: number, row: number, action: MouseEvent["action"]): MouseEvent {
  return { type: "mouse", column, row, button: "left", action, modifiers: MODIFIERS };
}

/** The cell style that the default theme gives to the style group `group`, read from a draw of one cell. */
export function themeStyle(group: string) {
  using frame = createFrame({ width: 1, height: 1 }, () => ({
    draw(canvas) {
      canvas.text(0, 0, "x", group);
    },
  }));
  return frame.draw().cells[0]?.[0]?.style ?? {};
}

/** One call of `sessions.open`: the session, the tail, the signal of its handle, and its event callback. */
interface Opened {
  readonly id: string;
  readonly tail: number;
  readonly signal: AbortSignal;
  readonly onEvent: (event: ViewEvent) => void;
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
  for (let seq = 2; seq <= last; seq += 1) saved.push(commit(seq, [{ assistant_text: { text: `reply ${seq}` } }]));
  return saved;
}

/**
 * Sessions whose saved events are `saved`: an open gives a snapshot of the last `tail`, and `events` gives a page.
 * An open of the session `missing` rejects. With `failing`, each page rejects.
 */
export function fakeSessions(saved: StoredEvent[] = []) {
  const opened: Opened[] = [];
  const pages: EventsPage[] = [];
  const created: SessionSettings[] = [];
  const inputs: (readonly Block[])[] = [];
  const changes: SessionSettings[] = [];
  const removals: number[] = [];
  const responses: [number, InteractionResponse][] = [];
  const blobs: number[][] = [];
  // The saved sessions of `list` and `get`, newest first, and the params of each list.
  const rows: SessionRow[] = [];
  const lists: ListSessionsParams[] = [];
  const renames: [string, string][] = [];
  // The end of each handle, by its open. A close by another client ends the handles of its session.
  const ends = new Map<Opened, AbortController>();
  /**
   * `failing` fails each page. `accept` holds each input until it settles, and a rejection refuses the input.
   * `cancels` counts the cancels of the handles. `removal` holds each removal until it settles, and `removed` is its
   * answer. `refuseAnswer` makes each answer throw, as for a question that another client answered. `store` holds each
   * put of a blob until it settles, and a rejection refuses the blob. `jobs` are the running jobs of each handle.
   */
  const state: {
    failing: boolean;
    accept: Promise<void> | undefined;
    cancels: number;
    backgrounds: number;
    movable: boolean;
    openFails: number;
    refuseSettings: boolean;
    renameFails: boolean;
    removal: Promise<void> | undefined;
    removed: boolean;
    refuseAnswer: boolean;
    store: Promise<void> | undefined;
    jobs: readonly Job[];
  } = {
    failing: false,
    accept: undefined,
    cancels: 0,
    backgrounds: 0,
    movable: false,
    openFails: 0,
    refuseSettings: false,
    renameFails: false,
    removal: undefined,
    removed: true,
    refuseAnswer: false,
    jobs: [],
    store: undefined,
  };
  /** Give each live handle of session `id` the live update `update`. */
  const deliver = (id: string, update: SessionUpdate): void => {
    for (const [entry, end] of ends) if (entry.id === id && !end.signal.aborted) entry.onEvent({ update });
  };
  return {
    opened,
    pages,
    created,
    inputs,
    changes,
    removals,
    responses,
    blobs,
    state,
    rows,
    lists,
    renames,
    /** The rows of the folder `params.cwd`, or of each folder. A list gives at most `params.limit` rows, else 50. */
    async list(params: ListSessionsParams = {}): Promise<{ sessions: SessionRow[] }> {
      lists.push(params);
      const cwd = params.cwd;
      const shown = rows.filter((row) => cwd === undefined || cwd === null || row.session.cwd === cwd);
      return { sessions: shown.slice(0, params.limit ?? 50) };
    },
    async get(id: string): Promise<SessionRow> {
      const row = rows.find((candidate) => candidate.session.sessionId === id);
      if (row === undefined) throw new Error(`no session ${id}`);
      return row;
    },
    async rename(id: string, title: string): Promise<void> {
      if (state.renameFails) throw new Error("rename failed");
      const index = rows.findIndex((candidate) => candidate.session.sessionId === id);
      if (index < 0) throw new Error(`no session ${id}`);
      const row = rows[index];
      if (row === undefined) throw new Error(`no session ${id}`);
      rows[index] = { ...row, session: { ...row.session, title } };
      renames.push([id, title]);
    },
    async create(settings: SessionSettings): Promise<string> {
      created.push(settings);
      return "s-new";
    },
    open(id: string, open: Opened): Promise<Partial<SessionHandle>> {
      const entry = { id, tail: open.tail, signal: open.signal, onEvent: open.onEvent };
      opened.push(entry);
      const end = new AbortController();
      ends.set(entry, end);
      open.signal.addEventListener("abort", () => end.abort(), { once: true });
      if (id === "missing") return Promise.reject(new Error("no session missing"));
      if (state.openFails > 0) {
        state.openFails -= 1;
        return Promise.reject(new Error("busy"));
      }
      open.onEvent({ snapshot: { settings: SETTINGS, updates: saved.slice(-open.tail) } });
      return Promise.resolve({
        signal: end.signal,
        async sendMessage(content: readonly Block[]) {
          inputs.push(content);
          await state.accept;
          return inputs.length;
        },
        moveJobsToBackground() {
          state.backgrounds += 1;
        },
        canMoveJobsToBackground: () => state.movable,
        cancel() {
          state.cancels += 1;
        },
        jobs: () => state.jobs,
        async setSettings(settings: SessionSettings) {
          if (state.refuseSettings) throw new Error("a turn runs");
          changes.push(settings);
        },
        // As the host does, a removal sends its update before its answer.
        async removeInput(inputId: number) {
          removals.push(inputId);
          await state.removal;
          if (state.removed) deliver(id, { sessionUpdate: "input_removed", inputId });
          return state.removed;
        },
        async putBlob(bytes: Uint8Array) {
          blobs.push([...bytes]);
          await state.store;
          return { digest: `d${blobs.length}`, len: bytes.length };
        },
        respond(interactionId: number, response: InteractionResponse) {
          if (state.refuseAnswer) throw new Error(`no open question ${interactionId}`);
          responses.push([interactionId, response]);
          // As the host does, the first answer closes the question for each handle, later through the event feed.
          queueMicrotask(() => deliver(id, { sessionUpdate: "interaction_closed", interactionId }));
        },
      });
    },
    async events(_id: string, page: EventsPage): Promise<StoredEvent[]> {
      pages.push(page);
      if (state.failing) throw new Error("disk");
      const before = page.before ?? Number.POSITIVE_INFINITY;
      return saved.filter((event) => event.seq < before).slice(-page.limit);
    },
    /** Give each live handle of session `id`, by default the session of the last open, the live update `update`. */
    push(update: SessionUpdate, id = opened.at(-1)?.id): void {
      if ("seq" in update) saved.push(update);
      if (id !== undefined) deliver(id, update);
    },
    /** End each handle of session `id`, as a close by another client does. */
    close(id: string): void {
      for (const [entry, end] of ends) if (entry.id === id) end.abort();
    },
  };
}

/** Load the chat into `frame` with `sessions`. Return the surface of the chat, each notice, and its service. */
export async function loadChat(
  frame: FrameTest,
  sessions: ReturnType<typeof fakeSessions> = fakeSessions(),
  catalog: { readonly list: () => Promise<ListCatalogResult> } = { list: async () => CATALOG },
) {
  const surface = frame.surface("chat");
  const notices: string[] = [];
  const services: Record<string, unknown> = { tui: surface.tui, sessions, catalog };
  const provided = new Map<string, unknown>();
  const facts = new Map<string, Set<(data: unknown) => void>>();
  await apply({
    get: (name: string) => services[name],
    provide: (name: string, value: unknown) => provided.set(name, value),
    on: (event: string, listener: (data: unknown) => void) => {
      const listeners = facts.get(event) ?? new Set();
      facts.set(event, listeners.add(listener));
      return () => listeners.delete(listener);
    },
    options: {},
    signal: surface.signal,
    dataDir: folder(),
    notify: (level: string, text: string) => notices.push(`${level} ${text}`),
  } as never);
  const transcript = (): TextView =>
    surface.tui.widgets.list().find((mount) => mount.widget instanceof TextView)?.widget as TextView;
  const chat = provided.get("chat") as ChatService;
  /** Send the event `event` with its data to the listeners of the chat. */
  const fact = (event: string, data: unknown): void => {
    for (const listener of facts.get(event) ?? []) listener(data);
  };
  return { tui: surface.tui, surface, opened: sessions.opened, notices, transcript, chat, fact };
}

/** One ready provider `p` with the model `m` (levels default, off, high) and the model `n` (levels default, low). */
export const CATALOG = {
  providers: [
    {
      id: "p",
      name: "P",
      state: { kind: "ready", credential: { kind: "none" } },
      models: [
        {
          id: "m",
          name: "M",
          reasoning: [
            { level: "default", settings: { thinking: null, effort: null } },
            { level: "off", settings: { thinking: "off", effort: null } },
            { level: "high", settings: { thinking: null, effort: "high" } },
          ],
        },
        {
          id: "n",
          name: "N",
          reasoning: [
            { level: "default", settings: { thinking: null, effort: null } },
            { level: "low", settings: { thinking: null, effort: "low" } },
          ],
        },
      ],
    },
  ],
} as unknown as ListCatalogResult;

export const EMPTY = { text: "", selection: { anchor: 0, head: 0 }, spans: [] };

/** A fixed `Date.now` until the end of the scope. A test moves it with `now`, so a slow machine changes no duration. */
export function fixedClock(): { now: number } & Disposable {
  const real = Date.now;
  const clock = {
    now: 1_000_000,
    [Symbol.dispose]: () => {
      Date.now = real;
    },
  };
  Date.now = () => clock.now;
  return clock;
}

/** The rows of the transcript of `frame` above the rule on the composer, which is the last rule but one. */
export function transcriptRows(frame: FrameTest): string[] {
  const shown = rows(frame.frame);
  const close = shown.findLastIndex((row) => row.startsWith("─"));
  const rule = shown.slice(0, close).findLastIndex((row) => row.startsWith("─"));
  return shown.slice(0, rule);
}

/** Press and release the left button at `row` and `column` of `frame`. */
export function click(frame: FrameTest, column: number, row: number): void {
  frame.mouse(mouse(column, row, "press"));
  frame.mouse(mouse(column, row, "release"));
}
