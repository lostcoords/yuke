// The bundled plugin `sessions`: the list of the recent sessions, its scope, its search, and the show of a pick.

import { apply } from "yuke:internal/bundled/sessions";
import type { SessionActivity, SessionRow } from "yuke:protocol";
import { createFrame, equal, type FrameTest, test, waitForSettled } from "yuke:test";
import { fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

/** A saved session `id` of the folder `cwd` with the title `title`, `minutes` old. */
function row(id: string, cwd: string, title: string | null, activity: SessionActivity, minutes: number): SessionRow {
  const updatedAt = Date.now() - minutes * 60_000;
  return {
    session: { sessionId: id, model: { provider: "p", model: "m" }, cwd, title, createdAt: updatedAt, updatedAt },
    activity,
  };
}

/** A chat on session `s1` of `/w` and the plugin `sessions` in `frame`, with three saved sessions. */
async function load(frame: FrameTest, sessions = fakeSessions(replies(2))) {
  sessions.rows.push(
    row("s1", "/w", "fix the flaky test", "running", 5),
    row("s2", "/w", "add the bar", "closed", 180),
    row("s3", "/home/other", "refactor sqlgen", "idle", 2 * 24 * 60),
  );
  const chat = await loadChat(frame, sessions);
  const notices: string[] = [];
  const services: Record<string, unknown> = { tui: frame.surface("sessions").tui, sessions, chat: chat.chat };
  apply({
    get: (name: string) => services[name],
    notify: (level: string, text: string) => notices.push(`${level} ${text}`),
  } as never);
  frame.start();
  return { chat, sessions, notices };
}

/** Run `/sessions`, and give the drawn rows after its list loads. */
async function openList(frame: FrameTest, chat: Awaited<ReturnType<typeof loadChat>>): Promise<string[]> {
  chat.tui.commands.run("sessions:open");
  await waitForSettled();
  frame.draw();
  return rows(frame.frame);
}

test("the list shows the sessions of the folder of the pane, and tab shows every folder", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const loaded = await load(frame);
  await waitForSettled();
  const here = await openList(frame, loaded.chat);
  frame.key("tab");
  await waitForSettled();
  frame.draw();
  const every = rows(frame.frame);
  /** Whether one row of `all` holds every text of `texts`, in any column. */
  const shows = (all: string[], ...texts: string[]) => all.some((line) => texts.every((text) => line.includes(text)));
  equal(
    loaded.sessions.lists.map((list) => list.cwd),
    ["/w", undefined],
  );
  equal(
    [
      here.some((line) => line.trim() === "/w"),
      shows(here, "tab: every folder · esc: close"),
      shows(here, "●", "fix the flaky test"),
      shows(here, "add the bar"),
    ],
    [true, true, true, true],
  );
  equal(
    [
      shows(here, "refactor"),
      every.some((line) => line.trim() === "every folder"),
      shows(every, "tab: this folder · esc: close"),
      shows(every, "○", "refactor sqlgen", "other"),
    ],
    [false, true, true, true],
  );
});

test("a query matches the first prompt, and else the model, the folder, or the id", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const loaded = await load(frame);
  await waitForSettled();
  await openList(frame, loaded.chat);
  frame.key("tab");
  await waitForSettled();
  const shown = (query: string): string[] => {
    frame.paste(query);
    frame.draw();
    const drawn = rows(frame.frame);
    for (const _ of query) frame.key("backspace");
    return ["fix the flaky test", "add the bar", "refactor sqlgen"].filter((text) =>
      drawn.some((line) => line.includes(text)),
    );
  };
  equal(
    [shown("flaky"), shown("home/oth"), shown("s2"), shown("m")],
    [
      ["fix the flaky test"],
      ["refactor sqlgen"],
      ["add the bar"],
      ["fix the flaky test", "add the bar", "refactor sqlgen"],
    ],
  );
});

test("enter shows the chosen session in the focused chat pane and closes the list", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const loaded = await load(frame);
  await waitForSettled();
  await openList(frame, loaded.chat);
  frame.paste("bar");
  frame.key("enter");
  await waitForSettled();
  frame.draw();
  equal(
    [loaded.chat.opened.map((open) => open.id), rows(frame.frame).some((line) => line.includes("tab: every folder"))],
    [["s1", "s2"], false],
  );
});

test("a pick that does not open gives a notice", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(replies(2));
  sessions.rows.push(row("missing", "/w", "gone", "closed", 1));
  const loaded = await load(frame, sessions);
  await waitForSettled();
  await openList(frame, loaded.chat);
  frame.paste("gone");
  frame.key("enter");
  await waitForSettled();
  equal(loaded.notices, ["error the session missing did not show: Error: no session missing"]);
});

test("a list of an earlier scope that loads late keeps the list of the later scope", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(replies(2));
  const { promise, resolve } = Promise.withResolvers<void>();
  const list = sessions.list;
  let first = true;
  sessions.list = async (params) => {
    const page = await list(params);
    if (first) {
      first = false;
      await promise;
    }
    return page;
  };
  const loaded = await load(frame, sessions);
  await waitForSettled();
  await openList(frame, loaded.chat);
  frame.key("tab");
  await waitForSettled();
  resolve();
  await waitForSettled();
  frame.draw();
  equal(
    rows(frame.frame).some((line) => line.includes("refactor sqlgen")),
    true,
  );
});

test("a match of the first prompt comes before a match of the folder of a newer session", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(replies(2));
  sessions.rows.push(row("s4", "/srv/bar", "deploy notes", "closed", 1));
  const loaded = await load(frame, sessions);
  await waitForSettled();
  await openList(frame, loaded.chat);
  frame.key("tab");
  await waitForSettled();
  frame.paste("bar");
  frame.draw();
  const drawn = rows(frame.frame);
  const at = (text: string) => drawn.findIndex((line) => line.includes(text));
  equal([at("add the bar") >= 0, at("add the bar") < at("deploy notes")], [true, true]);
});

test("a failed list of an earlier scope leaves the list of the later scope open", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(replies(2));
  const { promise, reject } = Promise.withResolvers<void>();
  const list = sessions.list;
  let first = true;
  sessions.list = async (params) => {
    if (first) {
      first = false;
      await promise;
    }
    return list(params);
  };
  const loaded = await load(frame, sessions);
  await waitForSettled();
  await openList(frame, loaded.chat);
  frame.key("tab");
  await waitForSettled();
  reject(new Error("disk"));
  await waitForSettled();
  frame.draw();
  equal([rows(frame.frame).some((line) => line.includes("refactor sqlgen")), loaded.notices], [true, []]);
});

test("the list of a pane whose session is gone starts with the start folder", async () => {
  using frame = createFrame({ width: 60, height: 14 }, undefined, { cwd: "/start", session: "s9" });
  const loaded = await load(frame);
  await waitForSettled();
  const drawn = await openList(frame, loaded.chat);
  equal(
    [drawn.some((line) => line.trim() === "/start"), loaded.sessions.lists],
    [true, [{ cwd: "/start", limit: 100 }]],
  );
});
