import { check } from "yuke:internal/test";
import { root, command, status, slot } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { client } from "yuke:internal/client";
import { feedOf } from "yuke:internal/sessions";
import { loadCatalog } from "yuke:internal/catalog";
import { elapsedLabel, phaseLabel, indicatorLine } from "yuke:internal/indicator";
import { stripRows, queuedText, queueOf } from "yuke:internal/queue";
import { contextBar, sessionCost } from "yuke:internal/context";
import { rowText } from "yuke:internal/pager";
import { chat } from "yuke:internal/defaults";
const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
const usage = { input: 200, output: 30, reasoning: 5, cache_read: 0, cache_write: 0 };
const idle = { state: { type: "idle" }, queued: 0, context_usage: usage, pending_compaction: null };
const tool = { ...idle, state: { type: "running_tool", run_id: 1, message_id: 1, part_id: 1, tool_name: "bash", started_at_ms: Date.now() - 65000 }, queued: 2 };
let answer = idle;
let load = { runs: 0, childRuns: 0, continuations: 0 };
client.load = () => load;
client.sessionOpen = () => true;
client.sessionActivity = () => answer;
client.sessionGet = async () => ({ instruction_sources: [{ scope: "workspace", path: "/work/AGENTS.md" }] });
const items = [
  { input_id: 11, queued_at_ms: 1, content: [{ type: "text", text: "first line\nsecond" }] },
  { input_id: 12, queued_at_ms: 2, content: [{ type: "image", source: { type: "blob", hash: "h", mime: "image/png", bytes: 1 } }, { type: "text", text: "look" }] },
];
let queueReads = 0;
client.sessionQueue = () => { queueReads++; return Promise.resolve({ items: items.slice(0, answer.queued) }); };
const dropped = [];
client.sessionCancelInput = (id, input) => { dropped.push(input); return Promise.resolve({ canceled_input: input }); };
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", providers: [],
  models: [{ id: "m", provider: "p", selector: "p/m", name: "m", context_window: 1000, reasoning_levels: [], default_reasoning: "", cost: { input: 10, output: 50 } }] });
