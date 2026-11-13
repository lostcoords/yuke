// The header of an empty chat pane: the icon, the version, the model and the folder of the first message, and the way
// to start.

import { writeTextFile } from "yuke:fs";
import { emptyHeader } from "yuke:internal/bundled/chat/empty";
import { env } from "yuke:process";
import type { Block, SessionUpdate } from "yuke:protocol";
import { assertEquals, createFrame, folder, test, waitForSettled } from "yuke:test";
import { CATALOG, fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

/** The first cell row of the icon: the antennae. */
const ICON_TOP = " 🬂🬀🬋🬱  🬵🬋🬁🬂";

/** The cells `from` up to `to` of `row`. A sextant is two UTF-16 units, so the cut counts code points. */
function cells(row: string | undefined, from: number, to?: number): string {
  return [...(row ?? "")].slice(from, to).join("");
}

/** Save the pick `p/m` at the level high, so a send needs no picker. */
async function savedPick(): Promise<void> {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    cwd: folder(),
  });
}

function accepted(id: number, content: Block[]): SessionUpdate {
  return {
    sessionUpdate: "inputAccepted",
    inputId: id,
    input: { source: { kind: "user" }, kind: "message", content },
  };
}

test("a pane without a session shows the icon and, beside it, the version, the model, the folder, and the way to start", async () => {
  await savedPick();
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/w", version: "1.2.3" });
  await loadChat(frame);
  frame.start();
  await waitForSettled();
  frame.draw();
  const shown = rows(frame.frame);

  assertEquals(
    [cells(shown[1], 2, 13), cells(shown[1], 16), cells(shown[2], 16), cells(shown[3], 16)],
    [ICON_TOP, "yuke 1.2.3", "m high · /w", "Type / for commands"],
  );
});

test("the first send hides the header at once, and the waiting message keeps it hidden", async () => {
  await savedPick();
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/w" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.key("h i enter");
  frame.draw();
  const sending = rows(frame.frame).join("\n").includes("Type / for commands");
  await waitForSettled();
  sessions.push(accepted(1, [{ kind: "userText", text: "hi" }]), "s-new");
  await waitForSettled();
  frame.draw();

  assertEquals([sending, rows(frame.frame).join("\n").includes("Type / for commands")], [false, false]);
});

test("a session with history shows no header", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions(replies(3)));
  frame.start();
  await waitForSettled();
  frame.draw();

  assertEquals(rows(frame.frame).join("\n").includes("yuke 0.0.0"), false);
});

test("a narrow pane puts the lines below the icon and cuts a long line", async () => {
  await savedPick();
  using frame = createFrame({ width: 30, height: 20 }, undefined, {
    cwd: "/a/very/long/folder/name",
    version: "1.2.3",
  });
  await loadChat(frame);
  frame.start();
  await waitForSettled();
  frame.draw();
  const shown = rows(frame.frame);

  assertEquals(
    [cells(shown[1], 2), shown[6], shown[7], shown[8]],
    [ICON_TOP, "  yuke 1.2.3", "  m high · /a/very/long/fold…", "  Type / for commands"],
  );
});

test("a pane too short for the whole header shows none of it", async () => {
  await savedPick();
  using frame = createFrame({ width: 80, height: 8 }, undefined, { cwd: "/w" });
  await loadChat(frame);
  frame.start();
  await waitForSettled();
  frame.draw();

  assertEquals(
    rows(frame.frame).some((row) => row.includes("yuke") || row.includes("🬂")),
    false,
  );
});

test("without a ready provider the header names /login, and a catalog change brings the usual hint back", async () => {
  await savedPick();
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/w" });
  let ready = false;
  const chat = await loadChat(frame, fakeSessions(), { list: async () => (ready ? CATALOG : { providers: [] }) });
  frame.start();
  await waitForSettled();
  frame.draw();
  const before = rows(frame.frame)
    .slice(1, 4)
    .map((row) => cells(row, 16));

  ready = true;
  chat.fact("catalog.changed", undefined);
  await waitForSettled();
  frame.draw();

  assertEquals(
    [
      before,
      rows(frame.frame)
        .slice(1, 4)
        .map((row) => cells(row, 16)),
    ],
    [
      ["yuke 0.0.0", "/w", "Type /login to connect a provider"],
      ["yuke 0.0.0", "m high · /w", "Type / for commands"],
    ],
  );
});

test("the header names the model and the folder of the bar, with the home folder as ~", async () => {
  await savedPick();
  const home = env.get("HOME") ?? "/home";
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: `${home}/launch` });
  const chat = await loadChat(frame);
  frame.start();
  await waitForSettled();
  frame.draw();
  const bar = ["chat:model", "chat:folder"].map((key) => chat.tui.status.list().find((item) => item.id === key)?.text);

  assertEquals([cells(rows(frame.frame)[2], 16), bar], ["m high · ~/launch", ["m high", "~/launch"]]);
});

test("setEmptyView replaces the header in each pane, and its disposer brings the default back", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  await waitForSettled();
  const dispose = chat.chat.setEmptyView(() => ({ draw: (canvas) => canvas.text(1, 1, "Ask me anything.") }));
  frame.draw();
  const replaced = rows(frame.frame)[1];

  dispose();
  frame.draw();

  assertEquals([replaced, cells(rows(frame.frame)[1], 2, 13)], [" Ask me anything.", ICON_TOP]);
});

test("the option emptyView false shows nothing in an empty pane", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/w" });
  await loadChat(frame, fakeSessions(), undefined, { emptyView: false });
  frame.start();
  await waitForSettled();
  frame.draw();

  assertEquals(
    rows(frame.frame)
      .slice(0, 10)
      .every((row) => row === ""),
    true,
  );
});

test("a header without the icon shows the lines alone at the top left", () => {
  const header = emptyHeader({
    version: "1.2.3",
    target: () => ({ model: "m high", folder: "/w" }),
    ready: () => true,
    icon: false,
  });
  using frame = createFrame({ width: 40, height: 6 }, () => header);
  frame.start();
  frame.draw();

  assertEquals(rows(frame.frame).slice(0, 5), ["", "  yuke 1.2.3", "  m high · /w", "  Type / for commands", ""]);
});
