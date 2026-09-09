import { exec } from "yuke:exec";
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
    [["echo x", {}, 42], "the workspace root must be a string"],
    [["echo x", { cwd: 42 }], "cwd must be a string"],
    [["echo x", { cwd: ".", timeoutMs: 0 }], "timeoutMs must be a whole number of milliseconds up to 600000"],
  ]) {
    message = "";
    try { await exec(...args); } catch (e) { message = e.message; }
    check("argument-rejects:" + expected, message === expected);
  }
  globalThis.result = fail.length ? fail.join(",") : "ok";
})();
