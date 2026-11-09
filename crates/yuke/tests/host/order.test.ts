// The order guarantees of the test host: an operation returns after its updates and its reports arrived.

import type { PluginSession } from "yuke:plugins";
import { createHost, equal, reply, test } from "yuke:test";

// Many updates require several deliveries of the feed.
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
