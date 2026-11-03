// A quit of the bundled chat: it asks while work runs, and it says what stops.

import type { Job, SessionUpdate } from "yuke:protocol";
import { createFrame, equal, settled, test } from "yuke:test";
import { fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

const JOB: Job = { id: "j1", label: "npm run dev", state: "running", kind: "process", command: "npm", log: "/tmp/j" };
const SUBAGENT: Job = { id: "j2", label: "Read", state: "running", kind: "plugin", plugin: "agents" };
const RUNNING: SessionUpdate = { sessionUpdate: "state", state: "running" };

/** A chat pane on the session `s1` with the running jobs `jobs`. */
async function opened(jobs: readonly Job[] = []) {
  const frame = createFrame({ width: 50, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(3));
  sessions.state.jobs = jobs;
  const chat = await loadChat(frame, sessions);
  // A frame test has no default keys.
  chat.tui.keys.bind("ctrl+q", "core:quit");
  frame.start();
  await settled();
  frame.draw();
  return { frame, sessions, chat };
}

const screen = (frame: ReturnType<typeof createFrame>): string[] => {
  frame.draw();
  return rows(frame.frame);
};

test("a quit with no work goes on at once", async () => {
  const { frame } = await opened();
  using _frame = frame;

  frame.key("ctrl+q");

  equal(frame.quits, 1);
});

test("a quit with jobs asks, and it names the keys and what runs", async () => {
  const { frame } = await opened([JOB, SUBAGENT]);
  using _frame = frame;

  frame.key("ctrl+q");

  equal(frame.quits, 0);
  equal(screen(frame).slice(-3), [
    " Stop everything and quit?",
    " 2 jobs are running.",
    " enter/ctrl+q: stop and quit · esc: stay",
  ]);
});

test("a quit during a turn asks, and the count names the turn and the job", async () => {
  const { frame, sessions } = await opened([JOB]);
  using _frame = frame;
  sessions.push(RUNNING);
  await settled();

  frame.key("ctrl+q");

  equal(screen(frame).at(-2), " 1 turn and 1 job are running.");
});

test("one job and one turn read in the singular", async () => {
  const first = await opened([JOB]);
  using _first = first.frame;
  first.frame.key("ctrl+q");

  equal(screen(first.frame).at(-2), " 1 job is running.");
});

test("Esc stays, and the work goes on", async () => {
  const { frame, sessions } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  frame.key("esc");

  equal(frame.quits, 0);
  equal(sessions.state.cancels, 0);
  equal(screen(frame).includes(" Stop everything and quit?"), false);
});

test("Enter in the dialog quits", async () => {
  const { frame } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  frame.key("enter");

  equal(frame.quits, 1);
});

test("a second quit key in the dialog quits, also after a stay and a new question", async () => {
  const { frame } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  frame.key("esc");
  frame.key("ctrl+q");
  const asked = frame.quits;
  frame.key("ctrl+q");

  equal([asked, frame.quits], [0, 1]);
});

test("the quit command in the dialog quits and opens no second question", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  chat.tui.commands.run("core:quit");

  equal(frame.quits, 1);
});

test("two panes on one session count its work once", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;
  chat.tui.commands.run("core:split-right");
  await settled();
  await chat.chat.show("s1");
  await settled();

  frame.key("ctrl+q");

  equal(screen(frame).join("\n").includes("1 job is running."), true);
});

test("a read-only session does not count, because its parent holds its work", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;
  chat.chat.setReadOnly((session) => (session === "s1" ? { text: "A child", back: "p1" } : undefined));
  frame.draw();

  frame.key("ctrl+q");

  equal(frame.quits, 1);
});
