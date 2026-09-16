// Background jobs: shell lines whose output goes to a private log. Every start, exit, and stop emits `jobs.changed` with a copy of the job.

import { spawn, kill } from "yuke:process";
import { events } from "yuke:kernel";

/** @typedef {{ id: string, command: string, root: string | undefined, sessionId: string | undefined, log: string, state: "running" | "exited" | "stopped", code: number | null, signal: number | null, startedAt: number, endedAt: number | null }} Job */
/** @typedef {{ job: Job, native: number, ended: Promise<void>, stopping: boolean }} Entry */

/** @type {Map<string, Entry>} */
const table = new Map();
let count = 0;
const MAX_ENDED = 32;

// Keep the newest ended jobs only, so the table stays bounded.
function prune() {
  const ended = [...table.values()].filter((e) => e.job.state !== "running");
  for (const old of ended.slice(0, Math.max(0, ended.length - MAX_ENDED))) table.delete(old.job.id);
}

/** @param {Entry} entry @param {"exited" | "stopped"} state @param {{ code: number | null, signal: number | null } | null} exit @returns {void} */
function finish(entry, state, exit) {
  if (entry.job.state !== "running") return;
  Object.assign(entry.job, { state, code: exit?.code ?? null, signal: exit?.signal ?? null, endedAt: Date.now() });
  prune();
  events.emit("jobs.changed", { ...entry.job });
}

/** @param {string} command @param {{ root?: string, sessionId?: string }} [options] @returns {Promise<Job>} */
export async function start(command, options = {}) {
  const child = spawn(command, { log: true }, undefined, options.root);
  // A failed start rejects `exited`, so this await throws the reason.
  if (child.id === 0) await child.exited;
  /** @type {Job} */
  const job = { id: `j${++count}`, command, root: options.root, sessionId: options.sessionId, log: child.log ?? "", state: "running", code: null, signal: null, startedAt: Date.now(), endedAt: null };
  /** @type {Entry} */
  const entry = { job, native: child.id, ended: Promise.resolve(), stopping: false };
  // A stop settles when the child ends, so the log already holds its exit line.
  entry.ended = child.exited.then((exit) => finish(entry, entry.stopping ? "stopped" : "exited", exit), () => finish(entry, entry.stopping ? "stopped" : "exited", null));
  table.set(job.id, entry);
  events.emit("jobs.changed", { ...job });
  return { ...job };
}

/** @returns {Job[]} */
export function list() {
  return [...table.values()].map((e) => ({ ...e.job }));
}

/** @param {string} id @returns {Job | null} */
export function get(id) {
  const entry = table.get(id);
  return entry ? { ...entry.job } : null;
}

// A job that exited before the kill keeps its real end, so the answer is always the final state.
/** @param {string} id @returns {Promise<Job | null>} */
export async function stop(id) {
  const entry = table.get(id);
  if (!entry) return null;
  if (entry.job.state === "running" && kill(entry.native)) entry.stopping = true;
  await entry.ended;
  return { ...entry.job };
}

// The public surface: a plugin reads and stops jobs, and only the exec tool starts them.
export const jobs = { list, get, stop };
