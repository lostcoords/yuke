// The `sessions` service of a plugin: its handles on the sessions of the host.

import type { PluginApply, Sessions } from "yuke:plugins";
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
