// The facts of `ctx.addListener`: the opens, the updates, and the closes of the sessions, and the notices.

import { auth } from "yuke:internal/sessions";
import type { HostEvents, PluginContext, PluginSession, SessionContext } from "yuke:plugins";
import type { QuestionAnswer } from "yuke:protocol";
import { assertEquals, createHost, reply, test, waitForSettled } from "yuke:test";

/** A plugin that keeps its context for the test. */
function watcher(): { readonly apply: (ctx: PluginContext) => undefined; readonly ctx: () => PluginContext } {
  let kept: PluginContext | undefined;
  return {
    apply: (ctx) => {
      kept = ctx;
      return undefined;
    },
    ctx: () => {
      if (kept === undefined) throw new Error("the plugin did not load");
      return kept;
    },
  };
}

/** A plugin whose tool `ask` asks the user a yes or no question. */
const asker: PluginSession = (s) => {
  s.tools.add({
    name: "ask",
    description: "Ask the user.",
    concurrency: "serial",
    inputSchema: { type: "object", properties: {} },
    execute: async (_args, context) => {
      const question = { id: "go", header: "Go", question: "Go on?", options: [{ label: "Yes" }, { label: "No" }] };
      return JSON.stringify(await s.ask({ questions: [question] }, { signal: context.signal })) ?? "undefined";
    },
  });
};

const yes: QuestionAnswer[] = [{ id: "go", values: ["Yes"] }];

test("a listener gets each open session first, then the states of a turn, a later open, and a close", async () => {
  const plugin = watcher();
  await using host = await createHost({
    plugins: [{ name: "watcher", apply: plugin.apply }],
    replies: [reply.text("Hello.")],
  });
  const first = await host.openSession();
  const seen: string[] = [];
  const ctx = plugin.ctx();
  ctx.addListener("session.opened", (data) =>
    seen.push(`opened ${data.sessionId === first.id ? "first" : "second"} ${data.state}`),
  );
  let frozen = true;
  // Each session starts with its open, so no update of a session comes before it.
  const opened = new Set<string>();
  let early = false;
  ctx.addListener("session.opened", (data) => opened.add(data.sessionId));
  ctx.addListener("session.update", (data) => {
    early ||= !opened.has(data.sessionId);
    frozen &&= Object.isFrozen(data) && Object.isFrozen(data.update);
    if (data.update.sessionUpdate === "state") seen.push(`state ${data.update.state}`);
  });
  ctx.addListener("session.closed", (data) => seen.push(`closed ${data.sessionId === first.id ? "first" : "second"}`));
  await waitForSettled();

  await first.sendMessage("Hi.");
  await host.openSession();
  await ctx.get("sessions").closeForAll(first.id);

  assertEquals(
    [seen, frozen, early],
    [["opened first idle", "state running", "state idle", "opened second idle", "closed first"], true, false],
  );
});

test("an open during a turn gives its state and interactions, and a later listener gets them as the facts left them", async () => {
  const plugin = watcher();
  const answered = Promise.withResolvers<QuestionAnswer[]>();
  await using host = await createHost({
    plugins: [
      { name: "watcher", apply: plugin.apply },
      { name: "asker", session: asker },
    ],
    replies: [reply.toolCalls([{ name: "ask", args: {} }]), reply.text("Done.")],
    onQuestion: () => answered.promise,
  });
  const session = await host.openSession();
  const ctx = plugin.ctx();
  /** The state and the count of interactions of each open that a new listener gets. */
  const opens = (): string[] => {
    const got: string[] = [];
    ctx.addListener("session.opened", (data) => got.push(`${data.state} ${data.interactions.length}`));
    return got;
  };
  const turn = session.sendMessage("Ask me.");
  await waitForSettled();
  assertEquals(host.questions.length, 1);
  // The first listener starts the watch, so the host gives the open as the session is now.
  const during = opens();
  await waitForSettled();
  answered.resolve(yes);
  await turn;
  // The watch runs already, so this listener gets the open as the facts of the turn left it.
  const after = opens();

  assertEquals([during, after], [["running 1"], ["idle 0"]]);
});

test("a listener that comes during a question of a running watch gets the open as the facts made it", async () => {
  const plugin = watcher();
  const answered = Promise.withResolvers<QuestionAnswer[]>();
  await using host = await createHost({
    plugins: [
      { name: "watcher", apply: plugin.apply },
      { name: "asker", session: asker },
    ],
    replies: [reply.toolCalls([{ name: "ask", args: {} }]), reply.text("Done.")],
    onQuestion: () => answered.promise,
  });
  const session = await host.openSession();
  const ctx = plugin.ctx();
  const first: string[] = [];
  ctx.addListener("session.opened", (data) => first.push(`${data.state} ${data.interactions.length}`));
  await waitForSettled();
  const turn = session.sendMessage("Ask me.");
  await waitForSettled();
  assertEquals(host.questions.length, 1);
  const later: string[] = [];
  ctx.addListener("session.opened", (data) => later.push(`${data.state} ${data.interactions.length}`));
  answered.resolve(yes);
  await turn;

  assertEquals([first, later], [["idle 0"], ["running 1"]]);
});

