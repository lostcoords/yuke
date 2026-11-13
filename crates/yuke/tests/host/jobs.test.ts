// The jobs of a plugin: `s.jobs.start`, `context.jobs.run`, the signal of the work, its end, and its report.

import type { JobReport, JobWork, PluginContext, SessionContext, SessionHandle } from "yuke:plugins";
import { assert, assertEquals, createHost, reply, type TestSession, test, waitForSettled } from "yuke:test";

/** Work that ends when a test says so. */
function held() {
  const end = Promise.withResolvers<JobReport | undefined>();
  let seen: AbortSignal | undefined;
  const work: JobWork = (signal) => {
    seen = signal;
    return end.promise;
  };
  return {
    work,
    finish: end.resolve,
    fail: end.reject,
    get signal(): AbortSignal {
      if (seen === undefined) throw new Error("the work did not start");
      return seen;
    },
  };
}

const REPORT: JobReport = { status: "completed", text: "The store has two tables." };
const SENT =
  '<system_notification plugin="agents">explorer one: completed.\nThe store has two tables.</system_notification>';

/** A host with one plugin, an open session, and a handle on it. The tool `work` runs `tools.work` in a job of its call. */
async function opened(replies: readonly string[] = []) {
  let context: SessionContext | undefined;
  let plugin: PluginContext | undefined;
  const tool: { work: JobWork; background: boolean } = { work: () => undefined, background: false };
  const host = await createHost({
    plugins: [
      {
        name: "agents",
        apply(ctx) {
          plugin = ctx;
          return undefined;
        },
        session(s) {
          context = s;
          s.tools.add({
            name: "work",
            description: "d",
            concurrency: "parallel",
            parameters: { type: "object", properties: {} },
            async execute(_args, call) {
              const job = { id: "explorer", label: "one", background: tool.background };
              const outcome = await call.jobs.run(job, tool.work);
              return outcome.kind === "background" ? `${outcome.id} moved.` : (outcome.report?.text ?? "no report");
            },
          });
          return undefined;
        },
      },
    ],
    replies: replies.map((text) => reply.text(text)),
  });
  const session = await host.openSession();
  if (context === undefined || plugin === undefined) throw new Error("the plugin did not start");
  const handle: SessionHandle = await plugin.get("sessions").open(session.id, { tail: 0, onEvent() {} });
  return { host, session, s: context, handle, tool };
}

/** The text that the `stop` tool answers for `id`. */
async function stop(session: TestSession, id: string, signal?: AbortSignal): Promise<string> {
  return (await session.call("stop", { id }, signal === undefined ? undefined : { signal })).text;
}

test("a job lists with the jobs of the session, and its report starts a turn", async () => {
  const { host, s, handle } = await opened(["Thanks."]);
  await using _host = host;
  const work = held();

  await s.jobs.start({ id: "explorer", label: "one" }, work.work);
  const listed = handle.jobs();
  work.finish(REPORT);
  await waitForSettled();

  assertEquals(listed, [{ id: "explorer", label: "one", state: "running", kind: "plugin", plugin: "agents" }]);
  assertEquals(handle.jobs(), []);
  assertEquals(work.signal.aborted, false);
  assertEquals(host.requests[0]?.messages.at(-1)?.text, SENT);
});

test("an id that still runs rejects, and the end of its work frees the id", async () => {
  const { host, s, handle } = await opened();
  await using _host = host;
  const first = held();
  const second = held();

  await s.jobs.start({ id: "explorer", label: "one" }, first.work);
  const refusal = await s.jobs.start({ id: "explorer", label: "two" }, () => undefined).catch(String);
  first.finish(undefined);
  await waitForSettled();
  await s.jobs.start({ id: "explorer", label: "three" }, second.work);
  const labels = handle.jobs().map((job) => job.label);
  second.finish(undefined);
  await waitForSettled();

  assert(String(refusal).includes("the job explorer still runs"), String(refusal));
  assertEquals(labels, ["three"]);
});

test("the stop tool aborts the signal, waits for the end, and drops the report", async () => {
  const { host, session, s, handle } = await opened();
  await using _host = host;
  const work = held();
  await s.jobs.start({ id: "explorer", label: "one" }, work.work);

  let answered = false;
  const pending = stop(session, "explorer").then((answer) => {
    answered = true;
    return answer;
  });
  await waitForSettled();
  assertEquals([work.signal.aborted, answered], [true, false]);
  work.finish(REPORT);

  assertEquals(await pending, "explorer stopped.");
  // The stop answered after the end, so the list no longer holds the job.
  assertEquals(handle.jobs(), []);
  await waitForSettled();
  assertEquals(session.transcript.entries, []);
  assertEquals(host.requests.length, 0);
});

