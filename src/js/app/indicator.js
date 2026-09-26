// The working line on the rule above the composer: a spinner, the phase, the elapsed time, and the child runs.
import { sessions } from "yuke:internal/session";
import { client } from "yuke:internal/client";
import { agentsLabel, elapsedLabel } from "yuke:internal/format";

/** @import { Context } from "yuke:internal/ext" */

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const PERIOD_MS = 100;

// The frame counter advances on each tick, so every pane spins in step.
let frame = 0;

// The start of the run a session works on. A reasoning state has no start time, so the first sight of a run keeps one.
/** @type {Map<string, { run_id: number, at: number }>} */
const starts = new Map();

// The moment the child count last rose from zero, so the aggregate reads how long the agents have worked.
let agentsSince = 0;

/** @param {Wire.SessionActivity | null} activity @returns {boolean} */
function isWorking(activity) {
  return activity != null && activity.state.type !== "idle";
}

// The words for one working state. `now` is the wall clock in milliseconds, the clock the engine stamps.
/** @param {Wire.ActivityState} state @param {number} now @returns {string} */
export function phaseLabel(state, now) {
  switch (state.type) {
    case "building": return "starting";
    case "waiting": return "waiting for response";
    case "streaming": return "responding";
    case "reasoning": return "reasoning";
    case "running_tool": return state.tool_name;
    // The 999 ms rounds the countdown up, so a short wait never reads "in 0s" while the run still holds.
    case "retrying": return "retry " + state.attempt + "/" + state.max_attempts + " in " + elapsedLabel(state.next_at_ms - now + 999) + " · " + state.code;
    case "compacting": return "compacting";
    default: return "";
  }
}

// The whole line for one session, or "" while it and the child runs rest. A resting pane still shows the child runs.
/** @param {string} sessionId @param {Wire.SessionActivity | null} activity @param {number} now @param {number} [childRuns] @returns {string} */
export function indicatorLine(sessionId, activity, now, childRuns = 0) {
  const spinner = /** @type {string} */ (FRAMES[frame % FRAMES.length]);
  if (childRuns === 0) agentsSince = 0;
  else if (agentsSince === 0) agentsSince = now;
  const suffix = childRuns > 0 ? " · " + agentsLabel(childRuns) : "";
  if (!isWorking(activity)) {
    starts.delete(sessionId);
    return childRuns > 0 ? " " + spinner + " " + agentsLabel(childRuns) + " working · " + elapsedLabel(now - agentsSince) + " " : "";
  }
  const state = /** @type {Wire.SessionActivity} */ (activity).state;
  const run_id = /** @type {{ run_id: number }} */ (state).run_id;
  const held = starts.get(sessionId);
  const at = held && held.run_id === run_id ? held.at : "started_at_ms" in state ? state.started_at_ms : now;
  if (!held || held.run_id !== run_id) starts.set(sessionId, { run_id, at });
  const queued = /** @type {Wire.SessionActivity} */ (activity).queued;
  return " " + spinner + " " + phaseLabel(state, now) + " · " + elapsedLabel(now - at) + (queued > 0 ? " · " + queued + " queued" : "") + suffix + " ";
}

/** @returns {boolean} */
function anyWorking() {
  if (client.load().childRuns > 0) return true;
  for (const session of sessions) if (isWorking(session.activity)) return true;
  return false;
}

export const indicatorPlugin = {
  name: "indicator",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.on("chat.rule", (view) => {
        const id = view.session.sessionId;
        if (!id) return null;
        const line = indicatorLine(id, view.session.activity, Date.now(), client.load().childRuns);
        return line ? { text: line, group: "YukeStatus" } : null;
      });
      // The frame loop runs only while a pane or a child run works, so an idle screen costs no wakeups.
      ctx.tui.tickable({
        needsTick: () => (anyWorking() ? { periodMs: PERIOD_MS } : null),
        tick: () => {
          frame++;
        },
      });
      ctx.effect(() => () => { starts.clear(); agentsSince = 0; });
    });
  },
};