test("an open gives the parent and the running jobs, and a later listener gets the jobs as the updates left them", async () => {
  const plugin = watcher();
  const contexts = new Map<string, SessionContext>();
  await using host = await createHost({
    plugins: [
      {
        name: "watcher",
        apply: plugin.apply,
        session: (s) => {
          contexts.set(s.sessionId, s);
        },
      },
    ],
  });
  const parent = await host.openSession();
  const ctx = plugin.ctx();
  const child = await ctx.get("sessions").create(parent.settings, { parent: parent.id });
  const end = Promise.withResolvers<undefined>();
  await contexts.get(parent.id)?.jobs.start({ id: "explorer", label: "one" }, () => end.promise);
  /** The opens that a new listener gets: the session, its parent, and the ids of its running jobs. */
  const opens = (): string[] => {
    const got: string[] = [];
    ctx.addListener("session.opened", (data) => {
      const name = data.sessionId === child ? "child" : "parent";
      const of = data.parent === undefined ? "top" : data.parent === parent.id ? "of parent" : "of another";
      got.push(`${name} ${of} [${data.jobs.map((job) => job.id).join()}]`);
    });
    return got;
  };
  // The first listener starts the watch, so the host gives each open as the session is now.
  const during = opens();
  await waitForSettled();
  end.resolve(undefined);
  await waitForSettled();
  // The watch runs already, so this listener gets each open as the job updates left it.
  const after = opens();

  assertEquals(
    [during.toSorted(), after.toSorted()],
    [
      ["child of parent []", "parent top [explorer]"],
      ["child of parent []", "parent top []"],
    ],
  );
});

test("a stored API key and a logout each tell the listeners that the catalog changed", async () => {
  const plugin = watcher();
  await using _host = await createHost({ plugins: [{ name: "watcher", apply: plugin.apply }] });
  const ctx = plugin.ctx();
  let changes = 0;
  ctx.addListener("catalog.changed", () => {
    changes += 1;
  });
  await waitForSettled();

  await auth.setApiKey("anthropic", "sk-test");
  await auth.logout("anthropic");
  await waitForSettled();

  assertEquals(changes, 2);
});

test("a listener that throws gives a notice for each throw, and it and the other listeners stay", async () => {
  const plugin = watcher();
  await using host = await createHost({ plugins: [{ name: "watcher", apply: plugin.apply }] });
  await host.openSession();
  const ctx = plugin.ctx();
  let throws = 0;
  let others = 0;
  ctx.addListener("session.opened", () => {
    throws += 1;
    throw new Error("broken");
  });
  ctx.addListener("session.opened", () => {
    others += 1;
  });
  await waitForSettled();
  await host.openSession();

  assertEquals(
    [
      throws,
      others,
      host.notices.filter((notice) => notice.source === "watcher").map((notice) => notice.text.split("\n")[0]),
    ],
    [
      2,
      2,
      ["a listener of session.opened failed: Error: broken", "a listener of session.opened failed: Error: broken"],
    ],
  );
});

test("a notice of a plugin reaches the notice listeners of another plugin, until the remover runs", async () => {
  const plugin = watcher();
  const sender = watcher();
  await using _host = await createHost({
    plugins: [
      { name: "watcher", apply: plugin.apply },
      { name: "sender", apply: sender.apply },
    ],
  });
  const got: HostEvents["notice"][] = [];
  const remove = plugin.ctx().addListener("notice", (data) => got.push(data));
  const delivered: string[] = [];
  plugin.ctx().addListener("notice", (data) => delivered.push(data.text));
  sender.ctx().notify("info", "first");
  await waitForSettled();
  remove();
  sender.ctx().notify("info", "second");
  await waitForSettled();

  assertEquals(
    [got.map((notice) => [notice.source, notice.level, notice.text]), delivered],
    [[["sender", "info", "first"]], ["first", "second"]],
  );
});

test("the last removal ends the watch, and a new listener gets the open sessions again", async () => {
  const plugin = watcher();
  await using host = await createHost({ plugins: [{ name: "watcher", apply: plugin.apply }] });
  await host.openSession();
  const ctx = plugin.ctx();
  const first: string[] = [];
  const remove = ctx.addListener("session.opened", (data) => first.push(data.sessionId));
  await waitForSettled();
  remove();
  const again: string[] = [];
  ctx.addListener("session.opened", (data) => again.push(data.sessionId));
  await waitForSettled();

  assertEquals(first.length, 1);
  assertEquals(again, first);
});
