// The jobs of a plugin: `s.jobs.start`, the signal of a job, its end, and its report.

import type { PluginContext, PluginJob, SessionContext, SessionHandle } from "yuke:plugins";
import { assert, createHost, equal, reply, type TestSession, test } from "yuke:test";

import { waitFor } from "./wait.ts";

/** A host with one plugin, an open session, the context of the plugin in that session, and a handle on the session. */
async function opened(replies: readonly string[] = []) {
  let context: SessionContext | undefined;
  let plugin: PluginContext | undefined;
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
          return undefined;
        },
      },
    ],
    replies: replies.map((text) => reply.text(text)),
  });
  const session = await host.openSession();
  if (context === undefined || plugin === undefined) throw new Error("the plugin did not start");
  const handle: SessionHandle = await plugin.get("sessions").open(session.id, { tail: 0, event() {} });
  return { host, session, s: context, handle };
}

/** Wait until the session `session` has no job left. */
function noJobs(handle: SessionHandle): Promise<void> {
  return waitFor(() => handle.jobs().length === 0);
}

/** The text that the `stop` tool answers for `id`. */
async function stop(session: TestSession, id: string, signal?: AbortSignal): Promise<string> {
  return (await session.call("stop", { id }, signal === undefined ? undefined : { signal })).text;
}

test("a plugin job lists with the jobs of the session, and its report starts a turn", async () => {
  const { host, s, handle } = await opened(["Thanks."]);
  await using _host = host;

  const job = s.jobs.start({ id: "explorer", label: "explore the store" });
  const listed = handle.jobs();
  job.end({ status: "completed", text: "The store has two tables." });
  await waitFor(() => host.requests.length === 1);
  await noJobs(handle);

  equal(listed, [{ id: "explorer", label: "explore the store", state: "running", kind: "plugin", plugin: "agents" }]);
  equal(job.signal.aborted, false);
  equal(
    host.requests[0]?.messages.at(-1)?.text,
    '<system_notification plugin="agents">explorer completed.\nThe store has two tables.</system_notification>',
  );
});

test("an id that still runs throws, and its end frees the id", async () => {
  const { host, s, handle } = await opened();
  await using _host = host;

  const first = s.jobs.start({ id: "explorer", label: "one" });
  let refusal = "";
  try {
    s.jobs.start({ id: "explorer", label: "two" });
  } catch (error) {
    refusal = String(error);
  }
  first.end();
  await noJobs(handle);
  const second = s.jobs.start({ id: "explorer", label: "three" });
  const labels = handle.jobs().map((job) => job.label);
  second.end();
  await noJobs(handle);

  assert(refusal.includes("the job explorer still runs"), refusal);
  equal(labels, ["three"]);
});

test("an end without a report sends no input", async () => {
  const { host, s, handle } = await opened();
  await using _host = host;

  s.jobs.start({ id: "explorer", label: "one" }).end();
  await noJobs(handle);

  equal(host.requests.length, 0);
});

test("the stop tool aborts the signal, waits for the end, and drops the report", async () => {
  const { host, session, s, handle } = await opened();
  await using _host = host;
  const job = s.jobs.start({ id: "explorer", label: "one" });
  let stateAtAbort = "";
  job.signal.addEventListener("abort", () => {
    stateAtAbort = handle.jobs()[0]?.state ?? "gone";
    setTimeout(() => job.end({ status: "cancelled", text: "It stopped." }), 20);
  });

  const answer = await stop(session, "explorer");

  equal(answer, "[explorer stopped.]");
  equal(stateAtAbort, "running");
  equal(job.signal.aborted, true);
  // The stop answered after the end, so the list no longer holds the job.
  equal(handle.jobs(), []);
  // A report would reach the transcript by now.
  await new Promise((resolve) => setTimeout(resolve, 100));
  equal(session.transcript.entries, []);
  equal(host.requests.length, 0);
});

