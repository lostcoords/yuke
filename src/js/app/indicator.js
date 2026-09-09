// yuke:indicator — the working line on the rule above the composer: a spinner, the phase, and the elapsed time.
import { ChatView } from "yuke:chat-view";
import { chatOf, chats } from "yuke:chat";
import { activityOf, isWorking } from "yuke:activity";

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const PERIOD_MS = 100;

// The frame counter advances on each tick, so every pane spins in step.
let frame = 0;

// The start of the run a session works on. A reasoning state has no start time, so the first sight of a run keeps one.
/** @type {Map<string, { run_id: number, at: number }>} */
const starts = new Map();

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
    case "running": return "thinking";
    case "reasoning": return "reasoning";
    case "running_tool": return state.tool_name;
    case "retrying": return "retry " + state.attempt + "/" + state.max_attempts + " in " + elapsedLabel(state.next_at_ms - now) + " · " + state.code;
    case "compacting": return "compacting";
    default: return "";
  }
}

// The whole line for one session, or "" while it rests.
/** @param {string} sessionId @param {Wire.SessionActivity | null} activity @param {number} now @returns {string} */
export function indicatorLine(sessionId, activity, now) {
  if (!isWorking(activity)) {
    starts.delete(sessionId);
    return "";
  }
  const state = /** @type {Wire.SessionActivity} */ (activity).state;
  const run_id = /** @type {{ run_id: number }} */ (state).run_id;
  const held = starts.get(sessionId);
  const at = held && held.run_id === run_id ? held.at : "started_at_ms" in state ? state.started_at_ms : now;
  if (!held || held.run_id !== run_id) starts.set(sessionId, { run_id, at });
  const queued = /** @type {Wire.SessionActivity} */ (activity).queued;
  const spinner = /** @type {string} */ (FRAMES[frame % FRAMES.length]);
  return " " + spinner + " " + phaseLabel(state, now) + " · " + elapsedLabel(now - at) + (queued > 0 ? " · " + queued + " queued" : "") + " ";
}

/** @returns {boolean} */
function anyWorking() {
  for (const c of chats) if (c.sessionId && isWorking(activityOf(c.sessionId))) return true;
  return false;
}

export const indicatorPlugin = {
  name: "indicator",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.slot(ChatView, "rule", /** @param {ChatView} view @returns {{ text: string, group: string } | null} */ (view) => {
        const c = chatOf(view);
        if (!c || !c.sessionId) return null;
        const line = indicatorLine(c.sessionId, activityOf(c.sessionId), Date.now());
        return line ? { text: line, group: "YukeStatus" } : null;
      });
      // The frame loop runs only while a pane works, so an idle screen costs no wakeups.
      ctx.tui.tickable({
        needsTick: () => (anyWorking() ? { periodMs: PERIOD_MS } : null),
        tick: () => {
          frame++;
        },
      });
      ctx.effect(() => () => starts.clear());
    });
  },
};
