import { assertEquals, createHost, reply, test } from "yuke:test";
import * as approve from "../snippets/engine/approve.ts";
import * as policy from "../snippets/engine/prompt.ts";
import * as events from "../snippets/plugins/events.ts";

test("the documented approval hook denies refusal and cancellation but accepts approval", async () => {
  let choice: string | undefined = "Deny";
  await using host = await createHost({
    plugins: [{ name: "approve", ...approve }],
    onQuestion: () => (choice === undefined ? undefined : [{ id: "exec", values: [choice] }]),
  });
  const session = await host.openSession();
  const call = { callId: "command", name: "exec", arguments: { command: "echo hello" } };
  const denied = await session.runHook("tool.before", { call });
  choice = "Allow";
  const allowed = await session.runHook("tool.before", { call });
  choice = undefined;
  const canceled = await session.runHook("tool.before", { call });
  const read = await session.runHook("tool.before", {
    call: { callId: "read", name: "read", arguments: { path: "README.md" } },
  });
  assertEquals(
    [denied, allowed, canceled, read],
    [{ deny: "The user did not approve exec." }, "run", { deny: "The user did not approve exec." }, "run"],
  );
});

test("the documented prompt hook adds policy without discarding existing sections", async () => {
  await using host = await createHost({ plugins: [{ name: "policy", ...policy }] });
  const session = await host.openSession();
  const prompt = await session.runHook("prompt.build", {
    sections: { base: "Original prompt.", project: "Project rules." },
  });
  assertEquals(prompt.sections, {
    base: "Original prompt.",
    project: "Project rules.",
    review: "Run the relevant tests before you report a code change as complete.",
  });
});

test("the documented state listener reports the running and idle transitions", async () => {
  await using host = await createHost({ plugins: [{ name: "events", ...events }], replies: [reply.text("Done.")] });
  const session = await host.openSession();
  await session.sendMessage("Go.");
  assertEquals(
    host.notices.map((notice) => [notice.source, notice.text]),
    [
      ["events", `${session.id}: running`],
      ["events", `${session.id}: idle`],
    ],
  );
});
