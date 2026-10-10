import { check, listSessions } from "yuke:internal/test";
import { Session, showSession, currentPane } from "yuke:internal/session";
import { root, command, status } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { client } from "yuke:internal/client";
import { catalogRefresh } from "yuke:internal/catalog";
import { phaseLabel, indicatorLine } from "yuke:internal/indicator";
import { elapsedLabel, contextBar } from "yuke:internal/format";
import { stripRows, queuedText, queueOf } from "yuke:internal/queue";
import { rowText } from "yuke:internal/pager";
// The shell built the first chat pane at boot.
const chat = currentPane();
const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
const usage = { input: 200, output: 30, reasoning: 5, cache_read: 0, cache_write: 0 };
// The count differs from the last input, so a check reads the right one.
const idle = { state: { type: "idle" }, queued: 0, context_tokens: 300, pending_compaction: null };
const tool = { ...idle, state: { type: "running_tool", run_id: 1, message_id: 1, part_id: 1, tool_name: "bash", started_at_ms: Date.now() - 65000 }, queued: 2 };
let answer = idle;
let load = { runs: 0, childRuns: 0, continuations: 0 };
client.load = () => load;
client.sessionOpen = () => true;
client.sessionActivity = () => answer;
client.sessionContextInfo = async () => ({ instruction_sources: [{ scope: "workspace", path: "/work/AGENTS.md" }], usage_last: usage });
const items = [
  { input_id: 11, queued_at_ms: 1, content: [{ type: "text", text: "first line\nsecond" }] },
  { input_id: 12, queued_at_ms: 2, content: [{ type: "image", source: { type: "blob", hash: "h", mime: "image/png", bytes: 1 } }, { type: "text", text: "look" }] },
];
let queueReads = 0;
client.sessionQueue = () => { queueReads++; return Promise.resolve({ items: items.slice(0, answer.queued) }); };
const dropped = [];
client.sessionCancelInput = (id, input) => { dropped.push(input); return Promise.resolve({ canceled_input: input }); };
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", providers: [],
  models: [{ id: "m", provider: "p", selector: "p/m", name: "m", context_window: 1000, reasoning_levels: [], default_reasoning: "", cost: [{ min_prompt_tokens: 0, input: 10, output: 50, reasoning: 50 }] }] });
