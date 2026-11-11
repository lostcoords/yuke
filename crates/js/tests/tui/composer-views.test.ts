// Views of plugins on each side of the composer of the bundled chat: their place, their limit, order, and lifetime.

import { type ChatPane, composerRows } from "yuke:chat";
import type { SessionUpdate } from "yuke:protocol";
import { createFrame, equal, test, waitForSettled } from "yuke:test";
import { click, fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

/** A `create` of plain text rows. */
const plain =
  (...texts: readonly string[]) =>
  () =>
    composerRows(() => texts.map((text) => ({ text })));

/** The update that accepts the waiting message `text` of the user as the input `id`. */
function waiting(id: number, text: string): SessionUpdate {
  return {
    sessionUpdate: "input_accepted",
    inputId: id,
    input: { source: { kind: "user" }, kind: "message", content: [{ user_text: text }] },
  };
}

test("views above show below the transcript and above the waiting messages, cut to the width, in add order", async () => {
  using frame = createFrame({ width: 24, height: 11 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  chat.chat.addComposerView("above", () =>
    composerRows(() => [{ text: "first source, a longer row", style: { bold: true } }, { text: "its second row" }]),
  );
  const remove = chat.chat.addComposerView("above", plain("second source"));
  frame.start();
  await waitForSettled();
  sessions.push(waiting(5, "fix the test"));
  frame.draw();
  const shown = rows(frame.frame).slice(3);
  const bold = frame.frame.cells[4]?.[0]?.style.bold;
  remove();
  frame.draw();
  equal(
    [shown, bold, rows(frame.frame).slice(5, 8)],
    [
      [
        "",
        "first source, a longer …",
        "its second row",
        "second source",
        " fix the test     ↑ edit",
        "────────────────────────",
        "Message…",
        "────────────────────────",
      ],
      true,
      ["first source, a longer …", "its second row", " fix the test     ↑ edit"],
    ],
  );
});

test("views above share at most half the rows above the frame and give way to the strip", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  chat.chat.addComposerView("above", plain("a1", "a2", "a3"));
  chat.chat.addComposerView("above", plain("b1", "b2", "b3"));
  chat.chat.addComposerView("above", plain("c1"));
  frame.start();
  await waitForSettled();
  const plugin = (): string[] => {
    frame.draw();
    return rows(frame.frame).filter((text) => /^[abc]\d$/.test(text));
  };
  // Nine rows above the frame give plugins four. A later view gets the rows that remain.
  const half = plugin();
  for (let id = 1; id <= 8; id++) sessions.push(waiting(id, `m${id}`));
  equal([half, plugin()], [["a1", "a2", "a3", "b1"], ["a1"]]);
});

test("views below show under the composer in add order, and the composer moves up", async () => {
  using frame = createFrame({ width: 24, height: 11 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerView("below", plain("first", "second"));
  const remove = chat.chat.addComposerView("below", plain("third"));
  chat.chat.addComposerView("above", plain("above"));
  frame.start();
  await waitForSettled();
  frame.draw();
  const shown = rows(frame.frame).slice(4);
  remove();
  frame.draw();
  const rule = "─".repeat(24);
  equal(
    [shown, rows(frame.frame).slice(5)],
    [
      ["above", rule, "Message…", rule, "first", "second", "third"],
      ["above", rule, "Message…", rule, "first", "second"],
    ],
  );
});

test("views below share at most half the pane, and views above share half of what the frame leaves", async () => {
  using frame = createFrame({ width: 24, height: 13 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerView("below", plain("a1", "a2", "a3", "a4"));
  chat.chat.addComposerView("below", plain("b1", "b2", "b3"));
  chat.chat.addComposerView("below", plain("c1"));
  chat.chat.addComposerView("above", plain("d1", "d2", "d3"));
  frame.start();
  await waitForSettled();
  frame.draw();

  equal(
    rows(frame.frame).filter((text) => /^[abcd]\d$/.test(text)),
    ["d1", "d2", "a1", "a2", "a3", "a4", "b1", "b2"],
  );
});

test("a height of 0 places no view, and the next view gets the rows that remain", async () => {
  using frame = createFrame({ width: 24, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  const heights: number[] = [];
  let drawnEmpty = 0;
  chat.chat.addComposerView("below", () => ({
    heightFor: () => 0,
    draw: () => {
      drawnEmpty += 1;
    },
  }));
  chat.chat.addComposerView("below", () => ({
    heightFor: () => 20,
    draw: (canvas) => {
      heights.push(canvas.height);
    },
  }));
  frame.start();
  await waitForSettled();
  frame.draw();
  equal([heights.at(-1), drawnEmpty], [4, 0]);
});

test("each pane makes one view per call and gives its live fields, and a close ends each mount", async () => {
  using frame = createFrame({ width: 60, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(replies(1)));
  const made: { readonly pane: ChatPane; readonly signal: AbortSignal }[] = [];
  const remove = chat.chat.addComposerView("below", (mount, pane) => {
    made.push({ pane, signal: mount.signal });
    return composerRows(() => []);
  });
  frame.start();
  await waitForSettled();
  frame.draw();
  frame.draw();
  const first = made[0]?.pane;
  equal(
    [made.length, first?.session, first?.running, first?.transcript.settings !== undefined],
    [1, "s1", false, true],
  );

  chat.tui.commands.run("core:split-right");
  await waitForSettled();
  frame.draw();
  equal(made.length, 2);
  // The close of a pane ends only its own mount.
  chat.tui.panes.active?.close();
  frame.draw();
  equal(
    made.map((entry) => entry.signal.aborted),
    [false, true],
  );
  remove();
  equal(made[0]?.signal.aborted, true);
});

test("a view that closes its mount stays closed in the pane, and its factory runs once", async () => {
  using frame = createFrame({ width: 24, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  let calls = 0;
  let close = (): void => {};
  chat.chat.addComposerView("below", (mount) => {
    calls += 1;
    close = () => mount.close();
    return composerRows(() => [{ text: "shown" }]);
  });
  frame.start();
  await waitForSettled();
  frame.draw();
  const before = rows(frame.frame).at(-1);
  close();
  frame.draw();
  frame.draw();
  equal([before, calls, rows(frame.frame).includes("shown")], ["shown", 1, false]);
});

test("a view above sits directly above the working row", async () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  chat.chat.addComposerView("above", plain("view row"));
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.draw();
  const shown = rows(frame.frame);
  const at = shown.indexOf("view row");
  equal([at >= 0, shown[at + 1]?.includes("Working"), shown.includes("Message…")], [true, true, true]);
});

test("a factory that throws gives one notice and runs once, and the pane still draws", async () => {
  using frame = createFrame({ width: 24, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  let calls = 0;
  chat.chat.addComposerView("below", () => {
    calls += 1;
    throw new Error("bad view");
  });
  frame.start();
  await waitForSettled();
  frame.draw();
  frame.draw();
  equal(
    [calls, chat.notices.filter((text) => text.includes("bad view")).length, rows(frame.frame).at(-2)],
    [1, 1, "Message…"],
  );
});

test("a press on a view reaches it and leaves the focus on the composer", async () => {
  using frame = createFrame({ width: 24, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  const pressed: number[] = [];
  chat.chat.addComposerView("below", () => ({
    heightFor: () => 1,
    draw() {},
    mouse: (event) => {
      if (event.action === "press") pressed.push(event.row);
      return true;
    },
  }));
  frame.start();
  await waitForSettled();
  frame.draw();
  const focused = chat.tui.focused;
  click(frame, 2, 7);
  equal([pressed, chat.tui.focused === focused], [[0], true]);
});

test("views below leave the composer half of the rows that remain", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerView("below", plain("b1", "b2", "b3", "b4"));
  frame.start();
  await waitForSettled();
  frame.paste("1\n2\n3\n4\n5\n6\n7\n8\n9");
  frame.draw();
  const shown = rows(frame.frame);

  equal([shown.findIndex((line) => line.startsWith("──")), shown.slice(-4)], [3, ["b1", "b2", "b3", "b4"]]);
});

test("each call is its own view, and a disposer removes only its own", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  const first = chat.chat.addComposerView("above", plain("same"));
  chat.chat.addComposerView("above", plain("same"));
  frame.start();
  await waitForSettled();
  const count = (): number => {
    frame.draw();
    return rows(frame.frame).filter((text) => text === "same").length;
  };
  const both = count();
  first();
  first();
  equal([both, count()], [2, 1]);
});

test("the rule above the composer has a default look that a plugin changes", async () => {
  using frame = createFrame({ width: 24, height: 6 }, undefined, { cwd: "/w" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await waitForSettled();
  const look = () => {
    const cells = frame.draw().cells;
    return cells[rows(frame.frame).findIndex((line) => line.startsWith("──"))]?.[0]?.style;
  };
  const before = look();
  frame.surface("theme").tui.styles.set({ "chat.rule": { fg: 1, dim: null } });
  equal([before, look()], [{ dim: true }, { fg: 1 }]);
});

test("a pane without plugin views shows a rule below the composer, in the look of the rule above it", async () => {
  using frame = createFrame({ width: 24, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await waitForSettled();
  frame.draw();
  const rule = "─".repeat(24);
  equal([rows(frame.frame), frame.frame.cells[5]?.[23]?.style], [["", "", "", rule, "Message…", rule], { dim: true }]);
});

test("a view below takes a free row from the rule below the composer", async () => {
  using frame = createFrame({ width: 24, height: 3 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerView("below", plain("only"));
  frame.start();
  await waitForSettled();
  frame.draw();
  const two = rows(frame.frame);
  frame.resize({ width: 24, height: 4 });
  const rule = "─".repeat(24);
  equal(
    [two, rows(frame.frame)],
    [
      [rule, "Message…", "only"],
      [rule, "Message…", rule, "only"],
    ],
  );
});

test("a tall draft stays above the rule below the composer, with the caret on its last line", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await waitForSettled();
  frame.paste("1\n2\n3\n4\n5\n6\n7\n8\n9");
  frame.draw();
  const rule = "─".repeat(24);
  equal(
    [rows(frame.frame), frame.frame.cursor],
    [["", "", "", "", "", rule, "5", "6", "7", "8", "9", rule], { column: 1, row: 10 }],
  );
});

test("a tall question stays above the rule below the composer, with the caret on its field", async () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const question = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  const options = [{ label: "Yes" }];
  sessions.push({
    sessionUpdate: "interaction_requested",
    interactionId: 1,
    source: "guard",
    request: { kind: "questions", questions: [{ id: "q", header: "Q", question, options, other: true }] },
  });
  frame.key("down");
  frame.draw();
  const rule = "─".repeat(40);
  equal(
    [rows(frame.frame).slice(5), frame.frame.cursor],
    [
      [rule, " guard · Q", " line 1", "  Yes", "❯ Type your own answer…", " ↑↓ choose · enter send · esc cancel", rule],
      { column: 2, row: 9 },
    ],
  );
});
