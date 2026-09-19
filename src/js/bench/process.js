import { exec } from "yuke:exec";
import { fs } from "yuke:fs";
import { spawn } from "yuke:spawn";
import { JobOutput } from "yuke:jobs-ui";

let phase = "", scale = 1, received = 0, steps = 0, expected = 0;
/** @type {(() => void) | null} */
let complete = null;
/** @type {JobOutput | null} */
let view = null;
/** @type {import("../app/spawn.js").ChildProcess | null} */
let child = null;
const readFixturePath = "/tmp/yuke-bench-read-fixture";
const readFixtureBytes = 3 * 1024 * 1024;
const chunk = "x".repeat(4095) + "\n";
/** @type {import("yuke:jobs-native").Job} */
const job = { id: 1, state: "running", command: "bench", startedAt: 0, sessionId: null, cwd: "/tmp", log: "", code: null, signal: null, endedAt: null, stopRequested: false };

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
  if (phase === "exec_short" || phase === "exec_bulk") {
    const command = phase === "exec_short" ? "printf ok" : `/usr/bin/head -c ${1048576 * scale} /dev/zero`;
    const result = await exec(command, { maxBytes: 65536 }, "/tmp");
    if (result.code !== 0 || (phase === "exec_bulk" && result.stdoutDropped === 0)) throw Error("exec result");
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
