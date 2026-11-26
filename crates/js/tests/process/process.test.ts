// The public module `yuke:process`: arguments without a shell, the streams, the environment, the misuse, the stops, and
// the spawned programs.

import * as fs from "yuke:fs";
import { folder } from "yuke:internal/test";
import { Command, env, type Signal } from "yuke:process";
import { assert, assertEquals, assertRejects, assertThrows, test } from "yuke:test";

/** `bytes` as UTF-8 text. */
function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

/** The process id in `file` in `cwd`, after the program writes its line. */
async function pidOf(cwd: string, file: string): Promise<string> {
  for (;;) {
    const line = await fs.readTextFile(file, { folder: cwd }).catch(() => "");
    if (line.endsWith("\n")) return line.trim();
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** Wait until the process that `file` in `cwd` names is gone, as `kill -0` tells it. After the file holds the id, the wait
 * stops after four seconds. */
async function gone(cwd: string, file: string): Promise<boolean> {
  const pid = await pidOf(cwd, file);
  // The test has 5 seconds in all, so the wait stops before that limit.
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline) {
    const probe = await new Command("sh", { args: ["-c", 'kill -0 "$1"', "sh", pid], cwd, stderr: "null" }).output();
    if (!probe.success) return true;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return false;
}

test("each argument reaches the program as it is and the streams stay apart", async () => {
  const base = folder();
  const out = await new Command("sh", {
    args: ["-c", 'printf "%s|" "$1" "$2"; echo err >&2; exit 3', "sh", "a b", "$HOME"],
    cwd: base,
  }).output();
  assertEquals(
    [text(out.stdout), text(out.stderr), out.code, out.success, out.signal],
    ["a b|$HOME|", "err\n", 3, false, null],
  );
});

test("env adds variables clear env leaves only env and a null stream throws from its getter", async () => {
  const base = folder();
  const added = await new Command("/usr/bin/env", { cwd: base, env: { YUKE_A: "1" } }).output();
  const only = await new Command("/usr/bin/env", { cwd: base, env: { YUKE_A: "1" }, clearEnv: true }).output();
  const dropped = await new Command("/usr/bin/env", { cwd: base, stdout: "null" }).output();
  const lines = text(added.stdout).split("\n");
  assertEquals(
    [
      lines.includes("YUKE_A=1"),
      lines.some((line) => line.startsWith("PATH=")),
      text(only.stdout),
      assertThrows(() => dropped.stdout),
      dropped.success,
    ],
    [true, true, "YUKE_A=1\n", new TypeError("Cannot get 'stdout': 'stdout' is not piped"), true],
  );
});

test("a relative cwd throws a type error before any start", () => {
  assertEquals(
    assertThrows(() => new Command("ls", { cwd: "relative" })),
    new TypeError("the option cwd is not an absolute path"),
  );
});

test("an abort before the start rejects and an abort during the run stops the group", async () => {
  const base = folder();
  const early = new AbortController();
  early.abort(new Error("too early"));
  assertEquals(
    await assertRejects(() => new Command("sh", { cwd: base, signal: early.signal }).output()),
    new Error("too early"),
  );
  const late = new AbortController();
  // The background child writes its id, so the test sees that the stop reached the whole group.
  const running = new Command("sh", {
    args: ["-c", "sleep 30 & echo $! > child; wait"],
    cwd: base,
    signal: late.signal,
  }).output();
  await pidOf(base, "child");
  late.abort();
  const out = await running;
  assertEquals([out.success, out.code, out.signal], [false, 143, "SIGTERM"]);
  assert(await gone(base, "child"), "the child of the program still runs");
});

test("an abort after the exit stops a left process that holds the output", async () => {
  const base = folder();
  const controller = new AbortController();
  // The shell exits at once, and its background child keeps stdout open.
  const running = new Command("sh", {
    args: ["-c", "echo $$ > shell; sleep 30 & echo $! > child; echo done"],
    cwd: base,
    signal: controller.signal,
  }).output();
  assert(await gone(base, "shell"), "the shell still runs");
  controller.abort();
  const out = await running;
  assertEquals([text(out.stdout), out.code, out.signal], ["done\n", 0, null]);
  assert(await gone(base, "child"), "the left process still runs");
});

test("a program that does not start rejects with its name", async () => {
  const base = folder();
  assertEquals(
    await assertRejects(() => new Command("/no/such/program", { cwd: base }).output()),
    new Error("/no/such/program did not start: No such file or directory (os error 2)"),
  );
});

test("env.get gives a variable of the environment of yuke, and undefined for a missing one", async () => {
  const cwd = folder();
  // A program gets the environment of yuke, and env prints it as it gets it.
  const shown = await new Command("/usr/bin/env", { cwd }).output();
  const path = text(shown.stdout)
    .split("\n")
    .find((line) => line.startsWith("PATH="))
    ?.slice("PATH=".length);
  assertEquals([env.get("PATH"), env.get("YUKE_TEST_NO_SUCH_VARIABLE"), env.get("")], [path, undefined, undefined]);
});

test("spawn gives a chunk of stdout while the program runs and kill ends it", async () => {
  const base = folder();
  const child = new Command("sh", { args: ["-c", "echo first; exec sleep 30"], cwd: base }).spawn();
  const reader = child.stdout.getReader();
  const first = await reader.read();
  child.kill();
  const rest = await reader.read();
  const status = await child.status;
  assertEquals(
    [text(first.value ?? new Uint8Array()), rest.done, status.success, status.code, status.signal],
    ["first\n", true, false, 143, "SIGTERM"],
  );
});

test("kill throws a type error for an unknown signal and after the exit", async () => {
  const base = folder();
  const child = new Command("sh", { args: ["-c", "exit 0"], cwd: base }).spawn();
  // A plugin in JavaScript has no type check, so the name reaches yuke.
  const unknown = assertThrows(() => child.kill("SIGNOPE" as Signal));
  await child.status;
  assertEquals(
    [unknown, assertThrows(() => child.kill())],
    [new TypeError("Invalid signal: SIGNOPE"), new TypeError("Child process has already terminated")],
  );
});

test("a cancel of stdout closes the pipe so the program ends with SIGPIPE", async () => {
  const base = folder();
  const child = new Command("yes", { cwd: base }).spawn();
  const reader = child.stdout.getReader();
  await reader.read();
  await reader.cancel();
  const status = await child.status;
  assertEquals([status.code, status.signal], [141, "SIGPIPE"]);
});

test("an abort stops a spawned group", async () => {
  const base = folder();
  const controller = new AbortController();
  const child = new Command("sh", {
    args: ["-c", "sleep 30 & echo $! > child; wait"],
    cwd: base,
    signal: controller.signal,
  }).spawn();
  await pidOf(base, "child");
  controller.abort();
  const out = await child.output();
  assertEquals([out.code, out.signal], [143, "SIGTERM"]);
  assert(await gone(base, "child"), "the child of the program still runs");
});

test("a stream that is not piped throws from the getters of the child and of its output", async () => {
  const base = folder();
  const child = new Command("sh", { args: ["-c", "echo out; echo err >&2"], cwd: base, stdout: "null" }).spawn();
  const output = await child.output();
  const notPiped = new TypeError("Cannot get 'stdout': 'stdout' is not piped");
  assertEquals(
    [assertThrows(() => child.stdout), assertThrows(() => output.stdout), text(output.stderr)],
    [notPiped, notPiped, "err\n"],
  );
});

test("output of a spawn with a locked stream rejects", async () => {
  const base = folder();
  const child = new Command("sh", { args: ["-c", "echo out"], cwd: base }).spawn();
  child.stdout.getReader();
  assertEquals(await assertRejects(() => child.output()), new TypeError("Cannot collect output: 'stdout' is locked"));
  await child.status;
});

test("a spawn of a missing program throws with its name", () => {
  const base = folder();
  assertEquals(
    assertThrows(() => new Command("/no/such/program", { cwd: base }).spawn()),
    new Error("/no/such/program did not start: No such file or directory (os error 2)"),
  );
});

test("await using stops a running program", async () => {
  const base = folder();
  let status: Promise<{ readonly code: number }>;
  {
    await using child = new Command("sh", { args: ["-c", "echo $$ > shell; exec sleep 30"], cwd: base }).spawn();
    status = child.status;
    await pidOf(base, "shell");
  }
  assertEquals((await status).code, 143);
});

test("a spawn under an aborted signal throws its reason and starts nothing", async () => {
  const base = folder();
  const controller = new AbortController();
  controller.abort(new Error("too early"));
  const thrown = assertThrows(() =>
    new Command("sh", { args: ["-c", "echo ran > ran"], cwd: base, signal: controller.signal }).spawn(),
  );
  // A started shell writes the file in a few milliseconds.
  await new Promise((resolve) => setTimeout(resolve, 100));
  const ran = await fs.stat("ran", { folder: base }).then(
    () => true,
    () => false,
  );
  assertEquals([thrown, ran], [new Error("too early"), false]);
});

test("stderr of a spawned program is a stream apart from stdout", async () => {
  const base = folder();
  const child = new Command("sh", { args: ["-c", "echo out; echo err >&2"], cwd: base, stdout: "null" }).spawn();
  const chunks: string[] = [];
  for await (const chunk of child.stderr) chunks.push(text(chunk));
  assertEquals([chunks.join(""), (await child.status).success], ["err\n", true]);
});
