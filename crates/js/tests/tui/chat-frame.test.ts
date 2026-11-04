// The frame around the input of a chat pane: its insets, its paint, its context, and its owner.

import { ChatDocument, type ComposerFrameContext, composerRows } from "yuke:chat";
import type { InteractionRequest } from "yuke:protocol";
import { createFrame, equal, settled, test } from "yuke:test";
import { type Canvas, TextEditor } from "yuke:tui";
import { click, fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

const QUESTION: InteractionRequest = {
  kind: "questions",
  questions: [{ id: "q", header: "Branch", question: "Delete?", options: [{ label: "Yes" }] }],
} as InteractionRequest;

/** A frame that draws its rows as text: `t` on the top row, `b` on the bottom row, and `|` beside the input. */
const marks = {
  draw: (canvas: Canvas, pane: ComposerFrameContext) => {
    const end = pane.inputRect.row + pane.inputRect.height;
    for (let row = 0; row < pane.inputRect.row; row += 1) canvas.text(0, row, "t");
    for (let row = pane.inputRect.row; row < end; row += 1) canvas.text(0, row, "|");
    for (let row = end; row < canvas.height; row += 1) canvas.text(0, row, "b");
  },
};

test("the height, the cursor, and a click of the input follow the side insets", async () => {
  using frame = createFrame({ width: 12, height: 8 });
  const chat = await loadChat(frame);
  chat.chat.setComposerFrame({ ...marks, inset: () => ({ top: 1, bottom: 1, left: 2, right: 2 }) });
  frame.start();
  frame.paste("abcdefghij");
  frame.draw();
  // The input has 8 columns, so the text takes two rows.
  equal(rows(frame.frame).slice(-4), ["t", "| abcdefgh", "| ij", "b"]);
  equal(frame.frame.cursor?.column, 4);
  equal(frame.frame.cursor?.row, 6);
  click(frame, 3, 5);
  frame.draw();
  equal([frame.frame.cursor?.column, frame.frame.cursor?.row], [3, 5]);
});

test("a frame without insets leaves each row to the transcript and the input", async () => {
  using frame = createFrame({ width: 20, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(replies(30)));
  chat.chat.setComposerFrame({ inset: () => ({}), draw() {} });
  frame.start();
  await settled();
  frame.draw();
  const shown = rows(frame.frame);
  equal(shown.at(-1), "Message…");
  equal(shown.at(-2), "");
  equal(
    shown.some((row) => row.startsWith("─")),
    false,
  );
  // The input takes one row and the empty row takes one. The two rules of the default frame would take two more.
  equal(chat.transcript().scroll.state.height, 4);
});

test("a short pane gives up the rows below the input first, then the rows above it", async () => {
  using frame = createFrame({ width: 10, height: 3 });
  const chat = await loadChat(frame);
  let inputRow = -1;
  chat.chat.setComposerFrame({
    inset: () => ({ top: 1, bottom: 1 }),
    draw: (canvas, pane) => {
      inputRow = pane.inputRect.row;
      marks.draw(canvas, pane);
    },
  });
  frame.start();
  equal(rows(frame.frame), ["t", "Message…", "b"]);
  frame.resize({ width: 10, height: 2 });
  frame.draw();
  equal(rows(frame.frame), ["t", "Message…"]);
  frame.resize({ width: 10, height: 1 });
  frame.draw();
  equal([rows(frame.frame), inputRow], [["Message…"], 0]);
});

test("the style of a frame stays under the text of the input and the empty cells", async () => {
  using frame = createFrame({ width: 8, height: 4 });
  const chat = await loadChat(frame);
  chat.chat.setComposerFrame({
    inset: () => ({ top: 1, left: 1, right: 1 }),
    style: { bg: 2 },
    draw: (canvas) => {
      canvas.text(0, 1, "┃", { fg: 1, bg: 3 });
    },
  });
  frame.start();
  frame.paste("hi");
  const cells = frame.draw().cells;
  // The top row, the bar, the text, the empty cell of the input, and the right inset.
  equal(cells[2]?.[3]?.style, { bg: 2 });
  equal(cells[3]?.[0], { text: "┃", width: 1, style: { fg: 1, bg: 3 } });
  equal(cells[3]?.[1], { text: "h", width: 1, style: { bg: 2 } });
  equal(cells[3]?.[5]?.style, { bg: 2 });
  equal(cells[3]?.[7]?.style, { bg: 2 });
  // The row above the frame is not in the frame.
  equal(cells[1]?.[3]?.style, {});
});

test("a frame gets the view in the input area, the focus, and the state of the turn", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(3));
  const chat = await loadChat(frame, sessions);
  const seen: string[] = [];
  chat.chat.setComposerFrame({
    inset: (pane) => (pane.kind === "composer" ? { left: 1 } : {}),
    draw: (_canvas, pane) => {
      seen.push(`${pane.kind} ${pane.focused} ${pane.running} ${pane.inputRect.column} ${pane.session}`);
    },
  });
  frame.start();
  await settled();
  frame.draw();
  equal(seen.at(-1), "composer true false 1 s1");
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.draw();
  equal(seen.at(-1), "composer true true 1 s1");
  sessions.push({ sessionUpdate: "state", state: "idle" });
  frame.draw();
  sessions.push({ sessionUpdate: "interaction_requested", interactionId: 1, source: "guard", request: QUESTION });
  await settled();
  frame.draw();
  equal(seen.at(-1), "question true false 0 s1");
  const end = chat.chat.addReadOnly(() => ({ text: "A child session", back: "p1" }));
  frame.draw();
  equal(seen.at(-1), "readOnly true false 0 s1");
  end();
  chat.tui.panes.split(() => ({ draw() {} }));
  frame.draw();
  equal(seen.at(-1)?.split(" ")[1], "false");
});

test("the composer stays the same widget in a frame, and the last frame wins until its disposer", async () => {
  using frame = createFrame({ width: 10, height: 4 });
  const chat = await loadChat(frame);
  const label = (text: string) => ({
    inset: () => ({ top: 1, bottom: 1 }),
    draw: (canvas: Canvas) => {
      canvas.text(0, 0, text);
    },
  });
  const first = chat.chat.setComposerFrame(label("one"));
  const second = chat.chat.setComposerFrame(label("two"));
  frame.start();
  equal(rows(frame.frame)[1], "two");
  const composer = chat.tui.widgets.list().find((mount) => mount.widget.role === "composer")?.widget;
  equal(composer instanceof TextEditor, true);
  equal(chat.tui.focused, composer);
  // A press on the frame leaves the focus on the input.
  click(frame, 0, 1);
  equal(chat.tui.focused, composer);
  // An old disposer changes nothing, and the disposer of the current frame gives the two rules back.
  first();
  frame.draw();
  equal(rows(frame.frame)[1], "two");
  second();
  frame.draw();
  equal(rows(frame.frame).slice(-3), ["─".repeat(10), "Message…", "─".repeat(10)]);
});

test("a disposer of the chat service runs after the chat plugin stops", async () => {
  using frame = createFrame({ width: 10, height: 4 });
  const chat = await loadChat(frame);
  const disposers = [
    chat.chat.setComposerFrame({ inset: () => ({}), draw() {} }),
    chat.chat.setPresentation((options) => new ChatDocument(options.key, options.folds)),
    chat.chat.addReadOnly(() => undefined),
    chat.chat.addComposerView("below", () => composerRows(() => [])),
  ];
  frame.start();
  chat.surface.close();
  for (const dispose of disposers) dispose();
});
