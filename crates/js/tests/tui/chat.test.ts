// The bundled chat pane in a frame: the default pane of each split, its own draft, a reload, and its options.

import { apply } from "yuke:internal/bundled/chat";
import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { type MouseEvent, TextView } from "yuke:tui";

const MODIFIERS = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

function mouse(column: number, row: number, action: MouseEvent["action"]): MouseEvent {
  return { type: "mouse", column, row, button: "left", action, modifiers: MODIFIERS };
}

/** Load the chat into `frame` with `options`. Return the surface of the chat. */
function loadChat(frame: FrameTest, options: { readonly copyOnRelease?: boolean } = {}) {
  const surface = frame.surface("chat");
  apply({ get: () => surface.tui, options } as never);
  return surface;
}

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