test("a cancel of the stop tool ends its wait, and the stop goes on", async () => {
  const { host, session, s, handle } = await opened();
  await using _host = host;
  const work = held();
  await s.jobs.start({ id: "explorer", label: "one" }, work.work);
  const cancel = new AbortController();

  const answer = stop(session, "explorer", cancel.signal);
  await waitForSettled();
  assertEquals(work.signal.aborted, true);
  cancel.abort(new Error("cancelled"));
  const failure = await answer.then(
    () => "answered",
    () => "rejected",
  );
  const running = handle.jobs().map((listed) => listed.id);
  work.finish(undefined);
  await waitForSettled();

  assertEquals(failure, "rejected");
  assertEquals(running, ["explorer"]);
});

test("the close aborts the work, waits for its end, and refuses a later job", async () => {
  const { host, session, s } = await opened();
  await using _host = host;
  const work = held();
  await s.jobs.start({ id: "explorer", label: "one" }, work.work);

  let closed = false;
  const closing = session.close().then(() => {
    closed = true;
  });
  await waitForSettled();
  const whileWorking = closed;
  work.finish(undefined);
  await closing;
  const refusal = await s.jobs.start({ id: "late", label: "two" }, () => undefined).catch(String);

  assertEquals(work.signal.aborted, true);
  assertEquals(whileWorking, false);
  assert(String(refusal).includes("after the end of its session"), String(refusal));
});

test("after its end a job is gone, so a stop finds no job and the report goes out", async () => {
  const { host, session, s, handle } = await opened(["Thanks."]);
  await using _host = host;

  await s.jobs.start({ id: "explorer", label: "one" }, () => REPORT);
  await waitForSettled();
  const stopped = await session.call("stop", { id: "explorer" });

  assertEquals(handle.jobs(), []);
  assertEquals(host.requests.length, 1);
  assert(stopped.text.includes("The id explorer does not exist."), stopped.text);
});

test("two sessions can run one id, and the end of one job leaves the other", async () => {
  const contexts: SessionContext[] = [];
  let plugin: PluginContext | undefined;
  await using host = await createHost({
    plugins: [
      {
        name: "agents",
        apply(ctx) {
          plugin = ctx;
          return undefined;
        },
        session(s) {
          contexts.push(s);
          return undefined;
        },
      },
    ],
  });
  await host.openSession();
  const second = await host.openSession();
  const handle = await plugin?.get("sessions").open(second.id, { tail: 0, onEvent() {} });
  const [one, two] = contexts;
  if (one === undefined || two === undefined || handle === undefined) throw new Error("the sessions did not start");
  const stays = held();
  await two.jobs.start({ id: "explorer", label: "second" }, stays.work);

  await one.jobs.start({ id: "explorer", label: "first" }, () => undefined);
  await waitForSettled();
  const listed = handle.jobs().map((job) => job.label);
  stays.finish(undefined);
  await waitForSettled();

  assertEquals(listed, ["second"]);
});

test("a job start rejects while its session closes", async () => {
  let refusal = "";
  await using host = await createHost({
    plugins: [
      {
        name: "agents",
        session(s) {
          s.tools.add({
            name: "wait",
            description: "d",
            concurrency: "serial",
            parameters: { type: "object", properties: {} },
            async execute(_args, context) {
              await new Promise((resolve) => context.signal.addEventListener("abort", resolve));
              // The close of the session cancels this call before the close of the plugin scope.
              await s.jobs
                .start({ id: "late", label: "late" }, () => undefined)
                .catch((error) => {
                  refusal = String(error);
                });
              return "done";
            },
          });
          return undefined;
        },
      },
    ],
    replies: [reply.toolCall("wait", {})],
  });
  const session = await host.openSession();

  const turn = session.sendMessage("Work.").catch(() => undefined);
  await waitForSettled();
  assertEquals(session.transcript.state, "running");
  await session.close();
  await turn;

  assert(refusal.includes("its session is closed"), refusal);
});

test("a label of many lines shows its first line in the list and in the report", async () => {
  const { host, s, handle } = await opened(["Thanks."]);
  await using _host = host;
  const work = held();

  await s.jobs.start({ id: "explorer", label: "one\ntwo" }, work.work);
  const listed = handle.jobs().map((job) => job.label);
  work.finish(REPORT);
  await waitForSettled();

  assertEquals(listed, ["one..."]);
  assertEquals(host.requests[0]?.messages.at(-1)?.text, SENT.replace("one:", "one...:"));
});

test("work without a report sends no input, and its signal stays quiet at the close of the session", async () => {
  const { host, session, s } = await opened();
  await using _host = host;
  const work = held();
  await s.jobs.start({ id: "explorer", label: "one" }, work.work);

  work.finish(undefined);
  await waitForSettled();
  const requests = host.requests.length;
  await session.close();

  assertEquals(work.signal.aborted, false);
  assertEquals(requests, 0);
});

