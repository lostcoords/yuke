// The built-in tool `exec`: its answer, its live output, its caps, and its deadline. Rust tests cover the cancel, the
// background jobs, and the processes.

import { readTextFile } from "yuke:fs";
import type { Sessions } from "yuke:plugins";
import { assert, createHost, equal, folder, settled, type TestSession, test } from "yuke:test";

/** The answer of `exec` for `command`, with the arguments `extra`. */
function exec(session: TestSession, command: string, extra: object = {}) {
  return session.call("exec", { command, ...extra });
}

/** An open session of a host without plugins: the built-in tools only. */
async function opened() {
  const host = await createHost({ plugins: [] });
  return { host, session: await host.openSession() };
}

test("exec answers the output in write order and the exit code", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const result = await exec(session, "printf 'a\\n'; printf 'b\\n' >&2; printf 'c\\n'; pwd; exit 3");

  equal([result.text, result.isError], [`a\nb\nc\n${folder()}\n[exit code: 3]`, true]);
});

test("a command leads its own session without the terminal of yuke", async () => {
  const { host, session } = await opened();
  await using _host = host;

  // The `ps` of Linux and of macOS both mark a session leader with `s` in the process state.
  const result = await exec(session, "ps -o stat= -p $$");

  assert(result.text.split("\n")[0]?.includes("s"), result.text);
});

test("exec names the signal that ended the shell, and says when it has no output", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const killed = await exec(session, "kill -9 $$");
  const quiet = await exec(session, "true");

  equal(
    [killed.text, killed.isError, quiet.text, quiet.isError],
    ["[no output]\n[signal: 9]", true, "[no output]\n[exit code: 0]", false],
  );
});

test("a background exec and its stop show the user a short row and tell the model the log and the next step", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const started = await exec(session, "sleep 30", { background: true });
  const id = started.text.split(" ")[0] as string;
  const lines = started.text.split("\n");
  const stopped = await session.call("stop", { id });

  equal(
    [lines[0], lines[1]?.startsWith("Log: "), lines[1]?.endsWith(`${id}.log`), lines[2]],
    [
      `${id} runs in the background.`,
      true,
      true,
      `Its end arrives as a message, so never sleep or poll. Use stop with ${id} to end it.`,
    ],
  );
  equal(started.display, [{ kind: "markdown", text: `Running in the background as ${id}` }]);
  equal([stopped.text, stopped.display], [`${id} stopped.`, [{ kind: "markdown", text: "Stopped" }]]);
});

test("a moved exec shows the user a short row and tells the model the log and the next step", async () => {
  let sessions: Sessions | undefined;
  const host = await createHost({
    plugins: [
      {
        name: "mover",
        apply(ctx) {
          sessions = ctx.get("sessions");
          return undefined;
        },
      },
    ],
  });
  await using _host = host;
  const session = await host.openSession();
  const handle = await (sessions as Sessions).open(session.id, { tail: 0, onEvent() {} });
  const running = exec(session, "sleep 30");
  while (!handle.canMoveJobsToBackground()) await settled();
  handle.moveJobsToBackground();
  const moved = await running;
  const id = moved.text.split(" as ")[1]?.split(".")[0] as string;
  const lines = moved.text.split("\n");

  equal(
    [lines[0], lines[1]?.startsWith("Log: "), lines[2]],
    [
      `The user moved the command to the background as ${id}.`,
      true,
      `Its end arrives as a message, so never sleep or poll. Use stop with ${id} to end it.`,
    ],
  );
  equal(moved.display, [{ kind: "markdown", text: `Moved to the background as ${id}` }]);
  equal(moved.isError, false);
  await session.call("stop", { id });
});

test("exec gives its output as live texts", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const result = await exec(session, "echo one; echo two");

  equal([result.text, result.output.join("")], ["one\ntwo\n[exit code: 0]", "one\ntwo\n"]);
});

test("exec stops its live output after the cap and answers the end", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const result = await exec(session, "seq 1 300000");

  const live = result.output.join("");
  assert(live.startsWith("1\n2\n3\n"), live.slice(0, 20));
  assert(live.endsWith("\n[yuke stops the live output here. The command runs on.]\n"), live.slice(-80));
  // The cap counts bytes, and each byte of `seq` is one UTF-16 unit.
  assert(live.length >= 1024 * 1024 && live.length < 1024 * 1024 + 70 * 1024, String(live.length));
  assert(result.text.endsWith("299999\n300000\n[exit code: 0]"), result.text.slice(-40));
});

test("exec reports its deadline also when the shell exits 0 at the stop", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const result = await exec(session, "trap 'exit 0' TERM; sleep 30 & wait", { timeout_ms: 200 });

  assert(result.text.startsWith("[no output]\n[timeout: 200 ms."), result.text);
  equal(result.isError, true);
});

test("exec at its deadline stops the process group", async () => {
  const { host, session } = await opened();
  await using _host = host;
  const started = Date.now();

  const result = await exec(session, "echo begun; sleep 30", { timeout_ms: 200 });

  assert(Date.now() - started < 4000, `the call took ${Date.now() - started} ms`);
  assert(result.text.startsWith("begun\n[timeout: 200 ms. yuke stopped the process group."), result.text);
});

// The shell ends at once on SIGTERM, but another process of its group needs time to clean up.
test("each process of a stopped group gets the grace", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const group = `sh -c 'trap "sleep 0.3; echo done > cleaned; exit 0" TERM; while :; do sleep 0.05; done' & wait`;

  await exec(session, group, { timeout_ms: 300 });

  equal(await readTextFile(`${folder()}/cleaned`), "done\n");
});

test("exec ends every process that it starts", async () => {
  const { host, session } = await opened();
  await using _host = host;
  const started = Date.now();

  // The background sleep holds the output pipe. Only its end lets the read finish before the grace.
  const result = await exec(session, "sleep 30 & echo started");

  equal(result.text, "started\n[exit code: 0]");
  assert(Date.now() - started < 1500, `the call took ${Date.now() - started} ms`);
});

test("a character across the end of the head stays whole", async () => {
  const { host, session } = await opened();
  await using _host = host;

  // The head holds 25600 bytes, so the four bytes of the emoji start one byte before its end.
  const result = await exec(session, "head -c 25599 /dev/zero | tr '\\0' a; printf '\\360\\237\\230\\200b'");

  assert(result.text.endsWith("a\u{1f600}b\n[exit code: 0]"), result.text.slice(-30));
  assert(!result.text.includes("�"), "the head cut a character");
});

test("exec output over the cap keeps a head, a tail, and the full file", async () => {
  const { host, session } = await opened();
  await using _host = host;

  const result = await exec(session, "seq 1 30000");

  assert(result.text.startsWith("1\n2\n3\n"), result.text.slice(0, 20));
  assert(result.text.endsWith("29999\n30000\n[exit code: 0]"), result.text.slice(-40));
  assert(result.text.length < 52 * 1024, String(result.text.length));
  const marker = result.text.split("\n").find((line) => line.startsWith("[yuke cut "));
  const path = marker?.split("Full output: ")[1]?.split(". Read it")[0] ?? "";
  const expected = Array.from({ length: 30_000 }, (_item, index) => `${index + 1}\n`).join("");
  equal(await readTextFile(path), expected);
});
