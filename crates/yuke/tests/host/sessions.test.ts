// The `sessions` service of a plugin: its handles on the sessions of the host.

import type { PluginApply, PluginSession, Sessions } from "yuke:plugins";
import { assertEquals, assertRejects, createHost, reply, test, waitForSettled } from "yuke:test";

test("the close of a session ends each handle on it", async () => {
  let sessions: Sessions | undefined;
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "holder", apply: holder }] });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  const first = await sessions.open(session.id, { tail: 5, onEvent: () => undefined });
  const second = await sessions.open(session.id, { tail: 5, onEvent: () => undefined });

  await sessions.closeForAll(session.id);

  assertEquals([first.signal.aborted, second.signal.aborted], [true, true]);
  const reason = first.signal.reason;
  assertEquals(reason instanceof Error ? reason.message : reason, `the session ${session.id} closed`);
  const refused = await assertRejects(() => second.sendMessage({ content: [{ kind: "userText", text: "late" }] }));
  assertEquals(
    refused instanceof Error ? refused.message : refused,
    `the handle of the session ${session.id} has ended`,
  );
  const blob = await assertRejects(() => second.putBlob(new Uint8Array([1])));
  assertEquals(blob instanceof Error ? blob.message : blob, `the handle of the session ${session.id} has ended`);
});

test("a removal of a waiting input gives true and one update, and a second removal gives false", async () => {
  let sessions: Sessions | undefined;
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  // The hook holds the input, so it waits and no turn takes it.
  const { promise: held, resolve: release } = Promise.withResolvers<void>();
  const hold: PluginSession = (s) => {
    s.addHook("input.before", async () => {
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
    onEvent: (event) => {
      if (event.kind === "update" && event.update.sessionUpdate === "inputRemoved") removed.push(event.update.inputId);
    },
  });

  const input = await handle.sendMessage({ content: [{ kind: "userText", text: "hi" }] });
  await waitForSettled();
  const first = await handle.removeInput(input);
  const second = await handle.removeInput(input);
  release();
  await handle.waitForIdle();

  assertEquals([first, second, removed, host.requests.length], [true, false, [input], 0]);
});

test("a blob that a plugin saves reaches the model as the image of an input", async () => {
  let sessions: Sessions | undefined;
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "holder", apply: holder }], replies: [reply.text("seen")] });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  const handle = await sessions.open(session.id, { tail: 0, onEvent: () => undefined });

  const blob = await handle.putBlob(new Uint8Array([1, 2, 3]));
  await handle.sendMessage({
    content: [
      { kind: "userText", text: "see" },
      { kind: "media", blob, mimeType: "image/png" },
    ],
  });
  await handle.waitForIdle();

  // "AQID" is the base64 of the bytes 1, 2, 3.
  assertEquals([blob.len, JSON.stringify(host.requests[0]?.body).includes("AQID")], [3, true]);
});

test("a child session names its parent, stays out of the default list, and leaves with its parent", async () => {
  const parents: (string | undefined)[] = [];
  let sessions: Sessions | undefined;
  const plugin: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  const scope: PluginSession = (s) => {
    parents.push(s.parent);
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "agents", apply: plugin, session: scope }] });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  const child = await sessions.create(session.settings, { parent: session.id });

  const roots = await sessions.list();
  const children = await sessions.list({ parent: session.id });
  await session.close();
  await sessions.closeForAll(child);
  await sessions.remove(session.id);
  const failure = await assertRejects(() => (sessions as Sessions).get(child));

  assertEquals(parents, [undefined, session.id]);
  assertEquals(
    roots.sessions.map((row) => row.sessionId),
    [session.id],
  );
  assertEquals(
    children.sessions.map((row) => [row.sessionId, row.parent]),
    [[child, session.id]],
  );
  assertEquals(String(failure), "Error: the store has no such session");
});

test("a child that opens again names its saved parent", async () => {
  const contexts: { readonly parent: string | undefined }[] = [];
  let sessions: Sessions | undefined;
  const plugin: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  const scope: PluginSession = (s) => {
    contexts.push(s);
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "agents", apply: plugin, session: scope }] });
  const session = await host.openSession();
  if (sessions === undefined) throw new Error("the plugin got no sessions service");

  const child = await sessions.create(session.settings, { parent: session.id });
  await sessions.closeForAll(child);
  contexts.length = 0;
  await sessions.open(child, { tail: 0, onEvent: () => undefined });

  assertEquals(
    contexts.map((context) => context.parent),
    [session.id],
  );
});
