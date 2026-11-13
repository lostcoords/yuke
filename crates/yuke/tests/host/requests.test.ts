// The requests of the plugins to the client in a session of the test host.

import { ClientRequestError, type PluginSession } from "yuke:plugins";
import type { ExtensionRequestParams } from "yuke:protocol";
import { assertEquals, assertRejects, createHost, test, waitForSettled } from "yuke:test";

/** A plugin whose tool `read_session` sends a request. It gives the result, the error, or an event of a failure. */
const requester: PluginSession = (s) => {
  s.tools.add({
    name: "read_session",
    description: "Read a session.",
    concurrency: "serial",
    inputSchema: { type: "object", properties: {} },
    execute: async (_args, context) => {
      try {
        const found = (await s.sendClientRequest("session.read", { id: "S-42" }, { signal: context.signal })) as {
          title: string;
        };
        return `title: ${found.title}`;
      } catch (error) {
        if (error instanceof ClientRequestError) return `refused ${error.code} ${error.message} ${error.data}`;
        s.sendClientEvent("failed", String(error));
        throw error;
      }
    },
  });
};

test("without a client, a request rejects at once with an Error", async () => {
  await using host = await createHost({ plugins: [{ name: "requester", session: requester }] });
  const session = await host.openSession();

  const outcome = await session.call("read_session", {});

  assertEquals(
    host.events.map((event) => event.data),
    ["Error: no client can answer the request"],
  );
  assertEquals(outcome.isError, true);
});

test("the result of onClientRequest reaches the plugin, and onClientRequest gets the request", async () => {
  const requests: ExtensionRequestParams[] = [];
  await using host = await createHost({
    plugins: [{ name: "requester", session: requester }],
    onClientRequest: (request) => {
      requests.push(request);
      return { title: "fix the login" };
    },
  });
  const session = await host.openSession();

  assertEquals((await session.call("read_session", {})).text, "title: fix the login");
  assertEquals(requests, [
    { sessionId: session.id, extension: "requester", request: "session.read", data: { id: "S-42" } },
  ]);
});

test("a thrown ClientRequestError of onClientRequest is the error answer", async () => {
  await using host = await createHost({
    plugins: [{ name: "requester", session: requester }],
    onClientRequest: async () => {
      throw new ClientRequestError("no such session", { code: -32_001, data: "deleted" });
    },
  });
  const session = await host.openSession();

  assertEquals((await session.call("read_session", {})).text, "refused -32001 no such session deleted");
});

test("a cancel of the plugin ends its wait while onClientRequest still runs", async () => {
  let responding = false;
  await using host = await createHost({
    plugins: [{ name: "requester", session: requester }],
    onClientRequest: () => {
      responding = true;
      return new Promise(() => undefined);
    },
  });
  const session = await host.openSession();
  const stop = new AbortController();

  const called = session.call("read_session", {}, { signal: stop.signal });
  await waitForSettled();
  assertEquals(responding, true);
  stop.abort(new Error("stop"));

  await assertRejects(() => called);
  assertEquals(
    host.events.map((event) => String(event.data).split(":")[0]),
    ["AbortError"],
  );
});
