import { check } from "yuke:test";
import { root, events, command, status, slot } from "yuke:core";
import { client } from "yuke:client";
import { feedOf } from "yuke:sessions";
import { loadCatalog } from "yuke:catalog";
import { elapsedLabel, phaseLabel, indicatorLine } from "yuke:indicator";
import { stripRows, queuedText, queueOf } from "yuke:queue";
import { contextBar, sessionCost } from "yuke:context";
import { chat } from "yuke:defaults";
const key = (code, o = {}) => ({ type: "key", code, char: "", text: "", event: "press", mods: 0, ...o });
const settle = async () => { for (let i = 0; i < 64; i++) await Promise.resolve(); };
const usage = { input: 200, output: 30, reasoning: 5, cache_read: 0, cache_write: 0 };
const idle = { state: { type: "idle" }, queued: 0, context_usage: usage, pending_compaction: null };
const tool = { ...idle, state: { type: "running_tool", run_id: 1, message_id: 1, part_id: 1, tool_name: "bash", started_at_ms: Date.now() - 65000 }, queued: 2 };
let answer = idle;
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
// Working with two queued: the rule names the tool and the elapsed time, and the strip reads the queue once.
answer = tool;
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
await settle();
const line = slot.get(chat.view, "rule");
check("rule-line", line && line.text.indexOf("bash · 1m05s · 2 queued") > 0);
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
check("context-instructions", root.overlays[0].content.rows.some((row) => row[0] === "workspace AGENTS" && row[1] === "/work/AGENTS.md"));
root.onEvent(key("esc"));
check("context-closed", root.overlays.length === 0);
// The pure helpers.
check("elapsed", elapsedLabel(12000) === "12s" && elapsedLabel(65000) === "1m05s" && elapsedLabel(-5) === "0s");
check("phase", phaseLabel({ type: "retrying", run_id: 1, attempt: 2, max_attempts: 5, next_at_ms: 4000, code: "rate_limited", message: "" }, 0) === "retry 2/5 in 4s · rate_limited");
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
  && indicatorLine("s1", { ...tool, state: { type: "running", run_id: 2, started_at_ms: Date.now() } }, Date.now()).indexOf("thinking · 0s") > 0);
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
