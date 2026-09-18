import { root, Node } from "yuke:core";
import { events } from "yuke:kernel";
import { plugins, advice } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { client } from "yuke:client";
import { Chat } from "yuke:chat";
import { openAgents } from "yuke:agents-ui";

/** @import { InjectContext } from "./app/types/ext.js" */
/** @type {InjectContext} */
let context;
/** @type {Awaited<ReturnType<typeof openAgents>>} */
let picker;
/** @type {Chat | undefined} */
let chat;
let phase = "", count = 0, gets = 0, lists = 0, updates = 0, steps = 0;
/** @type {(() => void) | undefined} */
let off;
let activityChanges = 0;
events.on("engine.activity.changed", () => { client.isBusy(); activityChanges++; });
plugins.use(tuiPlugin);
plugins.use({ name: "agent-bench", apply(ctx) { ctx.inject(["tui"], ctx => { context = ctx; }); } });
advice.advise(client, "sessionGet", "before", () => { gets++; });
advice.advise(client, "sessionList", "before", () => { lists++; });

async function open() {
  picker?.content.cancel();
  off?.();
  picker = await openAgents(context, AGENTS_ROOT);
  if (!picker) throw new Error("missing picker");
  off = advice.advise(picker.content, "setSource", "after", () => { updates++; });
}
/** @param {string} name @param {number} scale */
async function start(name, scale) {
  picker?.content.cancel();
  off?.();
  if (chat) { chat.sessionId = null; chat.dispose(); }
  phase = name; count = scale;
  if (phase === "engine_activity" || phase === "engine_activity_changed") return 1;
  chat = new Chat();
  root.setRoot(Node.leaf(chat.view)); root.focusView(chat.view);
  chat.sessionId = AGENTS_ROOT;
  await open();
  gets = lists = updates = steps = 0;
  return 1;
}
function step() {
  steps++;
  if (phase === "engine_activity") {
    for (let i = 0; i < 1000; i++) if (client.isBusy()) throw new Error("idle tree is busy");
    return 1;
  }
  if (phase === "engine_activity_changed") return 1;
  if (phase === "agents_open") return open().then(() => 1);
  if (phase === "agents_structure") events.emit("index.changed", { type: "index", facts: ["session.summary_changed"] });
  else for (let i = 0; i < (phase === "agents_burst" ? 20 : 1); i++) {
    events.emit("session.changed", { type: "session", session: AGENTS_TARGET, kind: "quiet", facts: ["session.activity_changed"] });
  }
  return 1;
}
function verify() {
  if (phase === "engine_activity") return steps * 1000;
  if (phase === "engine_activity_changed") {
    if (activityChanges !== steps * 2) throw new Error("activity change count mismatch");
    return activityChanges;
  }
  if (!picker || picker.content.source.length !== count + 1) throw new Error("tree size mismatch");
  if (phase !== "agents_open" && updates < steps) throw new Error("missing refresh");
  if (picker.content.source[0]?.item.session.id !== AGENTS_ROOT) throw new Error("root mismatch");
  return count + 1;
}
globalThis.bench = { start, step, verify };
globalThis.agentReads = () => ({ gets, lists, updates });

globalThis.agentResetReads = () => { gets = lists = updates = steps = activityChanges = 0; return 0; };
