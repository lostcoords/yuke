// Rows of plugins above the composer of the bundled chat: the place, the space, the order, and a failed source.

import type { ChatRowsContext } from "yuke:chat";
import type { SessionUpdate } from "yuke:protocol";
import { createFrame, equal, test } from "yuke:test";
import { fakeSessions, loadChat, rows, settle } from "./chat.ts";

/** The update that accepts the waiting message `text` of the user as the input `id`. */
function waiting(id: number, text: string): SessionUpdate {
  return {
    sessionUpdate: "input_accepted",
    inputId: id,
    input: { source: { kind: "user" }, kind: "message", content: [{ user_text: text }] },
  };
}

test("plugin rows show below the transcript and above the waiting messages, cut to the width, in add order", async () => {
  using frame = createFrame({ width: 24, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  const seen: ChatRowsContext[] = [];
  chat.chat.addRows((pane) => {
    seen.push(pane);
    return [{ text: "first source, a longer row", style: { bold: true } }, { text: "its second row" }];
  });
  const remove = chat.chat.addRows(() => [{ text: "second source" }]);
  frame.start();
  await settle();
  sessions.push(waiting(5, "fix the test"));
  frame.draw();
  const shown = rows(frame).slice(3);
  const bold = frame.frame.cells[4]?.[0]?.style.bold;
  remove();
  frame.draw();
  equal(
    [shown, bold, rows(frame).slice(5, 8), seen.at(-1)],
    [
      [
        "",
        "first source, a longer …",
        "its second row",
        "second source",
        " fix the test     ↑ edit",
        "────────────────────────",
        "Message…",
      ],
      true,
      ["first source, a longer …", "its second row", " fix the test     ↑ edit"],
      { session: "s1", width: 24 },
    ],
  );
});

test("plugin rows take at most half the rows above the rule and give way to the strip, and a source shows whole", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  const three = ["a1", "a2", "a3"].map((text) => ({ text }));
  chat.chat.addRows(() => three);
  chat.chat.addRows(() => [{ text: "b1" }, { text: "b2" }, { text: "b3" }]);
  chat.chat.addRows(() => [{ text: "c1" }]);
  frame.start();
  await settle();
  /** The plugin rows that show. */
  const plugin = (): string[] => {
    frame.draw();
    return rows(frame).filter((text) => /^[abc]\d$/.test(text));
  };
  // Ten rows above the rule give plugins five. The three rows of the second source do not fit, so it and the later
  // sources wait.
  const half = plugin();
  for (let id = 1; id <= 8; id++) sessions.push(waiting(id, `m${id}`));
  equal([half, plugin()], [["a1", "a2", "a3"], []]);
});

test("a row source that throws is removed and gives one notice, and the other sources stay", async () => {
  using frame = createFrame({ width: 24, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions());
  let calls = 0;
  chat.chat.addRows(() => {
    calls += 1;
    throw new Error("broken");
  });
  chat.chat.addRows(() => [{ text: "kept" }]);
  frame.start();
  await settle();
  frame.draw();
  frame.draw();
  equal(
    [calls, chat.notices, rows(frame).includes("kept")],
    [1, ["error a row source of the chat failed: Error: broken"], true],
  );
});

test("each add is its own source, so the same source shows twice and a disposer removes only its own", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions());
  const source = () => [{ text: "same" }];
  const first = chat.chat.addRows(source);
  chat.chat.addRows(source);
  frame.start();
  await settle();
  /** The count of rows of the source. */
  const count = (): number => {
    frame.draw();
    return rows(frame).filter((text) => text === "same").length;
  };
  const both = count();
  first();
  first();
  equal([both, count()], [2, 1]);
});
