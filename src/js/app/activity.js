// yuke:activity — the live activity of every open session, read back after each activity fact.
import { events, root } from "yuke:core";
import { client } from "yuke:client";

/** @import { Context } from "yuke:ext" */
/** @import { EngineEvent } from "yuke:engine-native" */
/** @typedef {Extract<EngineEvent, { type: "session" }>} NativeSessionEvent */

// The last activity the engine reported for each session a pane holds open.
/** @type {Map<string, Wire.SessionActivity>} */
const live = new Map();

/** @param {string} sessionId @returns {Wire.SessionActivity | null} */
export function activityOf(sessionId) {
  return live.get(sessionId) || null;
}

// A feed row carries a looser activity shape, so the check reads only the state type.
/** @param {{ state: { type: string } } | null | undefined} activity @returns {boolean} */
export function isWorking(activity) {
  return activity != null && activity.state.type !== "idle";
}

// Read the activity again. The pane pinned the session, so a null read means the pane let it go.
/** @param {string} sessionId @returns {Wire.SessionActivity | null} */
export function refreshActivity(sessionId) {
  const activity = client.sessionActivity(sessionId);
  if (activity) live.set(sessionId, activity);
  else live.delete(sessionId);
  events.emit("activity.changed", sessionId, activity);
  root.invalidate();
  return activity;
}

/** @param {string} sessionId @returns {void} */
function forget(sessionId) {
  if (!live.delete(sessionId)) return;
  events.emit("activity.changed", sessionId, null);
  root.invalidate();
}

// The digest names the fact and this plugin reads the projection, so a burst of changes costs one read per frame.
export const activityPlugin = {
  name: "activity",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.on("session.changed", /** @param {NativeSessionEvent} ev */ (ev) => {
      if (!ev) return;
      if (ev.kind === "gone") forget(ev.session);
      else if (ev.facts.indexOf("session.activity_changed") >= 0) refreshActivity(ev.session);
    });
    // An unload emits one forget event for each held session.
    ctx.effect(() => () => {
      for (const id of Array.from(live.keys())) forget(id);
    });
  },
};
