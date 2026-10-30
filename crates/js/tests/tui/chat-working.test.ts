// The working row of the bundled chat: a spinner, the phase, the elapsed time, and the cancel key of a running turn.

import { createFrame, equal, test } from "yuke:test";
import { commit, fakeSessions, loadChat, replies, rows, settle } from "./chat.ts";

const hints = { title: null, subject: { argument: "command", kind: "text" }, preview: "tail" } as const;

test("a running turn shows its phase and time above the rule, and the end of the turn takes the row away", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  /** Draw the frame, and give the row above the rule. */
  const row = (): string => {
    frame.draw();
    const all = rows(frame);
    return all[all.findIndex((text) => text.startsWith("──")) - 1] ?? "";
  };
  const idle = row();
  sessions.push({ sessionUpdate: "state", state: "running" });
  const start = row();
  frame.advance(1080);
  const later = row();
  sessions.push(
    commit(3, [{ tool_call: { callId: "c1", name: "exec", arguments: '{"command":"cargo test"}' } }], {
      display: { calls: [{ blockIndex: 0, hints, folder: "/w" }], results: [] },
    }),
  );
  const tool = row();
  sessions.push(commit(4, [{ tool_result: { callId: "c1", content: "ok", isError: false } }]));
  const done = row();
  sessions.push({ sessionUpdate: "retry_scheduled", afterMs: 5000, error: "overloaded" });
  frame.advance(2000);
  const retry = row();
  sessions.push({ sessionUpdate: "state", state: "idle" });
  frame.draw();
  const ended = rows(frame).some((text) => text.includes("to interrupt"));
  // The retry status stays in the transcript until the next draft, and the next turn shows no old countdown.
  sessions.push({ sessionUpdate: "state", state: "running" });
  const next = row();
  equal(
    [idle.includes("to interrupt"), start, later, tool, done, retry, ended, next],
    [
      false,
      "⠋ Waiting… (0s · esc to interrupt)",
      "⠸ Waiting… (1s · esc to interrupt)",
      "⠸ Running cargo test… (1s · esc to interrupt)",
      "⠸ Waiting… (1s · esc to interrupt)",
      "⠇ Retrying in 3s… (3s · esc to interrupt)",
      false,
      "⠋ Waiting… (0s · esc to interrupt)",
    ],
  );
});

test("the elapsed time of a long turn shows minutes", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.advance(185_000);
  equal(
    rows(frame).some((text) => text.includes("(3m 05s · esc to interrupt)")),
    true,
  );
});

test("a draft shows reasoning, a response, or a call that the model still writes", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.push({ sessionUpdate: "state", state: "running" });
  sessions.push({ sessionUpdate: "draft_started", draftId: "d1" });
  const phase = (): string | undefined => {
    frame.draw();
    return rows(frame)
      .find((text) => text.includes("to interrupt"))
      ?.slice(2)
      .split(" (")[0];
  };
  const model = (event: object) => sessions.push({ sessionUpdate: "model", draftId: "d1", event } as never);
  model({ kind: "block_started", block: 0, blockKind: "reasoning" });
  model({ kind: "reasoning_delta", block: 0, text: "Hmm" });
  const reasoning = phase();
  model({ kind: "block_started", block: 1, blockKind: "text" });
  model({ kind: "text_delta", block: 1, text: "Sure" });
  const responding = phase();
  model({ kind: "block_started", block: 2, blockKind: "tool_call" });
  equal([reasoning, responding, phase()], ["Reasoning…", "Responding…", "Preparing a tool call…"]);
});

test("a close of the session by another client takes the working row away", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.draw();
  const running = rows(frame).some((text) => text.includes("to interrupt"));
  sessions.close("s1");
  frame.draw();
  equal([running, rows(frame).some((text) => text.includes("to interrupt"))], [true, false]);
});
