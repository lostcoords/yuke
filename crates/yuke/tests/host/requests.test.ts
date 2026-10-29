// The requests of the plugins to the client in a session of the test host.

import { ExtensionRequestError, type PluginSession } from "yuke:plugins";
import type { ExtensionRequestParams } from "yuke:protocol";
import { createHost, equal, rejects, test } from "yuke:test";

/** A plugin whose tool `read_session` sends a request. It gives the result, the error, or an event of a failure. */
const requester: PluginSession = (s) => {
  s.tools.define({
    name: "read_session",
    description: "Read a session.",
    concurrency: "serial",
    parameters: { type: "object", properties: {} },
    execute: async (_args, context) => {
      try {
        const found = (await s.request("session.read", { id: "S-42" }, { signal: context.signal })) as {
          title: string;
        };
        return `title: ${found.title}`;
      } catch (error) {
        if (error instanceof ExtensionRequestError) return `refused ${error.code} ${error.message} ${error.data}`;
        s.emit("failed", String(error));
        throw error;
      }
    },
  });
};

test("without a client, a request rejects at once with an Error", async () => {
  await using host = await createHost({ plugins: [{ name: "requester", session: requester }] });
  const session = await host.openSession();

  const outcome = await session.call("read_session", {});

  equal(
    host.events.map((event) => event.data),
    ["Error: no client can answer the request"],
  );
  equal(outcome.isError, true);
});

test("the result of respond reaches the plugin, and respond gets the request", async () => {
  const requests: ExtensionRequestParams[] = [];
  await using host = await createHost({
    plugins: [{ name: "requester", session: requester }],
    respond: (request) => {
      requests.push(request);
      return { title: "fix the login" };
    },
  });
  const session = await host.openSession();

  equal((await session.call("read_session", {})).text, "title: fix the login");
  equal(requests, [{ sessionId: session.id, extension: "requester", request: "session.read", data: { id: "S-42" } }]);
});

test("a thrown ExtensionRequestError of respond is the error answer", async () => {
  await using host = await createHost({
    plugins: [{ name: "requester", session: requester }],
    respond: async () => {
      throw new ExtensionRequestError("no such session", { code: -32_001, data: "deleted" });
    },
  });
  const session = await host.openSession();

  equal((await session.call("read_session", {})).text, "refused -32001 no such session deleted");
});

test("a cancel of the plugin ends its wait while respond still runs", async () => {
  await using host = await createHost({
    plugins: [{ name: "requester", session: requester }],
    respond: () => new Promise(() => undefined),
  });
  const session = await host.openSession();
  const stop = new AbortController();

  const called = session.call("read_session", {}, { signal: stop.signal });
  stop.abort(new Error("stop"));

  await rejects(called);
  equal(
    host.events.map((event) => event.data),
    ["AbortError: The tool call was cancelled"],
  );
});
