// The public module `yuke:process`: arguments without a shell, the streams, the environment, the misuse, and the stops.

import * as fs from "yuke:fs";
import { folder } from "yuke:internal/test";
import { Command, env } from "yuke:process";
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

test("env adds variables clear env leaves only env and a null stream is empty", async () => {
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
      dropped.stdout.length,
      dropped.success,
    ],
    [true, true, "YUKE_A=1\n", 0, true],
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

test("spawn pipes stdin to the program and streams its output", async () => {
  const child = new Command("cat", { cwd: folder(), stdin: "piped" }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode("hello "));
  await writer.write(new TextEncoder().encode("world"));
  await writer.close();
  const out = await child.output();
  assertEquals(
    [text(out.stdout), text(out.stderr), out.code, out.success, out.signal],
    ["hello world", "", 0, true, null],
  );
  assert(child.pid > 0, "the child has no process id");
});

test("stdout gives a chunk while the program runs and kill ends the group", async () => {
  const child = new Command("sh", { args: ["-c", "echo first; exec sleep 30"], cwd: folder() }).spawn();
  const reader = child.stdout.getReader();
  assertEquals(text((await reader.read()).value ?? new Uint8Array()), "first\n");
  child.kill();
  assertEquals(await child.status, { success: false, code: 143, signal: "SIGTERM" });
  assertEquals((await reader.read()).done, true);
  assertEquals(
    assertThrows(() => child.kill()),
    new TypeError("Child process has already terminated"),
  );
});

test("kill takes the name of a signal and rejects an unknown name", async () => {
  const child = new Command("sleep", { args: ["30"], cwd: folder() }).spawn();
  assertEquals(
    assertThrows(() => child.kill("SIGNOPE")),
    new TypeError("Unknown signal: SIGNOPE"),
  );
  child.kill("SIGKILL");
  assertEquals(await child.status, { success: false, code: 137, signal: "SIGKILL" });
});

test("an abort stops a spawned group, and a signal that aborted throws before the start", async () => {
  const base = folder();
  const early = new AbortController();
  early.abort(new Error("too early"));
  assertEquals(
    assertThrows(() => new Command("sh", { cwd: base, signal: early.signal }).spawn()),
    new Error("too early"),
  );
  const late = new AbortController();
  const child = new Command("sh", {
    args: ["-c", "sleep 30 & echo $! > child; wait"],
    cwd: base,
    signal: late.signal,
  }).spawn();
  await pidOf(base, "child");
  late.abort();
  assertEquals(await child.status, { success: false, code: 143, signal: "SIGTERM" });
  assert(await gone(base, "child"), "the child of the program still runs");
});

test("a cancel of stdout closes the pipe, so a program that writes ends", async () => {
  const child = new Command("yes", { cwd: folder(), stderr: "null" }).spawn();
  const reader = child.stdout.getReader();
  await reader.read();
  await reader.cancel();
  assertEquals(await child.status, { success: false, code: 141, signal: "SIGPIPE" });
});

test("a stream that is not piped throws and output rejects piped stdin before any start", () => {
  const base = folder();
  const child = new Command("true", { cwd: base, stdout: "null", stderr: "null" }).spawn();
  assertEquals(
    [
      assertThrows(() => child.stdin),
      assertThrows(() => child.stdout),
      assertThrows(() => child.stderr),
      assertThrows(() => new Command("cat", { cwd: base, stdin: "piped" }).output()),
    ],
    [
      new TypeError("Cannot get 'stdin': 'stdin' is not piped"),
      new TypeError("Cannot get 'stdout': 'stdout' is not piped"),
      new TypeError("Cannot get 'stderr': 'stderr' is not piped"),
      new TypeError("Piped stdin is not supported for this function, use 'Command.spawn()' instead"),
    ],
  );
});

test("a spawn of a program that does not start throws with its name", () => {
  assertEquals(
    assertThrows(() => new Command("/no/such/program", { cwd: folder() }).spawn()),
    new Error("/no/such/program did not start: No such file or directory (os error 2)"),
  );
});

test("output of a child rejects a stream that a reader holds", async () => {
  const child = new Command("echo", { args: ["hi"], cwd: folder() }).spawn();
  const reader = child.stdout.getReader();
  assertEquals(await assertRejects(() => child.output()), new TypeError("Cannot collect output: 'stdout' is locked"));
  reader.releaseLock();
  assertEquals(text((await child.output()).stdout), "hi\n");
});
