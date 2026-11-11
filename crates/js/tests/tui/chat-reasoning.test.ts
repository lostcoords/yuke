// Shared reasoning runs in the bundled chat: one fold and source for adjacent provider blocks.

import { assert, createFrame, equal, test, waitForSettled } from "yuke:test";
import { click, commit, fakeSessions, loadChat, SETTINGS, transcriptRows } from "./chat.ts";
import { rows } from "./rows.ts";

test("one thought opens and copies every adjacent reasoning block of a saved response", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions([
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ reasoning: { text: "first thought" } }, { reasoning: { text: "second thought" } }]),
  ]);
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  equal(
    transcriptRows(frame).filter((row) => row !== ""),
    [" thought"],
  );
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 6), ["", " thought", " first thought", "", " second thought", ""]);
  const view = chat.transcript();
  const thought = view.document.items.find((item) =>
    item.sections.some((section) => section.text === "first thought\n\nsecond thought"),
  );
  assert(thought !== undefined);
  const from = { item: thought.key, section: "text", offset: 0 };
  const to = { ...from, offset: "first thought\n\nsecond thought".length };
  equal(view.text({ from, to }), "first thought\n\nsecond thought");
  const snapshot = frame.snapshot();
  using restored = createFrame({ width: 60, height: 14 });
  await loadChat(restored, sessions);
  restored.start(snapshot);
  await waitForSettled();
  equal(transcriptRows(restored).slice(0, 6), ["", " thought", " first thought", "", " second thought", ""]);
  click(frame, 2, 4);
  equal(
    transcriptRows(frame).filter((row) => row !== ""),
    [" thought"],
  );
});

test("adjacent empty reasoning blocks keep one working phase without drawing thought rows", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions([{ seq: 1, sessionUpdate: "settings", ...SETTINGS }]);
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  sessions.push({ sessionUpdate: "draft_started", draftId: "d" });
  sessions.push({
    sessionUpdate: "model",
    draftId: "d",
    event: { kind: "block_started", block: 0, content: { kind: "reasoning" } },
  });
  sessions.push({
    sessionUpdate: "model",
    draftId: "d",
    event: { kind: "block_started", block: 1, content: { kind: "reasoning" } },
  });
  sessions.push({ sessionUpdate: "model", draftId: "d", event: { kind: "reasoning_delta", block: 1, text: " \n\t" } });
  frame.draw();
  equal(
    transcriptRows(frame).filter((row) => row !== "" && !row.includes("to interrupt")),
    [],
  );
  assert(rows(frame.frame).some((row) => row.includes("Reasoning…")));
  sessions.push({ sessionUpdate: "model", draftId: "d", event: { kind: "reasoning_delta", block: 0, text: "first" } });
  sessions.push({ sessionUpdate: "model", draftId: "d", event: { kind: "reasoning_delta", block: 1, text: "second" } });
  frame.draw();
  equal(
    transcriptRows(frame).filter((row) => row !== "" && !row.includes("to interrupt")),
    [" thinking"],
  );
  click(frame, 2, 1);
  equal(
    transcriptRows(frame).filter((row) => row !== "" && !row.includes("to interrupt")),
    [" thinking", " first", " second"],
  );
});
