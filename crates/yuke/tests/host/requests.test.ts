// The requests of the plugins to the client in a session of the test host, which has no client.

import { ExtensionRequestError, type PluginSession } from "yuke:plugins";
import { createHost, equal, test } from "yuke:test";

/** A plugin whose tool `read_session` sends a request, and answers with the rejection. */
const requester: PluginSession = (s) => {
  s.tools.define({
    name: "read_session",
    description: "Read a session.",
    concurrency: "serial",
    parameters: { type: "object", properties: {} },
    execute: async (_args, context) => {
      try {
        await s.request("session.read", { id: "S-42" }, { signal: context.signal });
        return "answered";
      } catch (error) {
        return `${error instanceof ExtensionRequestError} ${String(error)}`;
      }
    },
  });
};

test("without a client, a request rejects at once with an Error", async () => {
  await using host = await createHost({ plugins: [{ name: "requester", session: requester }] });
  const session = await host.openSession();

  equal((await session.call("read_session", {})).text, "false Error: no client can answer the request");
});
