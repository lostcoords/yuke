// The order guarantees of the test host: an operation returns after its updates and its reports arrived.

import type { PluginSession } from "yuke:plugins";
import { createHost, equal, reply, test } from "yuke:test";

/** The texts `notice 0` to `notice 4999`. */
const texts = Array.from({ length: 5000 }, (_item, index) => `notice ${index}`);

// Many updates fill several deliveries of the feed, so only the flush lets `send` see each one.
test("send returns after the transcript got each update of the turn", async () => {
  const calls = Array.from({ length: 300 }, (_item, index) => ({ name: "noop", args: { index } }));
  const replies = [reply.toolCalls(calls), reply.text("Done.")];
  const noop: PluginSession = (s) => {
    s.tools.define({
      name: "noop",
      description: "Do nothing.",
      concurrency: "parallel",
      parameters: { type: "object", properties: { index: { type: "number" } } },
      execute: () => "ok",
    });
  };
  await using host = await createHost({ plugins: [{ name: "noop", session: noop }], replies });
  const session = await host.openSession();

  await session.send("Run them.");

  const done = session.transcript.entries.flatMap((entry) =>
    entry.kind === "tool" && entry.status === "done" ? [entry.arguments] : [],
  );
  equal(
    done,
    calls.map((call) => JSON.stringify(call.args)),
  );
});

// Many reports keep the report task of the app busy, so only the barrier lets `run` see each one.
test("run returns after the host recorded each notice of the handlers", async () => {
  const loud: PluginSession = (s) => {
    s.hook("tool.before", () => {
      for (const text of texts) s.notify("info", text);
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "loud", session: loud }] });
  const session = await host.openSession();

  await session.run("tool.before", { call: { callId: "c", name: "x", arguments: {} } });

  equal(
    host.notices.map((notice) => notice.message),
    texts,
  );
});