test("a cancel of the stop tool ends its wait, and the stop goes on", async () => {
  const { host, session, s, handle } = await opened();
  await using _host = host;
  const job: PluginJob = s.jobs.start({ id: "explorer", label: "one" });
  const cancel = new AbortController();

  const answer = stop(session, "explorer", cancel.signal);
  await waitFor(() => job.signal.aborted);
  cancel.abort(new Error("cancelled"));
  const failure = await answer.then(
    () => "answered",
    () => "rejected",
  );
  const running = handle.jobs().map((listed) => listed.id);
  job.end();
  await noJobs(handle);

  equal(failure, "rejected");
  equal(running, ["explorer"]);
});

test("the close aborts a job that its plugin does not end, and ends it after the cleanup", async () => {
  const { host, session, s } = await opened();
  await using _host = host;
  const job = s.jobs.start({ id: "explorer", label: "one" });

  await session.close();

  equal(job.signal.aborted, true);
  let refusal = "";
  try {
    s.jobs.start({ id: "late", label: "two" });
  } catch (error) {
    refusal = String(error);
  }
  assert(refusal.includes("after the end of its session"), refusal);
});

test("a job leaves the list at its end, so a later stop finds no job and the report goes out", async () => {
  const { host, session, s, handle } = await opened(["Thanks."]);
  await using _host = host;
  const job = s.jobs.start({ id: "explorer", label: "one" });

  job.end({ status: "completed", text: "Done." });
  const listed = handle.jobs();
  const stopped = await session.call("stop", { id: "explorer" });
  await waitFor(() => host.requests.length === 1);

  equal(listed, []);
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
  const first = await host.openSession();
  const second = await host.openSession();
  const handle = await plugin?.get("sessions").open(second.id, { tail: 0, event() {} });
  const [one, two] = contexts;
  if (one === undefined || two === undefined || handle === undefined) throw new Error("the sessions did not start");
  const stays = two.jobs.start({ id: "explorer", label: "second" });

  one.jobs.start({ id: "explorer", label: "first" }).end();
  await new Promise((resolve) => setTimeout(resolve, 50));
  const listed = handle.jobs().map((job) => job.label);
  stays.end();
  await noJobs(handle);

  equal(listed, ["second"]);
  equal(first.id === second.id, false);
});

test("a job start fails while its session closes", async () => {
  let refusal = "";
  let running: () => void = () => undefined;
  const started = new Promise<void>((resolve) => {
    running = resolve;
  });
  await using host = await createHost({
    plugins: [
      {
        name: "agents",
        session(s) {
          s.tools.define({
            name: "work",
            description: "d",
            concurrency: "serial",
            parameters: { type: "object", properties: {} },
            async execute(_args, context) {
              running();
              await new Promise((resolve) => context.signal.addEventListener("abort", resolve));
              // The close of the session cancels this call before the close of the plugin scope.
              try {
                s.jobs.start({ id: "late", label: "late" });
              } catch (error) {
                refusal = String(error);
              }
              return "done";
            },
          });
          return undefined;
        },
      },
    ],
    replies: [reply.toolCall("work", {})],
  });
  const session = await host.openSession();

  const turn = session.send("Work.").catch(() => undefined);
  await started;
  await session.close();
  await turn;

  assert(refusal.includes("its session is closed"), refusal);
});

test("the signal of a job that ended does not abort at the close of the session", async () => {
  const { host, session, s, handle } = await opened();
  await using _host = host;
  const job = s.jobs.start({ id: "explorer", label: "one" });

  job.end();
  await noJobs(handle);
  await session.close();

  equal(job.signal.aborted, false);
});

test("a second end does nothing", async () => {
  const { host, s, handle } = await opened(["Thanks."]);
  await using _host = host;
  const job = s.jobs.start({ id: "explorer", label: "one" });

  job.end({ status: "completed", text: "One." });
  job.end({ status: "completed", text: "Two." });
  await waitFor(() => host.requests.length === 1);
  await noJobs(handle);

  equal(host.requests.length, 1);
});
