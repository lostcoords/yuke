// A stop of the session tree in the bundled chat: a quit, `/new`, and a switch of the root ask while the tree runs a
// turn or a job, and they say what stops. `/new` and a switch close the old root.

import type { Job, SessionUpdate } from "yuke:protocol";
import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { composerOf, fakeSessions, loadChat, replies, row } from "./chat.ts";

const JOB: Job = { id: "j1", label: "npm run dev", state: "running", kind: "process", command: "npm", log: "/tmp/j" };
const SUBAGENT: Job = { id: "j2", label: "Read", state: "running", kind: "plugin", plugin: "agents" };
const RUNNING: SessionUpdate = { kind: "state", state: "running" };
const RESUME = "To resume this session, run: yuke -r s1";

/** A chat on the root `s1` with the running jobs `jobs`. The session `c1` is a child of `s1`, and `s2` is a root. */
async function opened(jobs: readonly Job[] = []) {
  const frame = createFrame({ width: 50, height: 12 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(3));
  sessions.rows.push(row("s1"), row("c1", { parent: "s1" }), row("s2"));
  const chat = await loadChat(frame, sessions);
  // A frame test has no default keys.
  chat.tui.keys.add("ctrl+q", "core:quit");
  frame.start();
  await waitForSettled();
  // As the host does, the open of the root gives the open of its session to each listener.
  open(chat, "s1", { jobs });
  frame.draw();
  return { frame, sessions, chat };
}

/** Give the chat the open of the session `id`, which the chat does not need to show. */
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
  return frame.rows();
};

test("a quit with no work ends at once and writes the resume command", async () => {
  const { frame } = await opened();
  using _frame = frame;

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
  await waitForSettled();

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
  await waitForSettled();

  assertEquals([asked, frame.quits], [0, [RESUME]]);
});

test("the quit command in the dialog quits and opens no second question", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;

  frame.key("ctrl+q");
  chat.tui.commands.run("core:quit");

  assertEquals(frame.quits, [RESUME]);
});

test("a quit while a child shows counts the own job of the child, and names the root to resume", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  await chat.chat.show("c1");
  open(chat, "c1", { parent: "s1", jobs: [JOB] });
  frame.draw();

  frame.key("ctrl+q");

  assertEquals(screen(frame).join("\n").includes("1 job is running."), true);
  frame.key("ctrl+q");
  await waitForSettled();
  assertEquals(frame.quits, [RESUME]);
});

test("two children of the root count each job", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  open(chat, "c1", { parent: "s1", jobs: [JOB] });
  open(chat, "c2", { parent: "s1", jobs: [{ ...JOB, id: "j3" }] });

  frame.key("ctrl+q");

  assertEquals(screen(frame).join("\n").includes("2 jobs are running."), true);
});

test("the work of a session outside the tree does not count", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  open(chat, "s9", { state: "running", jobs: [JOB] });

  frame.key("ctrl+q");

  assertEquals(frame.quits, [RESUME]);
});

test("a subagent counts as one job of its parent, and its own turn does not count again", async () => {
  const { frame, chat } = await opened([SUBAGENT]);
  using _frame = frame;
  open(chat, "c1", { parent: "s1", state: "running" });

  frame.key("ctrl+q");
  const asked = screen(frame).at(-2);
  frame.key("enter");
  await waitForSettled();

  assertEquals([asked, frame.quits], [" 1 job is running.", [RESUME]]);
});

test("a job that ends and a turn that ends no longer count", async () => {
  const { frame, chat } = await opened([JOB]);
  using _frame = frame;
  chat.fact("session.update", { sessionId: "s1", update: RUNNING });
  chat.fact("session.update", { sessionId: "s1", update: { kind: "job", job: { ...JOB, state: "ended" } } });
  chat.fact("session.update", { sessionId: "s1", update: { kind: "state", state: "idle" } });

  frame.key("ctrl+q");

  assertEquals(frame.quits, [RESUME]);
});

test("/new with no work closes the root at once and empties the chat", async () => {
  const { frame, sessions, chat } = await opened();
  using _frame = frame;

  frame.key("/ n e w enter");
  await waitForSettled();

  assertEquals([sessions.closes, chat.chat.sessionId()], [["s1"], undefined]);
});

test("/new asks while the tree runs, a stay keeps the root and its draft, and a stop closes the root", async () => {
  const { frame, sessions, chat } = await opened([JOB]);
  using _frame = frame;

  chat.tui.commands.run("chat:new");
  await waitForSettled();
  const asked = screen(frame).slice(-3);
  frame.key("esc");
  await waitForSettled();
  const stayed = [sessions.closes.length, chat.chat.sessionId()];
  chat.tui.commands.run("chat:new");
  await waitForSettled();
  frame.key("enter");
  await waitForSettled();

  assertEquals(asked, [" Stop them and switch?", " 1 job is running.", " enter: stop and switch · esc: stay"]);
  assertEquals(stayed, [0, "s1"]);
  assertEquals([sessions.closes, chat.chat.sessionId()], [["s1"], undefined]);
});

test("a show of another root asks while the tree runs, and a stop opens it, closes the old root, and clears the draft", async () => {
  const { frame, sessions, chat } = await opened([JOB]);
  using _frame = frame;
  frame.paste("draft of s1");

  const showing = chat.chat.show("s2");
  await waitForSettled();
  const asked = screen(frame).at(-2);
  frame.key("enter");
  await showing;

  assertEquals(asked, " 1 job is running.");
  assertEquals([sessions.closes, chat.chat.sessionId(), composerOf(chat).state.text], [["s1"], "s2", ""]);
});

test("a stay at a show of another root keeps the root, and the show resolves", async () => {
  const { frame, sessions, chat } = await opened([JOB]);
  using _frame = frame;

  const showing = chat.chat.show("s2");
  await waitForSettled();
  frame.key("esc");
  await showing;

  assertEquals([sessions.closes, chat.chat.sessionId(), chat.opened.map((open) => open.id)], [[], "s1", ["s1"]]);
});

test("a show of a child asks nothing and closes nothing, also while the tree runs", async () => {
  const { frame, sessions, chat } = await opened([JOB]);
  using _frame = frame;

  await chat.chat.show("c1");

  assertEquals(
    [sessions.closes, chat.chat.sessionId(), screen(frame).includes(" Stop them and switch?")],
    [[], "c1", false],
  );
});