await catalogRefresh.run();
await listSessions([{ session: { id: "s1", model: "p/m", message_count: 19, updated_at_ms: 1, usage_total: { input: 1000000, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, cost: { total: 10, without_cache: 10, unpriced: 0 } }, activity: idle }]);
root.focusView(chat);
showSession(chat, "s1");
await settle();
// Idle: no rule line, no strip, and no queue command.
check("idle-rule", events.bail("chat.rule", chat) === undefined);
check("idle-strip", stripRows([]).length === 0 && events.bail("chat.strip", chat).length === 0);
check("idle-status", status.side("right").indexOf(contextBar(300, 1000) + " 30% context") >= 0);
check("idle-no-queue-cmd", !command.available("queue:drop"));
// A resting pane still shows the child runs from the moment the count rose from zero; a tick reads the load once, and each pane rule reads that count.
load = { runs: 2, childRuns: 2, continuations: 0 };
root.tickLayers();
const agentsLine = events.bail("chat.rule", chat);
check("agents-rule", agentsLine && agentsLine.text.indexOf("2 agents working · 0s") > 0);
// The last child run ends: the loop asks one more tick, so a draw paints the zero count, and then the loop stops.
const ticker = root.tickables.find((e) => e.tickable.needsTick() !== null).tickable;
load = { runs: 0, childRuns: 0, continuations: 0 };
check("agents-end-ticks", ticker.needsTick() !== null);
check("agents-gone", events.bail("chat.rule", chat) === undefined);
check("agents-end-stops", ticker.needsTick() === null);
// Working with two queued: the rule names the tool and the elapsed time, the queue shows in the strip alone, and the strip reads the queue once.
answer = tool;
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
const line = events.bail("chat.rule", chat);
check("rule-line", line && line.text.indexOf("bash · 1m05s ") > 0 && line.text.indexOf("queued") < 0 && line.text.indexOf("agent") < 0);
load = { runs: 3, childRuns: 1, continuations: 0 };
root.tickLayers();
check("rule-line-agents", events.bail("chat.rule", chat).text.indexOf("bash · 1m05s · 1 agent ") > 0);
load = { runs: 0, childRuns: 0, continuations: 0 };
root.tickLayers();
check("queue-read-once", queueReads === 1);
const strip = events.bail("chat.strip", chat);
check("strip-rows", strip.length === 2 && strip[0].text === " ↳ first line…" && strip[1].text === " ↳ [image] look");
check("working-status", status.side("right").indexOf(contextBar(300, 1000) + " 30% context") >= 0);
// The same count reads nothing again; a changed count reads once more.
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
check("same-count-no-read", queueReads === 1);
// The picker drops the highlighted input through the engine.
check("queue-cmd", command.available("queue:drop"));
command.perform("queue:drop");
// A toast floats over the panes, so only a modal layer counts as an open dialog.
const dialogs = () => root.overlays.filter((o) => o.modal !== false);
check("picker-open", dialogs().length === 1);
root.onEvent(key("enter"));
await settle();
check("dropped-first", dropped.length === 1 && dropped[0] === 11 && dialogs().length === 0);
answer = { ...tool, queued: 1 };
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
check("changed-count-reads", queueReads === 2 && events.bail("chat.strip", chat).length === 1);
// The strip folds a long queue into a count row.
const many = stripRows([items[0], items[0], items[0], items[0]]);
check("strip-folds", many.length === 3 && many[2].text === " ↳ … 2 more queued");
// The breakdown window opens on the command and closes on Escape.
command.perform("context:show");
await settle();
check("context-open", dialogs().length === 1);
const shownRows = [];
dialogs()[0].content.pager.source.rows(80, 0, 100, shownRows, []);
const windowRows = shownRows.map(rowText);
check("context-instructions", windowRows.some((row) => /^workspace AGENTS +\/work\/AGENTS\.md$/.test(row)));
check("context-count", windowRows.some((row) => /^context +300 \/ 1,000 · 30%$/.test(row)));
check("context-last-turn", windowRows.some((row) => /^last turn +in 200 · out 30 · reasoning 5$/.test(row)));
// The engine priced each turn, so the cost row states the session sum.
check("context-cost", windowRows.some((row) => /^cost +\$10\.00$/.test(row)));
root.onEvent(key("esc"));
check("context-closed", dialogs().length === 0);
// The pure helpers.
check("elapsed", elapsedLabel(12000) === "12s" && elapsedLabel(65000) === "1m05s" && elapsedLabel(-5) === "0s");
check("phase", phaseLabel({ type: "retrying", run_id: 1, attempt: 2, max_attempts: 5, next_at_ms: 4000, code: "rate_limited", message: "" }, 0) === "retry 2/5 in 4s · rate_limited");
// The countdown rounds up, so a short wait never reads "in 0s" while the run still holds.
check("phase-countdown-up", phaseLabel({ type: "retrying", run_id: 1, attempt: 2, max_attempts: 5, next_at_ms: 500, code: "rate_limited", message: "" }, 0) === "retry 2/5 in 1s · rate_limited");
check("phase-waiting", phaseLabel({ type: "waiting", run_id: 1, started_at_ms: 0 }, 0) === "waiting for response" && phaseLabel({ type: "streaming", run_id: 1, started_at_ms: 0 }, 0) === "responding");
// A clock pulse rebuilds the running tool row without rereading its part.
const elapsedSession = new Session();
let elapsedRefresh = "";
elapsedSession.activity = tool;
elapsedSession.views.push({ transcript: { refreshRow: (message, part) => { elapsedRefresh = message + ":" + part; } } });
elapsedSession.refreshElapsed();
check("tool-elapsed-refresh", elapsedRefresh === "1:1");
check("bar", contextBar(0, 1000) === "[░░░░░░]" && contextBar(1, 1000) === "[░░░░░░]" && contextBar(500, 1000) === "[███░░░]" && contextBar(1000, 1000) === "[██████]" && contextBar(5, 0) === "[░░░░░░]");
// With no session the reading describes the next chat: the default model's window and 0%.
showSession(chat, new Session());
check("empty-reading", status.side("right").indexOf("[░░░░░░] 0% context") >= 0);
check("queued-text", queuedText(items[1]) === "[image] look");
// A new run restarts the elapsed time, and the same run keeps its start across a state with no start time.
check("run-change", indicatorLine("s1", { ...tool, state: { type: "reasoning", run_id: 1, message_id: 1, part_id: 1 } }, Date.now()).indexOf("1m05s") > 0
  && indicatorLine("s1", { ...tool, state: { type: "streaming", run_id: 2, started_at_ms: Date.now() } }, Date.now()).indexOf("responding · 0s") > 0);
// The count rose at one second, so the line counts from there; a zero count ends the words.
indicatorLine("s1", idle, 1000, 3);
check("agents-elapsed", indicatorLine("s1", idle, 66000, 3).indexOf("3 agents working · 1m05s") > 0 && indicatorLine("s1", idle, 66000) === "");
// A queue read that lands after the pane let the session go stays out, and the close clears both points.
let land = null;
client.sessionQueue = () => new Promise((resolve) => { land = resolve; });
showSession(chat, "s1");
answer = { ...tool, queued: 3 };
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
answer = null;
showSession(chat, new Session());
check("close-forgets", events.bail("chat.strip", chat) === undefined && events.bail("chat.rule", chat) === undefined);
land({ items });
await settle();
check("late-read-ignored", queueOf("s1").length === 0);