await loadCatalog();
feedOf().seed({ items: [{ session: { id: "s1", model: "p/m", message_count: 19, updated_at_ms: 1, usage_total: { input: 1000000, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 } }, activity: idle }] });
root.focusView(chat.view);
chat.open("s1");
await settle();
// Idle: no rule line, no strip, and no queue command.
check("idle-rule", slot.get(chat.view, "rule") === null);
check("idle-strip", stripRows([]).length === 0 && slot.get(chat.view, "strip").length === 0);
check("idle-status", status.side("right").indexOf("[█░░░░░] 20% context") >= 0);
check("idle-no-queue-cmd", !command.available("queue:drop"));
// A resting pane still shows the child runs, and the time counts from the moment the count rose from zero.
load = { runs: 2, childRuns: 2, continuations: 0 };
const agentsLine = slot.get(chat.view, "rule");
check("agents-rule", agentsLine && agentsLine.text.indexOf("2 agents working · 0s") > 0);
load = { runs: 0, childRuns: 0, continuations: 0 };
check("agents-gone", slot.get(chat.view, "rule") === null);
// Working with two queued: the rule names the tool and the elapsed time, and the strip reads the queue once.
answer = tool;
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
const line = slot.get(chat.view, "rule");
check("rule-line", line && line.text.indexOf("bash · 1m05s · 2 queued") > 0 && line.text.indexOf("agent") < 0);
load = { runs: 3, childRuns: 1, continuations: 0 };
check("rule-line-agents", slot.get(chat.view, "rule").text.indexOf("bash · 1m05s · 2 queued · 1 agent ") > 0);
load = { runs: 0, childRuns: 0, continuations: 0 };
check("queue-read-once", queueReads === 1);
const strip = slot.get(chat.view, "strip");
check("strip-rows", strip.length === 2 && strip[0].text === " ↳ first line…" && strip[1].text === " ↳ [image] look");
check("working-status", status.side("right").indexOf("[█░░░░░] 20% context") >= 0);
// The same count reads nothing again; a changed count reads once more.
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
check("same-count-no-read", queueReads === 1);
// The picker drops the highlighted input through the engine.
check("queue-cmd", command.available("queue:drop"));
command.perform("queue:drop");
check("picker-open", root.overlays.length === 1);
root.onEvent(key("enter"));
await settle();
check("dropped-first", dropped.length === 1 && dropped[0] === 11 && root.overlays.length === 0);
answer = { ...tool, queued: 1 };
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
check("changed-count-reads", queueReads === 2 && slot.get(chat.view, "strip").length === 1);
// The strip folds a long queue into a count row.
const many = stripRows([items[0], items[0], items[0], items[0]]);
check("strip-folds", many.length === 3 && many[2].text === " ↳ … 2 more queued");
// The breakdown window opens on the command and closes on Escape.
command.perform("context:show");
await settle();
check("context-open", root.overlays.length === 1);
check("context-instructions", root.overlays[0].content.pager.source.rows(80, 0, 100).some((row) => /^workspace AGENTS +\/work\/AGENTS\.md$/.test(rowText(row))));
root.onEvent(key("esc"));
check("context-closed", root.overlays.length === 0);
// The pure helpers.
check("elapsed", elapsedLabel(12000) === "12s" && elapsedLabel(65000) === "1m05s" && elapsedLabel(-5) === "0s");
check("phase", phaseLabel({ type: "retrying", run_id: 1, attempt: 2, max_attempts: 5, next_at_ms: 4000, code: "rate_limited", message: "" }, 0) === "retry 2/5 in 4s · rate_limited");
// The countdown rounds up, so a short wait never reads "in 0s" while the run still holds.
check("phase-countdown-up", phaseLabel({ type: "retrying", run_id: 1, attempt: 2, max_attempts: 5, next_at_ms: 500, code: "rate_limited", message: "" }, 0) === "retry 2/5 in 1s · rate_limited");
check("phase-waiting", phaseLabel({ type: "waiting", run_id: 1, started_at_ms: 0 }, 0) === "waiting for response" && phaseLabel({ type: "streaming", run_id: 1, started_at_ms: 0 }, 0) === "responding");
check("bar", contextBar(0, 1000) === "[░░░░░░]" && contextBar(1, 1000) === "[░░░░░░]" && contextBar(500, 1000) === "[███░░░]" && contextBar(1000, 1000) === "[██████]" && contextBar(5, 0) === "[░░░░░░]");
check("cost", sessionCost({ input: 1000000, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, { input: 10 }) === 10 && sessionCost(usage, {}) === 0);
// The input total holds the cached subsets, so a cached token pays the cache price alone, never both prices.
check("cost-cache", sessionCost({ input: 1000000, output: 0, reasoning: 0, cache_read: 500000, cache_write: 0 }, { input: 10, cache_read: 2 }) === 6);
check("cost-cache-write", sessionCost({ input: 1000000, output: 0, reasoning: 0, cache_read: 250000, cache_write: 250000 }, { input: 10, cache_read: 2, cache_write: 4 }) === 6.5);
// A peer that reports more cached tokens than input tokens leaves no fresh remainder to charge.
check("cost-cache-over", sessionCost({ input: 100, output: 0, reasoning: 0, cache_read: 500, cache_write: 0 }, { input: 10, cache_read: 0 }) === 0);
// With no session the reading describes the next chat: the default model's window and 0%.
chat.newChat();
check("empty-reading", status.side("right").indexOf("[░░░░░░] 0% context") >= 0);
check("queued-text", queuedText(items[1]) === "[image] look");
// A new run restarts the elapsed time, and the same run keeps its start across a state with no start time.
check("run-change", indicatorLine("s1", { ...tool, state: { type: "reasoning", run_id: 1, message_id: 1, part_id: 1 } }, Date.now()).indexOf("1m05s") > 0
  && indicatorLine("s1", { ...tool, state: { type: "streaming", run_id: 2, started_at_ms: Date.now() } }, Date.now()).indexOf("responding · 0s") > 0);
// The count rose at one second, so the line counts from there; a zero count ends the words.
indicatorLine("s1", idle, 1000, 3);
check("agents-elapsed", indicatorLine("s1", idle, 66000, 3).indexOf("3 agents working · 1m05s") > 0 && indicatorLine("s1", idle, 66000) === "");
// A queue read that lands after the pane let the session go stays out, and the close clears both slots.
let land = null;
client.sessionQueue = () => new Promise((resolve) => { land = resolve; });
chat.open("s1");
answer = { ...tool, queued: 3 };
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
answer = null;
chat.newChat();
check("close-forgets", slot.get(chat.view, "strip") === null && slot.get(chat.view, "rule") === null);
land({ items });
await settle();
check("late-read-ignored", queueOf("s1").length === 0);
// The bar glyphs are a plugin config, so a terminal with a font that fits can show another pair.
check("bar-config", contextBar(500, 1000, 6, "▰▱") === "[▰▰▰▱▱▱]");
