// Child sessions for a delegation plugin: the child ID the model reads, the lookup of a direct child, and the stop of a child.
import { client, allChildren } from "yuke:internal/client";
import { list as listJobs, stop as stopJob } from "yuke:internal/jobs";
import { native } from "yuke:internal/native/engine";

/** @import { AgentLimits } from "./types/ext.js" */

/**
 * The child ID that the model reads. It is the child name and the last 8 hex digits of the session ID. The engine report header uses the same ID.
 * @param {string} name @param {string} sessionId @returns {string}
 */
function id(name, sessionId) {
  return name + "-" + sessionId.slice(-8);
}

/**
 * The direct child of `parentId` that the child ID `childId` names, or null when no direct child has that ID.
 * @param {string} parentId @param {string} childId @returns {Promise<Wire.SessionListItem | null>}
 */
async function find(parentId, childId) {
  return (await allChildren(parentId)).find((item) => id(item.session.name ?? "", item.session.id) === childId) ?? null;
}

/**
 * Stop a child for its parent: cancel its run, drop its queued input, and end its running jobs. The caller returns the result, so the parent gets no report.
 * A job end would start a new run, so the stop also ends the jobs. The transcript and completed side effects remain.
 * @param {string} sessionId @returns {Promise<Wire.SessionCancelRunResult>}
 */
async function stop(sessionId) {
  const result = await client.sessionCancelRun(sessionId, true, false);
  for (const job of listJobs()) if (job.session_id === sessionId && job.state === "running") await stopJob(job.id);
  return result;
}

/**
 * Set the child limits of the engine, and answer the function that puts the previous pair back. Call it in `ctx.effect`, so an unload of the plugin restores the limits.
 * It throws a TypeError for a value that is not an integer from 1 to 4294967295.
 * @param {AgentLimits} next @returns {() => void}
 */
function limits(next) {
  const previous = native.setAgentLimits(next.maxConcurrent, next.maxDepth);
  return () => { native.setAgentLimits(previous[0], previous[1]); };
}

/** The child sessions of a parent. A child is a session that `client.sessionCreate` makes with `child`. */
export const children = {
  /** List every direct child of a parent. It throws when the list exceeds 32 pages of 100 or a page cursor does not advance. */
  list: allChildren,
  /** Make the child ID that the model reads. */
  id,
  /** Find the direct child that a child ID names. The answer is null for an unknown ID or a child of another parent. */
  find,
  /** Stop a child. The parent gets no report. */
  stop,
  /** Set the engine child limits. Call it in `ctx.effect`. */
  limits,
};
