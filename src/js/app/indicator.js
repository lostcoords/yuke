// The working line on the rule above the composer: a spinner, the phase, the elapsed time, and the child runs.
import { ChatView } from "yuke:internal/chat-view";
import { chatOf, chats } from "yuke:internal/chat";
import { client } from "yuke:internal/client";
import { activityOf, agentsLabel, isWorking } from "yuke:internal/activity";

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

/** @param {number} ms @returns {string} */
export function elapsedLabel(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  const rest = s % 60;
  return m + "m" + (rest < 10 ? "0" : "") + rest + "s";
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
  for (const c of chats) if (c.sessionId && isWorking(activityOf(c.sessionId))) return true;
  return false;
}

export const indicatorPlugin = {
  name: "indicator",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.slot(ChatView, "rule", /** @param {ChatView} view @returns {{ text: string, group: string } | null} */ (view) => {
        const c = chatOf(view);
        if (!c || !c.sessionId) return null;
        const line = indicatorLine(c.sessionId, activityOf(c.sessionId), Date.now(), client.load().childRuns);
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
