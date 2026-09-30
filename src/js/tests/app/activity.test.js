import { check, listSessions } from "yuke:internal/test";
import { root } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { client } from "yuke:internal/client";
import { plugins } from "yuke:internal/ext";
import { currentEntry, showSession, currentPane } from "yuke:internal/session";
// The shell built the first chat pane at boot.
const chat = currentPane();
const idle = { state: { type: "idle" }, queued: 0, context_usage: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, pending_compaction: null };
const streaming = { ...idle, state: { type: "streaming", run_id: 1, started_at_ms: 5 }, queued: 2 };
let reads = 0;
let answer = streaming;
client.sessionOpen = () => true;
client.sessionActivity = () => { reads++; return answer; };
const cancels = [];
client.sessionCancelRun = (id, clear) => { cancels.push([id, clear]); return Promise.resolve({ cleared_inputs: [] }); };
await listSessions([{ session: { id: "s1", model: "m", updated_at_ms: 1 }, activity: idle }]);
const seen = [];
events.on("activity.changed", (id, a) => seen.push(id + ":" + (a ? a.state.type : "null")));
root.focusView(chat);
showSession(chat, "s1");
check("open-reads", reads === 1 && chat.session.activity === streaming && chat.session.activity.queued === 2);
check("entry-overlays", currentEntry().activity === streaming && currentEntry().session.model === "m");
// A quiet digest without the fact costs no read; one with the fact reads once.
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["run.started"] });
check("no-fact-no-read", reads === 1);
answer = idle;
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
check("fact-reads", reads === 2 && chat.session.activity === idle && currentEntry().activity === idle);
// A null read means the engine let the session go, and a gone session forgets its activity.
answer = null;
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
check("null-forgets", chat.session.activity === null && currentEntry().activity === idle);
answer = streaming;
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
events.emit("session.changed", { type: "session", session: "s1", kind: "gone", facts: ["session.removed"] });
check("gone-forgets", chat.session.activity === null && chat.session.sessionId === null);
check("events", seen.join(",") === "s1:streaming,s1:idle,s1:null,s1:streaming,s1:null");
// An interrupt stops the run and never clears the queue.
chat.session.sessionId = "s1";
chat.session.interrupt();
check("interrupt-keeps-queue", cancels.length === 1 && cancels[0][0] === "s1" && cancels[0][1] === undefined);
// Nothing reads the activity once the session layer unloads, so it forgets every live activity and nothing reads as working.
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet", facts: ["session.activity_changed"] });
const working = chat.session.activity === streaming;
plugins.dispose("sessions");
check("unload-forgets-activity", working && chat.session.activity === null && seen[seen.length - 1] === "s1:null");
