// A quit of the bundled chat: it asks while work runs, and it says what stops.

import type { Job, SessionUpdate } from "yuke:protocol";
import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

const JOB: Job = { id: "j1", label: "npm run dev", state: "running", kind: "process", command: "npm", log: "/tmp/j" };
const SUBAGENT: Job = { id: "j2", label: "Read", state: "running", kind: "plugin", plugin: "agents" };
const RUNNING: SessionUpdate = { sessionUpdate: "state", state: "running" };
const RESUME = "To resume this session, run: yuke -r s1";

/** A chat pane on the session `s1` with the running jobs `jobs`. */
async function opened(jobs: readonly Job[] = []) {
  const frame = createFrame({ width: 50, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(3));
  const chat = await loadChat(frame, sessions);
  // A frame test has no default keys.
  chat.tui.keys.add("ctrl+q", "core:quit");
  frame.start();
  await waitForSettled();
  // As the host does, the open of the pane gives the open of its session to each listener.
  open(chat, "s1", { jobs });
  frame.draw();
  return { frame, sessions, chat };
}

/** Give the chat the open of the session `id`, which no pane needs to show. */
function open(
  chat: Awaited<ReturnType<typeof loadChat>>,
  id: string,
  facts: { readonly parent?: string; readonly state?: "idle" | "running"; readonly jobs?: readonly Job[] } = {},
): void {
  const data = { sessionId: id, parent: facts.parent, state: facts.state ?? "idle", jobs: facts.jobs ?? [] };
  chat.fact("session.opened", { ...data, interactions: [] });
}

const screen = (frame: ReturnType<typeof createFrame>): string[] => {
  frame.draw();
  return rows(frame.frame);
};

test("a quit with no work ends at once and writes the resume command", async () => {
  const { frame } = await opened();
  using _frame = frame;

  frame.key("ctrl+q");

  assertEquals(frame.quits, [RESUME]);
});

test("a quit names each session once and leaves out a pane without a session", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  chat.tui.commands.run("core:split-right");
  await waitForSettled();
  chat.tui.commands.run("core:split-right");
  await waitForSettled();
  await chat.chat.show("s1");
  await waitForSettled();

  frame.key("ctrl+q");

  assertEquals(frame.quits, [RESUME]);
});

test("a quit with jobs asks, and it names the keys and what runs", async () => {
  const { frame } = await opened([JOB, SUBAGENT]);
  using _frame = frame;

  frame.key("ctrl+q");

  assertEquals(frame.quits, []);
  assertEquals(screen(frame).slice(-3), [
    " Stop everything and quit?",
    " 2 jobs are running.",
    " enter/ctrl+q: stop and quit · esc: stay",
  ]);
});

test("a quit during a turn asks, and the count names the turn and the job", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;
  chat.fact("session.update", { sessionId: "s1", update: RUNNING });

  frame.key("ctrl+q");

  assertEquals(screen(frame).at(-2), " 1 turn and 1 job are running.");
});

test("Esc stays, and the work goes on", async () => {
  const { frame, sessions } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  frame.key("esc");

  assertEquals(frame.quits, []);
  assertEquals(sessions.state.cancels, 0);
  assertEquals(screen(frame).includes(" Stop everything and quit?"), false);
});

test("Enter in the dialog quits", async () => {
  const { frame } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  frame.key("enter");

  assertEquals(frame.quits, [RESUME]);
});

test("a second quit key in the dialog quits, also after a stay and a new question", async () => {
  const { frame } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  frame.key("esc");
  frame.key("ctrl+q");
  const asked = frame.quits.length;
  frame.key("ctrl+q");

  assertEquals([asked, frame.quits], [0, [RESUME]]);
});

test("the quit command in the dialog quits and opens no second question", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  chat.tui.commands.run("core:quit");

  assertEquals(frame.quits, [RESUME]);
});

test("two panes on one session count its work once", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;
  chat.tui.commands.run("core:split-right");
  await waitForSettled();
  await chat.chat.show("s1");
  await waitForSettled();

  frame.key("ctrl+q");

  assertEquals(screen(frame).join("\n").includes("1 job is running."), true);
});

test("a read-only session warns about its own job, and a quit names its parent to resume", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  chat.chat.addReadOnly((session) => (session === "s1" ? { text: "A child", back: "p1" } : undefined));
  open(chat, "s1", { parent: "p1", jobs: [JOB] });
  frame.draw();

  frame.key("ctrl+q");

  assertEquals(screen(frame).join("\n").includes("1 job is running."), true);
  frame.key("ctrl+q");
  assertEquals(frame.quits, ["To resume this session, run: yuke -r p1"]);
});

test("an idle read-only session warns while its parent runs a turn, and not after that turn", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  chat.chat.addReadOnly((session) => (session === "s1" ? { text: "A child", back: "p1" } : undefined));
  open(chat, "p1", { state: "running" });
  frame.draw();

  frame.key("ctrl+q");
  assertEquals(screen(frame).join("\n").includes("1 turn is running."), true);
  frame.key("esc");

  chat.fact("session.update", { sessionId: "p1", update: { sessionUpdate: "state", state: "idle" } });
  frame.key("ctrl+q");
  assertEquals(frame.quits, ["To resume this session, run: yuke -r p1"]);
});

test("two read-only children of one parent count each job, and a quit resumes the parent once", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  chat.chat.addReadOnly((session) => (session === "p1" ? undefined : { text: "A child", back: "p1" }));
  chat.tui.commands.run("core:split-right");
  await waitForSettled();
  await chat.chat.show("s2");
  await waitForSettled();
  open(chat, "s1", { parent: "p1", jobs: [JOB] });
  open(chat, "s2", { parent: "p1", jobs: [{ ...JOB, id: "j3" }] });
  frame.draw();

  frame.key("ctrl+q");
  assertEquals(screen(frame).join("\n").includes("2 jobs are running."), true);
  frame.key("ctrl+q");
  assertEquals(frame.quits, ["To resume this session, run: yuke -r p1"]);
});

test("a turn and a job of a session that no pane shows ask, and the quit names that session to resume", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  open(chat, "s9", { state: "running", jobs: [JOB] });

  frame.key("ctrl+q");
  const asked = screen(frame).at(-2);
  frame.key("enter");

  assertEquals(
    [asked, frame.quits],
    [" 1 turn and 1 job are running.", [`${RESUME}\nTo resume this session, run: yuke -r s9`]],
  );
});

test("a subagent counts as one job of its parent, and its own turn does not count again", async () => {
  const { frame, chat } = await opened([SUBAGENT]);
  using _frame = frame;
  open(chat, "c1", { parent: "s1", state: "running" });

  frame.key("ctrl+q");
  const asked = screen(frame).at(-2);
  frame.key("enter");

  assertEquals([asked, frame.quits], [" 1 job is running.", [RESUME]]);
});

test("a job that ends and a turn that ends no longer count", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;
  chat.fact("session.update", { sessionId: "s1", update: RUNNING });
  chat.fact("session.update", { sessionId: "s1", update: { sessionUpdate: "job", job: { ...JOB, state: "ended" } } });
  chat.fact("session.update", { sessionId: "s1", update: { sessionUpdate: "state", state: "idle" } });

  frame.key("ctrl+q");

  assertEquals(frame.quits, [RESUME]);
});
