// The `tool.before` hook: its order, its event, its answers, and its failures.

import type { PluginSession, SessionHooks } from "yuke:plugins";
import { createHost, equal, test } from "yuke:test";

const call = { callId: "c1", name: "read", arguments: { path: ["src", "main.rs"] } };

/** A plugin whose `tool.before` handler runs `body` and gives its answer. */
const answering =
  (body: SessionHooks["tool.before"]): PluginSession =>
  (s) => {
    s.addHook("tool.before", body);
  };

// The first block ends the chain, so a later handler never sees the call.
test("the first denial in plugin order, then in addition order, stops the call", async () => {
  const seen: string[] = [];
  const first: PluginSession = (s) => {
    s.addHook("tool.before", () => {
      seen.push("first one");
      return undefined;
    });
    s.addHook("tool.before", () => {
      seen.push("first two");
      return { deny: "first says no" };
    });
  };
  const second: PluginSession = (s) => {
    s.addHook("tool.before", () => {
      seen.push("second");
      return { deny: "second says no" };
    });
  };
  await using host = await createHost({
    plugins: [
      { name: "first", session: first },
      { name: "second", session: second },
    ],
  });
  const session = await host.openSession();

  equal(await session.runHook("tool.before", { call }), { deny: "first says no" });
  equal(seen, ["first one", "first two"]);
});

test("the decision is run when no handler denies the call", async () => {
  await using host = await createHost({ plugins: [{ name: "quiet", session: answering(() => undefined) }] });
  const session = await host.openSession();

  equal(await session.runHook("tool.before", { call }), "run");
});

test("a handler gets the id, the name, and the parsed arguments of the call", async () => {
  const reader: PluginSession = (s) => {
    s.addHook("tool.before", (event) => {
      const path = (event.call.arguments as { path: string[] }).path;
      return { deny: `${event.call.callId} ${event.call.name} ${path.join("/")}` };
    });
  };
  await using host = await createHost({ plugins: [{ name: "reader", session: reader }] });
  const session = await host.openSession();

  equal(await session.runHook("tool.before", { call }), { deny: "c1 read src/main.rs" });
});

test("a throw stops the call and names the plugin", async () => {
  const check = answering(() => {
    throw new Error("no check today");
  });
  await using host = await createHost({ plugins: [{ name: "check", session: check }] });
  const session = await host.openSession();

  equal(await session.runHook("tool.before", { call }), {
    deny: "tool.before of plugin check failed: Error: no check today",
  });
});
