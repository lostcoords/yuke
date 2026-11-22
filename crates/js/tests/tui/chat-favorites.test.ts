// The favorites of the bundled chat: their rows at the top of /model, their commands and keys, and the newest version
// of a `*` model.

import { readTextFile } from "yuke:fs";
import { resolveFavorite } from "yuke:internal/bundled/chat/favorites";
import type { ListCatalogResult } from "yuke:protocol";
import { assertEquals, createFrame, folder, test, waitForSettled } from "yuke:test";
import { fakeSessions, loadChat, SETTINGS } from "./chat.ts";
import { rows } from "./rows.ts";

test("/model lists the ready favorites first, and a favorite sets the model and the level in one pick", async () => {
  using frame = createFrame({ width: 40, height: 14 });
  const chat = await loadChat(frame, fakeSessions(), undefined, {
    favorites: [
      { name: "fast", model: "p/n", reasoning: "low" },
      { model: "p/gone", reasoning: "high" },
      { model: "p/m", reasoning: "high" },
    ],
  });
  frame.start();
  frame.key("ctrl+k m");
  await waitForSettled();
  frame.draw();
  const listed = rows(frame.frame).filter((line) => line.includes("p/"));
  assertEquals(
    listed.map((line) => line.trim()),
    ["fast · p/n · low", "p/m · high", "p/m", "p/n"],
  );
  frame.key("enter");
  await waitForSettled();
  assertEquals(
    [
      JSON.parse(await readTextFile("choice.json", { folder: folder() })),
      chat.tui.status.list().some((item) => item.id === "chat:model" && item.text === "n low"),
    ],
    [{ model: { provider: "p", model: "n" }, reasoning: "low" }, true],
  );
});

test("the key of a favorite changes the model and the level of the session and keeps its other settings", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions([{ seq: 1, kind: "settings", ...SETTINGS }]);
  await loadChat(frame, sessions, undefined, {
    favorites: [{ name: "fast", model: "p/n", reasoning: "low", key: "ctrl+x f" }],
  });
  frame.start();
  await waitForSettled();
  frame.key("ctrl+x f");
  await waitForSettled();
  assertEquals(sessions.changes, [
    {
      ...SETTINGS,
      model: { provider: "p", model: "n" },
      settings: { ...SETTINGS.settings, reasoning: { effort: "low" } },
    },
  ]);
});

test("a favorite without a ready model gives a notice and changes nothing", async () => {
  using frame = createFrame({ width: 40, height: 14 });
  const chat = await loadChat(frame, fakeSessions(), undefined, {
    favorites: [{ name: "gone", model: "p/gone", reasoning: "high" }],
  });
  frame.start();
  chat.tui.commands.run("chat:favorite-gone");
  await waitForSettled();
  assertEquals(chat.notices, ["info No ready model matches p/gone with high reasoning"]);
});

test("a favorite name that no command can take gives a notice, and the other favorites keep their commands", async () => {
  using frame = createFrame({ width: 40, height: 14 });
  const chat = await loadChat(frame, fakeSessions(), undefined, {
    favorites: [
      { name: "two words", model: "p/n", reasoning: "low" },
      { name: "fast", model: "p/n", reasoning: "low" },
    ],
  });
  assertEquals(
    [
      chat.notices.map((notice) => notice.startsWith("error The favorite two words has no command:")),
      chat.tui.commands.list().some((command) => command.name === "chat:favorite-fast"),
    ],
    [[true], true],
  );
});

test("a * in the model of a favorite takes the newest version", () => {
  const model = (id: string) => ({ id, name: id, reasoning: [{ level: "high", settings: { effort: "high" } }] });
  const catalog = {
    providers: [
      { id: "o", models: ["gpt-5.6-sol", "gpt-9.9-sol", "gpt-10-sol", "gpt-10.1-luna", "gpt-x-sol"].map(model) },
    ],
  } as unknown as ListCatalogResult;
  const found = resolveFavorite({ model: "o/gpt-*-sol", reasoning: "high" }, catalog.providers);
  assertEquals(found?.model.id, "gpt-10-sol");
});
