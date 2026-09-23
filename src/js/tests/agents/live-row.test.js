import { root, Node } from "yuke:core";
import { events } from "yuke:kernel";
import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { Chat } from "yuke:chat";
import { client } from "yuke:client";
import { agents, childLabel } from "yuke:agents";
const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
const check = (ok, why) => { if (!ok) throw new Error(why); };
plugins.use(tuiPlugin);
plugins.use(agents({ catalog: { explore: {} } }));
(async () => {
  const parent = "01".repeat(16), childId = "02".repeat(16);
  const chat = new Chat();
  root.setRoot(Node.leaf(chat.view)); root.focusView(chat.view);
  chat.sessionId = parent;
  const output = JSON.stringify({ session_id: childId, agent: "explore", model: "m", state: "started" });
  const part = { type: "tool", id: 0, name: "spawn_agent", arguments: JSON.stringify({ agent: "explore", message: "look" }), state: { type: "completed", output, duration_ms: 0 } };
  client.sessionOutline = () => ({ messages: [{ id: 1, type: "assistant" }], active: null });
  client.sessionParts = () => [part];
  client.sessionPart = () => part;
  const usage = { input: 8200, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 };
  const item = { session: { id: childId, model: "m", origin: { type: "child", name: "explore", site: { session_id: parent, message_id: 1, part_id: 0 } } }, activity: { state: { type: "running_tool", run_id: 1, message_id: 1, part_id: 0, tool_name: "read", started_at_ms: 1 }, queued: 0, context_usage: usage, pending_compaction: null }, last_run: null };
  let gets = 0;
  client.sessionGet = async () => { gets++; return JSON.parse(JSON.stringify(item)); };
  chat.reload();
  const t = chat.transcript;
  const text = () => t.rows(80, 0, t.rowCount(80)).map((row) => row.text || (row.segments || []).map((segment) => segment.text).join("")).join("\n");
  // The first render names the agent alone and starts one read; the read rebuilds the row with the live words.
  check(text().includes("Agent explore") && !text().includes("read"), "first render must be plain: " + text());
  await settle();
  check(gets === 1, "one read on first sight");
  check(text().includes("Agent explore · tool · read · 8.2k ctx"), "live row after the read: " + text());
  // A burst of facts coalesces into the read in flight and one more.
  gets = 0;
  for (let i = 0; i < 20; i++) events.emit("session.changed", { type: "session", session: childId, kind: "quiet", facts: ["session.activity_changed"] });
  await settle();
  check(gets === 2, "burst must coalesce: " + gets);
  item.activity.state = { type: "idle" }; item.last_run = { type: "turn", finish: "end_turn", rounds: 2 };
  events.emit("session.changed", { type: "session", session: childId, kind: "quiet", facts: ["run.done"] });
  await settle();
  check(text().includes("Agent explore · completed · 8.2k ctx"), "done row: " + text());
  check(childLabel({ ...item, activity: { ...item.activity, context_usage: { ...usage, input: 0 } } }) === "completed", "no context words at zero");
  // A fact the row does not draw costs no read.
  gets = 0;
  events.emit("session.changed", { type: "session", session: childId, kind: "quiet", facts: ["run.started"] });
  await settle();
  check(gets === 0, "an undrawn fact must not read");
  // A rejected read leaves the last words, and the next fact reads again.
  client.sessionGet = async () => { gets++; throw new Error("gone away"); };
  events.emit("session.changed", { type: "session", session: childId, kind: "quiet", facts: ["session.activity_changed"] });
  await settle();
  check(gets === 1 && text().includes("Agent explore · completed · 8.2k ctx"), "rejected read must keep the row: " + text());
  client.sessionGet = async () => { gets++; return JSON.parse(JSON.stringify(item)); };
  // A removed child leaves the plain row.
  events.emit("session.changed", { type: "session", session: childId, kind: "gone", facts: ["session.removed"] });
  await settle();
  check(!text().includes("completed"), "gone child must leave the plain row: " + text());
  chat.sessionId = null; chat.dispose();
  globalThis.result = "ok";
})().catch((e) => { globalThis.result = e.stack || e.message; });
