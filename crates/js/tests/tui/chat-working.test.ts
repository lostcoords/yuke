// The working row of the bundled chat: a spinner, the phase, the elapsed time, and the cancel key of a running turn.

import { assertEquals, createFrame, type FrameTest, test, waitForSettled } from "yuke:test";
import { commit, fakeSessions, fixedClock, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

const hints = { subject: { argument: "command", kind: "text" }, preview: "tail" } as const;

test("a running turn shows its phase and time above an empty row before the rule, and the end of the turn takes the working row away", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  using _clock = fixedClock();
  /** Draw the frame. Return the text two rows above the rule. */
  const row = (): string => {
    frame.draw();
    const all = rows(frame.frame);
    return all[all.findIndex((text) => text.startsWith("──")) - 2] ?? "";
  };
  /** The row without its spinner glyph, which changes with each frame of the spinner. */
  const phase = (): string => row().slice(2);
  const idle = row();
  sessions.push({ sessionUpdate: "state", state: "running" });
  const start = phase();
  const gap = rows(frame.frame)[rows(frame.frame).findIndex((text) => text.startsWith("──")) - 1];
  frame.advance(1080);
  const later = phase();
  const call = { callId: "c1", name: "exec", arguments: '{"command":"cargo test"}' };
  sessions.push(
    commit(3, [{ kind: "toolCall", ...call }], {
      display: { calls: [{ blockIndex: 0, hints, cwd: "/w" }], results: [] },
    }),
  );
  const tool = phase();
  const pendingCommand = rows(frame.frame).find((text) => text.includes("exec cargo test"));
  sessions.push({ sessionUpdate: "toolStarted", position: { eventNumber: 3, blockIndex: 0 }, call });
  const running = phase();
  const runningCommand = rows(frame.frame).find((text) => text.includes("exec cargo test"));
  sessions.push(commit(4, [{ kind: "toolResult", callId: "c1", content: "ok", isError: false }]));
  const done = phase();
  const completedCommand = rows(frame.frame).find((text) => text.includes("exec cargo test"));
  assertEquals(
    [pendingCommand, runningCommand, completedCommand],
    [" exec cargo test · waiting", " exec cargo test · running", " exec cargo test"],
  );
  sessions.push({ sessionUpdate: "retryScheduled", afterMs: 5000, error: "overloaded" });
  frame.advance(2000);
  const retry = phase();
  sessions.push({ sessionUpdate: "state", state: "idle" });
  frame.draw();
  const ended = rows(frame.frame).some((text) => text.includes("to interrupt"));
  // The retry status stays in the transcript until the next draft, and the next turn shows no old countdown.
  sessions.push({ sessionUpdate: "state", state: "running" });
  const next = phase();
  assertEquals(
    [idle.includes("to interrupt"), gap, start, later, tool, running, done, retry, ended, next],
    [
      false,
      "",
      "Working… (0s · esc to interrupt)",
      "Working… (1s · esc to interrupt)",
      "Working… (1s · esc to interrupt)",
      "Working… (1s · esc to interrupt)",
      "Working… (1s · esc to interrupt)",
      "Retrying in 3s… (3s · esc to interrupt)",
      false,
      "Working… (0s · esc to interrupt)",
    ],
  );
});

test("the elapsed time of a long turn shows minutes", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.advance(185_000);
  assertEquals(
    rows(frame.frame).some((text) => text.includes("(3m 05s · esc to interrupt)")),
    true,
  );
});

test("reasoning and response drafts have phase labels, and tool input has a generic label", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  sessions.push({ sessionUpdate: "draftStarted", draftId: "d1" });
  const phase = (): string | undefined => {
    frame.draw();
    return rows(frame.frame)
      .find((text) => text.includes("to interrupt"))
      ?.slice(2)
      .split(" (")[0];
  };
  const model = (event: object) => sessions.push({ sessionUpdate: "model", draftId: "d1", event } as never);
  model({ kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } });
  model({ kind: "reasoningDelta", blockId: 0, text: "Hmm" });
  const reasoning = phase();
  model({ kind: "blockStarted", blockId: 1, content: { kind: "text" } });
  model({ kind: "textDelta", blockId: 1, text: "Sure" });
  const responding = phase();
  model({ kind: "blockStarted", blockId: 2, content: { kind: "toolCall", name: "bash" } });
  assertEquals([reasoning, responding, phase()], ["Reasoning…", "Responding…", "Working…"]);
});