test("work that throws without a call reports the failure", async () => {
  const { host, s, handle } = await opened(["Thanks."]);
  await using _host = host;

  await s.jobs.start({ id: "explorer", label: "one" }, () => {
    throw new Error("the store is gone");
  });
  await waitForSettled();

  assertEquals(handle.jobs(), []);
  assert(host.requests[0]?.messages.at(-1)?.text.includes("explorer one: failed.") === true, "no report");
  assert(host.requests[0]?.messages.at(-1)?.text.includes("the store is gone") === true, "no failure text");
});

test("a job in a call stays hidden, and its report answers the call and not the session", async () => {
  const { host, session, handle, tool } = await opened();
  await using _host = host;
  const work = held();
  tool.work = work.work;

  const call = session.call("work", {});
  await waitForSettled();
  const listed = handle.jobs();
  const movable = handle.canMoveJobsToBackground();
  work.finish(REPORT);
  const result = await call;
  await waitForSettled();

  assertEquals([listed, movable], [[], true]);
  assertEquals(result.text, REPORT.text);
  assertEquals(handle.canMoveJobsToBackground(), false);
  assertEquals(host.requests.length, 0);
});

test("a throw of the work rejects the call that waits and frees the id", async () => {
  const { host, session, s, tool } = await opened();
  await using _host = host;
  tool.work = () => {
    throw new Error("the store is gone");
  };

  const result = await session.call("work", {});
  await waitForSettled();
  await s.jobs.start({ id: "explorer", label: "again" }, () => undefined);

  assertEquals([result.isError, result.text], [true, "the store is gone"]);
  assertEquals(host.requests.length, 0);
});

test("a cancel of the call aborts the signal of its job", async () => {
  const { host, session, tool } = await opened();
  await using _host = host;
  const work = held();
  tool.work = work.work;
  const cancel = new AbortController();

  const call = session.call("work", {}, { signal: cancel.signal }).catch(() => undefined);
  await waitForSettled();
  cancel.abort(new Error("cancelled"));
  await waitForSettled();
  const aborted = work.signal.aborted;
  work.finish(undefined);
  await call;

  assertEquals(aborted, true);
});

test("a move answers the call, keeps the signal quiet at its end, and the report goes to the session", async () => {
  const { host, session, handle, tool } = await opened(["Thanks."]);
  await using _host = host;
  const work = held();
  tool.work = work.work;
  const call = session.call("work", {});
  await waitForSettled();

  handle.moveJobsToBackground();
  const result = await call;
  await waitForSettled();
  const listed = handle.jobs().map((job) => job.id);
  const aborted = work.signal.aborted;
  const movable = handle.canMoveJobsToBackground();
  work.finish(REPORT);
  await waitForSettled();

  assertEquals(result.text, "explorer moved.");
  assertEquals([listed, aborted, movable], [["explorer"], false, false]);
  assertEquals(handle.jobs(), []);
  assertEquals(host.requests[0]?.messages.at(-1)?.text, SENT);
});

test("a throw of the work after a move reports the failure", async () => {
  const { host, session, handle, tool } = await opened(["Thanks."]);
  await using _host = host;
  const work = held();
  tool.work = work.work;
  const call = session.call("work", {});
  await waitForSettled();

  handle.moveJobsToBackground();
  await call;
  work.fail(new Error("the store is gone"));
  await waitForSettled();

  assert(host.requests[0]?.messages.at(-1)?.text.includes("explorer one: failed.") === true, "no report");
});

test("a stop after a move aborts the signal and drops the report", async () => {
  const { host, session, handle, tool } = await opened();
  await using _host = host;
  const work = held();
  tool.work = work.work;
  const call = session.call("work", {});
  await waitForSettled();
  handle.moveJobsToBackground();
  await call;

  const pending = stop(session, "explorer");
  await waitForSettled();
  const aborted = work.signal.aborted;
  work.finish(REPORT);

  assertEquals(await pending, "explorer stopped.");
  assertEquals(aborted, true);
  await waitForSettled();
  assertEquals(host.requests.length, 0);
});

test("a hidden job holds its id", async () => {
  const { host, session, s, tool } = await opened();
  await using _host = host;
  const work = held();
  tool.work = work.work;
  const call = session.call("work", {});
  await waitForSettled();

  const refusal = await s.jobs.start({ id: "explorer", label: "two" }, () => undefined).catch(String);
  work.finish(undefined);
  await call;

  assert(String(refusal).includes("the job explorer still runs"), String(refusal));
});

test("the option background runs the work without the call", async () => {
  const { host, session, handle, tool } = await opened(["Thanks."]);
  await using _host = host;
  const work = held();
  tool.work = work.work;
  tool.background = true;

  const result = await session.call("work", {});
  await waitForSettled();
  const listed = handle.jobs().map((job) => job.id);
  work.finish(REPORT);
  await waitForSettled();

  assertEquals(result.text, "explorer moved.");
  assertEquals(listed, ["explorer"]);
  assertEquals(host.requests[0]?.messages.at(-1)?.text, SENT);
});
