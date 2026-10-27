// The public module `yuke:process`: arguments without a shell, the streams, the environment, the misuse, and the stops.

import * as fs from "yuke:fs";
import { folder } from "yuke:internal/test";
import { Command } from "yuke:process";
import { assert, equal, rejects, test, throws } from "yuke:test";

/** Make the empty folder `name` in the scratch folder of the file, and give its absolute path. */
async function place(name: string): Promise<string> {
  const path = `${folder()}/${name}`;
  await fs.mkdir(path);
  return path;
}

/** `bytes` as UTF-8 text. */
function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

/** Wait until the process that `file` in `cwd` names is gone, as `kill -0` tells it, for at most three seconds. */
async function gone(cwd: string, file: string): Promise<boolean> {
  const pid = (await fs.readTextFile(file, { baseDir: cwd })).trim();
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
  const base = await place("arguments");
  const out = await new Command("sh", {
    args: ["-c", 'printf "%s|" "$1" "$2"; echo err >&2; exit 3', "sh", "a b", "$HOME"],
    cwd: base,
  }).output();
  equal(
    [text(out.stdout), text(out.stderr), out.code, out.success, out.signal],
    ["a b|$HOME|", "err\n", 3, false, null],
  );
});

test("env adds variables clear env leaves only env and a null stream is empty", async () => {
  const base = await place("environment");
  const added = await new Command("/usr/bin/env", { cwd: base, env: { YUKE_A: "1" } }).output();
  const only = await new Command("/usr/bin/env", { cwd: base, env: { YUKE_A: "1" }, clearEnv: true }).output();
  const dropped = await new Command("/usr/bin/env", { cwd: base, stdout: "null" }).output();
  const lines = text(added.stdout).split("\n");
  equal(
    [
      lines.includes("YUKE_A=1"),
      lines.some((line) => line.startsWith("PATH=")),
      text(only.stdout),
      dropped.stdout.length,
      dropped.success,
    ],
    [true, true, "YUKE_A=1\n", 0, true],
  );
});

test("a misuse throws a type error before any start", async () => {
  const base = await place("misuse");
  equal(
    [
      // @ts-expect-error: the options are missing.
      throws(() => new Command("ls")),
      throws(() => new Command("ls", { cwd: "relative" })),
      // @ts-expect-error: stdout does not inherit.
      throws(() => new Command("ls", { cwd: base, stdout: "inherit" })),
      // @ts-expect-error: stdin has no pipe.
      throws(() => new Command("ls", { cwd: base, stdin: "piped" })),
      // @ts-expect-error: a command has no shell.
      throws(() => new Command("ls", { cwd: base, shell: true })),
      // @ts-expect-error: an argument is a number.
      throws(() => new Command("ls", { cwd: base, args: [1] })),
      // @ts-expect-error: a variable is a number.
      throws(() => new Command("ls", { cwd: base, env: { A: 1 } })),
    ],
    [
      new TypeError("the options is not an object"),
      new TypeError("the option cwd is not an absolute path"),
      new TypeError('the option stdout is not "piped" or "null"'),
      new TypeError('the option stdin is not "null"'),
      new TypeError("the options has the unknown field 'shell'"),
      new TypeError("the option args is not an array of strings"),
      new TypeError("the option env has a value that is not a string"),
    ],
  );
});

test("an abort before the start rejects and an abort during the run stops the group", async () => {
  const base = await place("abort_run");
  const early = new AbortController();
  early.abort(new Error("too early"));
  equal(await rejects(new Command("sh", { cwd: base, signal: early.signal }).output()), new Error("too early"));
  const late = new AbortController();
  // The background child writes its id, so the test sees that the stop reached the whole group.
  const running = new Command("sh", {
    args: ["-c", "sleep 30 & echo $! > child; wait"],
    cwd: base,
    signal: late.signal,
  }).output();
  setTimeout(() => late.abort(), 300);
  const out = await running;
  equal([out.success, out.code, out.signal], [false, 143, "SIGTERM"]);
  assert(await gone(base, "child"), "the child of the program still runs");
});

test("an abort after the exit stops a left process that holds the output", async () => {
  const base = await place("abort_after_exit");
  const controller = new AbortController();
  // The shell exits at once, and its background child keeps stdout open.
  const running = new Command("sh", {
    args: ["-c", "sleep 30 & echo $! > child; echo done"],
    cwd: base,
    signal: controller.signal,
  }).output();
  setTimeout(() => controller.abort(), 300);
  const out = await running;
  equal([text(out.stdout), out.code, out.signal], ["done\n", 0, null]);
  assert(await gone(base, "child"), "the left process still runs");
});

test("a program that does not start rejects with its name", async () => {
  const base = await place("no_start");
  equal(
    await rejects(new Command("/no/such/program", { cwd: base }).output()),
    new Error("/no/such/program did not start: No such file or directory (os error 2)"),
  );
});
