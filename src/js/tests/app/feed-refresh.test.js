import { check } from "yuke:internal/test";
import { client } from "yuke:internal/client";
import { feedOf } from "yuke:internal/session";

const feed = feedOf();
feed.seed({ items: [{ session: { id: "old" }, activity: null }] });
client.sessionList = async () => ({ items: [{ session: { id: "new" }, activity: null }] });
await feed.refresh();
check("refresh-replaces-state", !feed.loading && feed.items.has("new") && !feed.items.has("old"));
client.sessionList = async () => { throw new Error("read refused"); };
await feed.refresh();
check("refusal-retains-state", !feed.loading && feed.items.has("new"));


// The list reads only when a reader looks after an overflow, once per burst; a summary change reads its one entry.
const { events } = await import("yuke:internal/kernel");
const { plugins } = await import("yuke:internal/ext");
const { tuiPlugin } = await import("yuke:internal/tui");
const { sessionsPlugin, feedItem } = await import("yuke:internal/session");
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
let reads = 0, gets = 0;
/** @type {(() => void) | null} */
let release = null;
client.sessionList = () => {
  reads++;
  // An open gate answers at once; a closed one holds the read in flight until `release`.
  if (!release) return Promise.resolve({ items: [{ session: { id: "new", title: "" }, activity: null }] });
  return new Promise((resolve) => { release = () => resolve({ items: [{ session: { id: "new", title: "" }, activity: null }] }); });
};
client.sessionGet = async (id) => { gets++; return { session: { id, title: "renamed" }, activity: null }; };
await feed.refresh();
reads = 0;
events.emit("index.changed", { type: "index", overflow: false, facts: ["catalog.changed", "notice"] });
feedItem("new");
check("unrelated-facts-read-nothing", reads === 0);

// A summary change reads its one entry and never the list.
events.emit("session.changed", { type: "session", session: "new", kind: "quiet", facts: ["session.summary_changed"] });
await settle();
check("summary-reads-one-entry", gets === 1 && reads === 0 && feedItem("new")?.session.title === "renamed");
// A removed session leaves the list at once.
events.emit("session.changed", { type: "session", session: "new", kind: "gone", facts: ["session.removed"] });
check("gone-leaves-the-list", feedItem("new") === null && reads === 0);

events.emit("index.changed", { type: "index", overflow: true, facts: [] });
check("overflow-waits-for-reader", reads === 0);
feedItem("new");
feedItem("new");
check("reader-reads-once", reads === 1);
await settle();
// A change while a read is in flight earns one follow-up read, not one per reader.
release = () => {};
events.emit("index.changed", { type: "index", overflow: true, facts: [] });
feedItem("new");
events.emit("session.changed", { type: "session", session: "new", kind: "quiet", facts: ["session.summary_changed"] });
feedItem("new");
check("in-flight-holds", reads === 2 && gets === 1);
release();
await settle();
check("change-in-flight-reads-again", reads === 3);
const last = release;
release = null;
last();
await settle();
check("burst-ends", reads === 3 && !feed.loading);
