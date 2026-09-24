import { exec } from "yuke:exec";
import { create, cancel } from "yuke:cancellation-native";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
globalThis.result = "pending";
(async () => {
  const ok = await exec("echo hello");
  check("stdout", ok.stdout === "hello\n");
  check("code", ok.code === 0);
  check("signal", ok.signal === null);
  check("timed-out", ok.timedOut === false);
  check("dropped", ok.stdoutDropped === 0 && ok.stderrDropped === 0);
  const bad = await exec("echo oops 1>&2; exit 3");
  check("stderr", bad.stderr === "oops\n");
  check("exit-code", bad.code === 3);
  // A stream above the host cap fills the pipe, so this proves the reactor drains a blocking pipe end to end.
  const big = await exec("yes abcdefgh | head -c 200000");
  check("big-completes", big.code === 0 && big.stdoutDropped > 0 && big.stdout.startsWith("abcdefgh"));
  check("no-log-by-default", big.log === null && ok.log === null);
  const capped = await exec("head -c 100 /dev/zero | tr '\\0' x", { maxBytes: 10 });
  check("max-bytes", capped.stdoutDropped === 90);
  // Live text reaches onOutput before the result settles.
  const live = [];
  let settled = false;
  const streamed = exec("printf live", {
    onOutput: (text) => live.push({ text, settled }),
  });
  const done = await streamed;
  settled = true;
  check("live-before-result", live.every((chunk) => !chunk.settled));
  check("live-text", live.map((chunk) => chunk.text).join("") === "live");
  check("live-result", done.stdout === "live" && done.stderr === "");
  // The live text is not bound by the result cap.
  let bytes = 0;
  const wide = await exec("yes abcdefgh | head -c 200000", { maxBytes: 10, onOutput: (text) => { bytes += text.length; } });
  check("live-uncapped", bytes === 200000 && wide.stdoutDropped === 199990);
  // The live text stops at the engine stream cap, and the command still runs to its end.
  bytes = 0;
  const huge = await exec("head -c 3000000 /dev/zero | tr '\\0' x", { onOutput: (text) => { bytes += text.length; } });
  check("live-cap", bytes === 1048576 && huge.code === 0);
  // A cancel still delivers what the command printed first, and the promise rejects.
  const signal = create();
  const early = [];
  let canceled = "";
  await exec("printf start; sleep 30", { signal, onOutput: (text) => { early.push(text); cancel(signal); } }).catch((e) => { canceled = e.message; });
  check("cancel-output", early.join("") === "start" && canceled === "the command was canceled");
  // A command with no cwd runs in the directory the host runs in.
  check("cwd", (await exec("cat marker.txt")).stdout === "found\n");
  // A refused argument rejects; it never throws at the caller.
  let message = "";
  try { await exec("   "); } catch (e) { message = e.message; }
  check("blank-rejects", message === "the command must not be blank");
  try { await exec("echo x", { timeoutMs: 0 }); } catch (e) { message = e.message; }
  check("timeout-range-rejects", message.startsWith("timeoutMs must be"));
  // A number reaches the host as a double, so a fraction must fail rather than truncate.
  message = "";
  try { await exec("echo x", { timeoutMs: 1.5 }); } catch (e) { message = e.message; }
  check("timeout-fraction-rejects", message.startsWith("timeoutMs must be"));
  for (const [args, expected] of [
    [[42], "the command must be a string"],
    [["echo x", { workspaceRoot: 42 }], "the workspace root must be an absolute path"],
    [["echo ok\0; echo cut"], "the command must not hold a NUL byte"],
    [["echo x", { workspaceRoot: "relative" }], "the workspace root must be an absolute path"],
    [["echo x", { cwd: 42 }], "cwd must be a string"],
    [["echo x", { cwd: ".", timeoutMs: 0 }], "timeoutMs must be a whole number of milliseconds up to 600000"],
    [["echo x", { maxBytes: 65537 }], "maxBytes must be a whole number of bytes up to 65536"],
    [["echo x", { log: "yes" }], "log must be a boolean"],
    [["echo x", { onOutput: "yes" }], "onOutput must be a function"],
  ]) {
    message = "";
    try { await exec(...args); } catch (e) { message = e.message; }
    check("argument-rejects:" + expected, message === expected);
  }
  globalThis.result = fail.length ? fail.join(",") : "ok";
})();
