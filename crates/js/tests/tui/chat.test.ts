// The bundled chat pane in a frame: the default pane of each split, its own draft and session handle, a reload, and its
// options.

import { apply } from "yuke:internal/bundled/chat";
import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { type MouseEvent, TextView } from "yuke:tui";

const MODIFIERS = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

function mouse(column: number, row: number, action: MouseEvent["action"]): MouseEvent {
  return { type: "mouse", column, row, button: "left", action, modifiers: MODIFIERS };
}

/** One call of `sessions.open`: the session and the signal of its handle. */
interface Opened {
  readonly id: string;
  readonly tail: number;
  readonly signal: AbortSignal;
}

/**
 * Load the chat into `frame` with `options`. Return the surface of the chat, each open of a session, and each notice.
 * An open of the session `missing` rejects.
 */
function loadChat(frame: FrameTest, options: { readonly copyOnRelease?: boolean } = {}) {
  const surface = frame.surface("chat");
  const opened: Opened[] = [];
  const notices: string[] = [];
  const sessions = {
    open: (id: string, open: { readonly tail: number; readonly signal: AbortSignal }) => {
      opened.push({ id, tail: open.tail, signal: open.signal });
      return id === "missing" ? Promise.reject(new Error("no session missing")) : Promise.resolve({});
    },
  };
  apply({
    get: (name: string) => (name === "tui" ? surface.tui : sessions),
    options,
    notify: (level: string, text: string) => notices.push(`${level} ${text}`),
  } as never);
  return { tui: surface.tui, opened, notices };
}

const EMPTY = { text: "", selection: { anchor: 0, head: 0 }, spans: [] };

function rows(frame: FrameTest): string[] {
  return frame.frame.cells.map((row) =>
    row
      .map((cell) => cell.text || " ")
      .join("")
      .trimEnd(),
  );
}

test("a split opens a new empty chat with its own draft", () => {
  using frame = createFrame({ width: 21, height: 4 });
  const chat = loadChat(frame);
  frame.start();
  equal(rows(frame), ["", "", "─────────────────────", "Message…"]);
  frame.paste("hi");
  chat.tui.commands.run("core:split-right");
  frame.paste("yo");
  equal(rows(frame), ["          │", "          │", "──────────│──────────", "hi        │yo"]);
  // The transcript and the composer of a pane share a group, and each pane has its own.
  const groups = new Map<unknown, Set<object>>();
  for (const mount of chat.tui.widgets.list())
    groups.set(mount.pane, (groups.get(mount.pane) ?? new Set()).add(mount.group));
  const perPane = [...groups.values()];
  equal(
    [perPane.length, perPane.map((set) => set.size), new Set(perPane.flatMap((set) => [...set])).size],
    [2, [1, 1], 2],
  );
});

test("a reload keeps the draft of each pane and the focus", () => {
  using before = createFrame({ width: 21, height: 4 });
  const chat = loadChat(before);
  before.start();
  before.paste("a");
  chat.tui.commands.run("core:split-right");
  before.paste("x");
  const snapshot = before.snapshot();
  using after = createFrame({ width: 21, height: 4 });
  loadChat(after);
  after.start(snapshot);
  after.paste("b");
  equal(rows(after).at(-1), "a         │xb");
});

test("the option copyOnRelease turns the copy of a drag over the transcript on and off", () => {
  for (const copyOnRelease of [false, true]) {
    using frame = createFrame({ width: 10, height: 4 });
    const chat = loadChat(frame, { copyOnRelease });
    frame.start();
    const transcript = chat.tui.widgets.list().find((mount) => mount.widget instanceof TextView)?.widget as TextView;
    transcript.setDocument({
      key: "chat",
      items: [{ key: "i", sections: [{ key: "s", kind: "text", text: "hello" }] }],
    });
    frame.draw();
    frame.mouse(mouse(0, 0, "press"));
    frame.mouse(mouse(4, 0, "drag"));
    frame.mouse(mouse(4, 0, "release"));
    equal(frame.copies, copyOnRelease ? ["hello"] : []);
  }
});

test("the start pane holds the session of the startup, and a split opens a new chat without one", () => {
  using frame = createFrame({ width: 21, height: 4 }, undefined, { cwd: "/work", session: "s1" });
  const chat = loadChat(frame);
  frame.start();
  chat.tui.commands.run("core:split-right");
  equal(
    chat.opened.map((open) => [open.id, open.tail]),
    [["s1", 0]],
  );
  // The close of the start pane ends its handle. Focus by direction reads the rects of the last frame.
  frame.draw();
  chat.tui.commands.run("core:focus-left");
  chat.tui.commands.run("core:close");
  equal(chat.opened[0]?.signal.aborted, true);
  equal(JSON.parse(frame.snapshot()).tree.state.session, undefined);
});

test("two panes on one session hold their own handles, and a reload keeps the session of each", async () => {
  const pane = { type: "chat:pane", state: { session: "s1", draft: EMPTY } };
  const saved = JSON.stringify({ tree: { split: "row", ratio: 0.5, first: pane, second: pane }, focus: 0 });
  using frame = createFrame({ width: 21, height: 4 });
  const chat = loadChat(frame);
  frame.start(saved);
  equal(
    chat.opened.map((open) => open.id),
    ["s1", "s1"],
  );
  chat.tui.commands.run("core:close");
  equal(
    chat.opened.map((open) => open.signal.aborted),
    [true, false],
  );
  equal(JSON.parse(frame.snapshot()).tree.state.session, "s1");
  // A session that does not open gives one notice, and the pane keeps the session for the next reload.
  using other = createFrame({ width: 21, height: 4 });
  const failed = loadChat(other);
  other.start(JSON.stringify({ tree: { type: "chat:pane", state: { session: "missing", draft: EMPTY } }, focus: 0 }));
  await Promise.resolve();
  equal(failed.notices, ["error the session missing did not open: Error: no session missing"]);
  equal(JSON.parse(other.snapshot()).tree.state.session, "missing");
});
