// Session titles through the real plugin service and the application store.

import type { PluginApply, Sessions } from "yuke:plugins";
import { createHost, equal, rejects, reply, test } from "yuke:test";

test("a title starts from the first message, renames independently of context, and prefixes a fork", async () => {
  let sessions: Sessions | undefined;
  const apply: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  await using host = await createHost({
    plugins: [{ name: "titles", apply }],
    replies: [reply.text("Investigating."), reply.text("Fixed.")],
  });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");

  await session.sendMessage("  Fix\n the\tlogin tests  ");
  equal((await sessions.get(session.id)).session.title, "Fix the login tests");
  await sessions.rename(session.id, "  Private\n navigation label  ");
  await session.sendMessage("Check token refresh too.");
  const fork = await sessions.fork(session.id);

  equal(
    [(await sessions.get(session.id)).session.title, (await sessions.get(fork)).session.title],
    ["Private navigation label", "Fork — Private navigation label"],
  );
  equal(host.requests.length, 2);
  equal(JSON.stringify(host.requests).includes("Private navigation label"), false);
  await session.close();
  await sessions.rename(session.id, "Finished login fix");
  equal((await sessions.get(session.id)).session.title, "Finished login fix");
});

test("a title set before the first message survives it and invalid renames preserve the title", async () => {
  let sessions: Sessions | undefined;
  const apply: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  await using host = await createHost({
    plugins: [{ name: "titles", apply }],
    replies: [reply.text("Done.")],
  });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  await sessions.rename(session.id, "User-chosen title");
  await session.sendMessage("A different first message.");

  const empty = await rejects(sessions.rename(session.id, " \n\t "));
  const long = await rejects(sessions.rename(session.id, "é".repeat(201)));

  equal(
    [
      String(empty).includes("a session title must contain 1 to 200 characters"),
      String(long).includes("a session title must contain 1 to 200 characters"),
    ],
    [true, true],
  );
  equal((await sessions.get(session.id)).session.title, "User-chosen title");
  equal(
    (await sessions.list()).sessions.map((row) => row.session.title),
    ["User-chosen title"],
  );
});
