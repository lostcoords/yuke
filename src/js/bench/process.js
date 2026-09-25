import { exec } from "yuke:internal/native/exec";
import { fs } from "yuke:internal/native/fs";
import { spawn } from "yuke:internal/spawn";
import { JobOutput } from "yuke:internal/jobs-ui";

/** @import { Job } from "yuke:internal/native/jobs" */
/** @import { ChildProcess } from "yuke:internal/spawn" */

let phase = "", scale = 1, received = 0, steps = 0, expected = 0;
/** @type {(() => void) | null} */
let complete = null;
/** @type {JobOutput | null} */
let view = null;
/** @type {ChildProcess | null} */
let child = null;
const readFixturePath = "/tmp/yuke-bench-read-fixture";
const readFixtureBytes = 3 * 1024 * 1024;
const rangeFixturePath = "/tmp/yuke-bench-range-fixture";
const rangeFixtureLine = "const value = compute(input, options);\n";
const chunk = "x".repeat(4095) + "\n";
/** @type {Job} */
const job = { id: 1, state: "running", command: "bench", started_at_ms: 0, cwd: "/tmp", log: "", stop_requested: false };

/** @param {string} name @param {number} count */
async function start(name, count) {
  if (child) { child.closeStdin(); await child.exited; child = null; }
  phase = name; scale = count; steps = 0; received = 0;
  if (phase === "jobs_output") {
    view = new JobOutput(job, () => {});
    view.append("row\n".repeat(5000));
  }
  if (phase === "process_echo") {
    child = spawn(["/bin/cat"], { workspaceRoot: "/tmp" });
    child.onStdout(output);
  }
  if (phase === "fs_read") await fs.writeFile(readFixturePath, "x".repeat(readFixtureBytes));
  if (phase === "fs_range") await fs.writeFile(rangeFixturePath, rangeFixtureLine.repeat(3000));
  await step();
  await step();
  steps = 0;
  return 1;
}

/** @param {string} text */
function output(text) {
  received += text.length;
  if (received >= expected) complete?.();
}

async function step() {
  if (phase === "exec_short" || phase === "exec_bulk" || phase === "exec_stream") {
    const command = phase === "exec_short" ? "printf ok" : `/usr/bin/head -c ${1048576 * scale} /dev/zero`;
    // The stream phase counts the live text, which stops at the 1 MiB cap.
    received = 0;
    const onOutput = phase === "exec_stream" ? (/** @type {string} */ text) => { received += text.length; } : undefined;
    const result = await exec(command, { maxBytes: 65536, onOutput, workspaceRoot: "/tmp" });
    if (result.code !== 0 || (phase !== "exec_short" && result.stdoutDropped === 0)) throw Error("exec result");
    if (phase === "exec_stream" && received !== 1048576) throw Error("exec stream bytes");
  } else if (phase === "fs_range") {
    // The read tool path: the byte cap stops the range, so the answer holds about 64 KiB and a next line.
    const got = await fs.readRange(rangeFixturePath, { start: 1, end: 3000 });
    if (!("text" in got) || got.text.length < 60000 || got.next === null) throw Error("range read");
  } else if (phase === "fs_read") {
    const text = await fs.readFile(readFixturePath);
    if (text.length !== readFixtureBytes) throw Error("file read bytes");
  } else if (phase === "process_echo" || phase === "process_echo_fresh") {
    if (phase === "process_echo_fresh") {
      received = 0;
      child = spawn(["/bin/cat"], { workspaceRoot: "/tmp" });
      child.onStdout(output);
    }
    const current = child;
    if (!current) throw Error("no child");
    expected = received + chunk.length * scale;
    const echoed = new Promise(resolve => { complete = () => resolve(1); });
    for (let i = 0; i < scale; i++) await current.write(chunk);
    await echoed;
    complete = null;
    if (received !== expected) throw Error("echo bytes");
    if (phase === "process_echo_fresh") { current.closeStdin(); await current.exited; child = null; }
  } else if (phase === "jobs_output") {
    if (!view) throw Error("no view");
    for (let i = 0; i < scale; i++) view.append("next row\n");
  } else {
    await new Promise(resolve => {
      let left = 256 * scale;
      for (let i = 0; i < 256 * scale; i++) setTimeout(() => { if (--left === 0) resolve(1); }, 0);
    });
  }
  return ++steps;
}

function verify() {
  if (steps < 1) throw Error("no steps");
  if (phase === "jobs_output" && (!view || view.pager.source.rowCount(100) !== 5000)) throw Error("row count");
  return steps;
}
globalThis.bench = { start, step, verify };
