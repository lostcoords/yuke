// yuke:jobs — background jobs over the native table: every start and end emits `jobs.changed` with a fresh copy of the job.

import * as native from "yuke:jobs-native";
import { events } from "yuke:kernel";

/** @typedef {import("yuke:jobs-native").Job} Job */

export const { list, get, read } = native;

/** @param {string} command @param {{ root?: string, sessionId?: string }} [options] @returns {Promise<Job>} */
export async function start(command, options = {}) {
  const { job, ended } = await native.start(command, options.sessionId ?? null, options.root);
  events.emit("jobs.changed", job);
  ended.then((done) => events.emit("jobs.changed", done));
  return job;
}

/** @param {number} id @returns {Promise<Job | null>} */
export async function stop(id) {
  const before = native.get(id);
  const job = native.stop(id);
  if (job?.stop_requested && !before?.stop_requested) events.emit("jobs.changed", job);
  return job;
}

/** @param {number} id @returns {Promise<Job | null>} */
export function wait(id) {
  const job = native.get(id);
  if (job === null || job.state !== "running") return Promise.resolve(job);
  return new Promise((resolve) => {
    const off = events.on("jobs.changed", (/** @type {Job} */ changed) => {
      if (changed.id !== id || changed.state === "running") return;
      off();
      resolve(native.get(id) ?? changed);
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
  return "j" + job.id;
}

// The end of a job in words, shared by the tool text and the TUI list.
/** @param {Job} job @returns {string} */
export function endLabel(job) {
  if (job.state === "failed") return "process wait failed";
  if (job.stop_requested) return job.state === "running" ? "stop requested" : "stopped";
  if (job.state === "running") return "running";
  return job.signal !== undefined ? "signal " + job.signal : "exit code " + job.exit_code;
}

// The last lines of a job log; the read covers the last 8 KiB.
/** @param {number} id @param {number} count @returns {Promise<string>} */
export async function tail(id, count) {
  const { text } = await read(id, null, 8192);
  return text.split("\n").filter((line, i, all) => line !== "" || i < all.length - 1).slice(-count).join("\n");
}

// The public surface: a plugin reads and stops jobs, and only the exec tool starts them.
export const jobs = { list, get, stop, wait, read };
