// The `sessions` service of a plugin: its handles on the sessions of the host.

import type { PluginApply, PluginSession, Sessions } from "yuke:plugins";
import { createHost, equal, rejects, test } from "yuke:test";

test("the close of a session ends each handle on it", async () => {
  let sessions: Sessions | undefined;
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "holder", apply: holder }] });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  const first = await sessions.open(session.id, { tail: 5, event: () => undefined });
  const second = await sessions.open(session.id, { tail: 5, event: () => undefined });

  await sessions.close(session.id);

  equal([first.signal.aborted, second.signal.aborted], [true, true]);
  const reason = first.signal.reason;
  equal(reason instanceof Error ? reason.message : reason, `the session ${session.id} closed`);
  const refused = await rejects(second.input([{ user_text: "late" }]));
  equal(refused instanceof Error ? refused.message : refused, `the handle of the session ${session.id} has ended`);
});

test("a removal of a waiting input gives true and one update, and a second removal gives false", async () => {
  let sessions: Sessions | undefined;
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  // The hook holds the input, so it waits and no turn takes it.
  const { promise: held, resolve: release } = Promise.withResolvers<void>();
  const { promise: waiting, resolve: entered } = Promise.withResolvers<void>();
  const hold: PluginSession = (s) => {
    s.hook("input.before", async () => {
      entered();
      await held;
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "holder", apply: holder, session: hold }] });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  const removed: number[] = [];
  const handle = await sessions.open(session.id, {
    tail: 0,
    event: (event) => {
      if ("update" in event && event.update.sessionUpdate === "input_removed") removed.push(event.update.inputId);
    },
  });

  const input = await handle.input([{ user_text: "hi" }]);
  await waiting;
  const first = await handle.removeInput(input);
  const second = await handle.removeInput(input);
  release();
  await handle.idle();

  equal([first, second, removed, host.requests.length], [true, false, [input], 0]);
});
