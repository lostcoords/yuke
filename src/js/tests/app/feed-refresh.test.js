import { check } from "yuke:internal/test";
import { client } from "yuke:internal/client";
import { root } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { defaultModel, sessionsPlugin } from "yuke:internal/session";

plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
/** @param {string} id @param {string} model */
const row = (id, model) => ({ session: { id, title: "", model, reasoning: "", updated_at_ms: 1 }, activity: null });
let reads = 0, gets = 0, refuse = true;
/** @type {(() => void) | null} */
let release = null;
client.sessionList = () => {
  reads++;
  if (refuse) return Promise.reject(new Error("read refused"));
  // An open gate answers at once; a closed one holds the read in flight until `release`.
  if (!release) return Promise.resolve({ items: [row("a", "m-a")] });
  return new Promise((resolve) => { release = () => resolve({ items: [row("a", "m-a")] }); });
};
client.sessionGet = async (id) => { gets++; return row(id, "m-renamed"); };

// A refused read asks for no redraw, or the redraw would read again while the engine refuses; the next reader retries.
root._needsDraw = false;
defaultModel();
await settle();
check("refusal-draws-nothing", reads === 1 && !root._needsDraw);
refuse = false;
defaultModel();
await settle();
check("retry-reads-the-list", reads === 2 && root._needsDraw && defaultModel().model === "m-a");
defaultModel();
check("fresh-list-reads-nothing", reads === 2);
events.emit("index.changed", { type: "index", overflow: false, facts: ["catalog.changed", "notice"] });
defaultModel();
check("unrelated-facts-read-nothing", reads === 2);

// A summary change reads its one entry and never the list; a removed session leaves the list at once.
events.emit("session.changed", { type: "session", session: "a", kind: "quiet", facts: ["session.summary_changed"] });
await settle();
check("summary-reads-one-entry", gets === 1 && reads === 2 && defaultModel().model === "m-renamed");
events.emit("session.changed", { type: "session", session: "a", kind: "gone", facts: ["session.removed"] });
check("gone-leaves-the-list", defaultModel().model === null && reads === 2);

// An overflow waits for a reader, and a burst of readers shares one read.
events.emit("index.changed", { type: "index", overflow: true, facts: [] });
check("overflow-waits-for-reader", reads === 2);
defaultModel();
defaultModel();
check("reader-reads-once", reads === 3);
await settle();
// A change while a read is in flight earns one follow-up read, not one per reader.
release = () => {};
events.emit("index.changed", { type: "index", overflow: true, facts: [] });
defaultModel();
events.emit("session.changed", { type: "session", session: "a", kind: "quiet", facts: ["session.summary_changed"] });
defaultModel();
defaultModel();
check("in-flight-holds", reads === 4 && gets === 1);
release();
await settle();
check("change-in-flight-reads-again", reads === 5);
const last = release;
release = null;
last();
await settle();
defaultModel();
check("burst-ends", reads === 5);

// The list missed every change while the plugin was away, so a new apply reads it again.
plugins.dispose("sessions");
plugins.use(sessionsPlugin);
defaultModel();
check("apply-reads-again", reads === 6);