test("a thought without text to show draws no rows, and the working row still shows the reasoning phase", async () => {
  const sessions = fakeSessions(replies(20));
  using frame = createFrame({ width: 50, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  sessions.push({ sessionUpdate: "draftStarted", draftId: "d1" });
  const model = (event: object) => sessions.push({ sessionUpdate: "model", draftId: "d1", event } as never);
  /** Draw the frame. Return the rows above the working row and the phase of the working row. */
  const shown = (): [string[], string | undefined] => {
    frame.draw();
    const all = rows(frame.frame);
    const working = all.findIndex((text) => text.includes("to interrupt"));
    return [all.slice(0, working), all[working]?.slice(2).split(" (")[0]];
  };
  // The transcript follows its tail, so a row of the thought moves the replies up.
  const before = shown()[0];
  model({ kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } });
  const empty = shown();
  model({ kind: "reasoningDelta", blockId: 0, text: " \n" });
  const blank = shown();
  model({ kind: "reasoningDelta", blockId: 0, text: "Hmm" });
  const thought = shown();
  assertEquals(
    [empty, blank, [thought[0].slice(-4), thought[1]]],
    [
      [before, "Reasoning…"],
      [before, "Reasoning…"],
      [[" reply 20", "", " thinking", ""], "Reasoning…"],
    ],
  );
});

test("a short pane gives up the empty rows before the last row of the transcript", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 5 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  using _clock = fixedClock();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.draw();
  // The spinner glyph changes with each frame of the spinner, so the test compares the text after it.
  assertEquals(
    rows(frame.frame).map((text, at) => (at === 1 ? text.slice(2) : text)),
    [" reply 2", "Working… (0s · esc to interrupt)", "─".repeat(50), "Message…", "─".repeat(50)],
  );
});

test("a close of the session by another client takes the working row away", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.draw();
  const running = rows(frame.frame).some((text) => text.includes("to interrupt"));
  sessions.close("s1");
  frame.draw();
  assertEquals([running, rows(frame.frame).some((text) => text.includes("to interrupt"))], [true, false]);
});

test("the working row shows no cancel key while the command list takes esc", async () => {
  const sessions = fakeSessions(replies(2));
  using frame = createFrame({ width: 50, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.key("/ m o d e l");
  frame.draw();
  const listed = rows(frame.frame).find((text) => text.includes("Working…"));
  frame.key("esc");
  frame.draw();
  const hidden = rows(frame.frame).find((text) => text.includes("Working…"));
  assertEquals([listed?.slice(2), hidden?.slice(2)], ["Working… (0s)", "Working… (0s · esc to interrupt)"]);
});

/** A frame of `width` with a chat whose exec of `command` runs. */
async function runningExec(width: number, command: string) {
  const sessions = fakeSessions(replies(2));
  const frame = createFrame({ width, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  const call = { callId: "c1", name: "exec", arguments: JSON.stringify({ command }) };
  sessions.push(
    commit(3, [{ kind: "toolCall", ...call }], {
      display: { calls: [{ blockIndex: 0, hints, cwd: "/w" }], results: [] },
    }),
  );
  const before = workingRow(frame);
  sessions.push({ sessionUpdate: "toolStarted", position: { eventNumber: 3, blockIndex: 0 }, call });
  sessions.state.movable = true;
  // A frame draws each spinner step, and the row counts the delay from the first draw of the movable work.
  frame.draw();
  return { frame, sessions, before };
}

/** The working row of `frame`. */
function workingRow(frame: FrameTest): string {
  frame.draw();
  return rows(frame.frame).find((text) => text.includes(" (") && /\d+s/.test(text)) ?? "";
}

test("movable work shows the background hint after a delay, and the key asks to move it", async () => {
  const { frame, sessions, before } = await runningExec(100, "cargo test");
  using _frame = frame;
  const early = workingRow(frame);

  frame.advance(2000);
  const late = workingRow(frame);
  frame.key("ctrl+b");

  assertEquals(before.includes("to background"), false, before);
  assertEquals(early.includes("to background"), false, early);
  assertEquals(late.includes("ctrl+b to background"), true, late);
  assertEquals(sessions.state.backgrounds, 1);
});

test("a long command stays in the transcript and leaves room for the interrupt and background hints", async () => {
  const { frame } = await runningExec(65, `cargo test ${"--flag ".repeat(30)}`);
  using _frame = frame;

  frame.advance(2000);

  assertEquals(workingRow(frame).slice(2), "Working… (2s · esc to interrupt · ctrl+b to background)");
  assertEquals(
    rows(frame.frame)
      .find((text) => text.includes("exec cargo test"))
      ?.startsWith(" exec cargo test --flag"),
    true,
  );
});

test("a narrow row drops the background hint, then the interrupt hint", async () => {
  const wide = await runningExec(42, "cargo test");
  using _wide = wide.frame;
  const narrow = await runningExec(30, "cargo test");
  using _narrow = narrow.frame;

  wide.frame.advance(2000);
  narrow.frame.advance(2000);

  assertEquals(
    [workingRow(wide.frame).slice(2), workingRow(narrow.frame).slice(2)],
    ["Working… (2s · esc to interrupt)", "Working… (2s)"],
  );
});
