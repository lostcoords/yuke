// Background jobs over the native table: every start, stop request, and end emits `job.changed` with a fresh copy of the job.

import * as native from "yuke:internal/native/jobs";
import { events } from "yuke:internal/kernel";

/** @import { Job } from "yuke:internal/native/jobs" */

export const { list, get, read } = native;

/** @param {string} command @param {string} sessionId @param {{ workspaceRoot?: string }} [options] @returns {Promise<Job>} */
export async function start(command, sessionId, options = {}) {
  const { job, ended } = await native.start(command, sessionId, options);
  events.emit("job.changed", job);
  ended.then((done) => events.emit("job.changed", done));
  return job;
}

/** Ask a running job to stop. It answers the job as it is now, or null for an unknown id; `wait` answers the end. @param {number} id @returns {Promise<Job | null>} */
export async function stop(id) {
  const before = native.get(id);
  const job = native.stop(id);
  if (job?.stop_requested && !before?.stop_requested) events.emit("job.changed", job);
  return job;
}

/** Wait until the job ends, and answer the final job. A job that is not running answers at once, and an unknown id answers null. @param {number} id @returns {Promise<Job | null>} */
export function wait(id) {
  const job = native.get(id);
  if (job === null || job.state !== "running") return Promise.resolve(job);
  return new Promise((resolve) => {
    const off = events.on("job.changed", (/** @type {Job} */ changed) => {
      if (changed.id !== id || changed.state === "running") return;
      off();
      resolve(native.get(id));
    });
  });
}

// One line of at most 60 characters, so a multi-line command never breaks a row or a title.
/** @param {string} command @returns {string} */
export function shortCommand(command) {
  const text = command.trim();
  const end = text.indexOf("\n");
  const line = end < 0 ? text : text.slice(0, end);
  return line.length > 60 || end >= 0 ? `${line.slice(0, 57)}...` : line;
}

/** @param {Job} job @returns {string} */
export function name(job) {
  return "job-" + job.id.toString(36);
}

// The state of a job in the words of the engine end header (`reports.jobEnded`). The stop tool, the TUI, and the transcript share it.
// A `job_ended` source has no state, so it reads as an end. Neither number means the wait failed.
/** @param {{ state?: Job["state"], stop_requested?: boolean, exit_code?: number, signal?: number }} job @returns {string} */
export function endLabel(job) {
  if (job.state === "running") return job.stop_requested ? "stop requested" : "running";
  if (job.stop_requested && job.state !== "failed") return "stopped";
  return job.exit_code !== undefined ? "exited " + job.exit_code : job.signal !== undefined ? "signal " + job.signal : "failed";
}

// Only the exec tool starts a job.
/** The background jobs of the exec tool. A plugin lists, reads, stops, and waits for them. Each start, stop request, and end emits `job.changed` with the job. */
export const jobs = { list, get, stop, wait, read };
