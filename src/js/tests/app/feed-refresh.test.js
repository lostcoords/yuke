import { check } from "yuke:internal/test";
import { client } from "yuke:internal/client";
import { feedOf } from "yuke:internal/chat";

const feed = feedOf();
feed.seed({ items: [{ session: { id: "old" }, activity: null }] });
client.sessionList = async () => ({ items: [{ session: { id: "new" }, activity: null }] });
await feed.refresh();
check("refresh-replaces-state", !feed.loading && feed.items.has("new") && !feed.items.has("old"));
client.sessionList = async () => { throw new Error("read refused"); };
await feed.refresh();
check("refusal-retains-state", !feed.loading && feed.items.has("new"));


// The list reads only when a reader looks after a summary change, once per burst.
const { events } = await import("yuke:internal/kernel");
const { plugins } = await import("yuke:internal/ext");
const { tuiPlugin } = await import("yuke:internal/tui");
const { chatPlugin, feedItem } = await import("yuke:internal/chat");
plugins.use(tuiPlugin);
plugins.use(chatPlugin);
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
let reads = 0;
/** @type {(() => void) | null} */
let release = null;
client.sessionList = () => {
  reads++;
  // An open gate answers at once; a closed one holds the read in flight until `release`.
  if (!release) return Promise.resolve({ items: [] });
  return new Promise((resolve) => { release = () => resolve({ items: [] }); });
};
await feed.refresh();
reads = 0;
events.emit("index.changed", { type: "index", overflow: false, facts: ["catalog.changed", "notice"] });
feedItem("new");
check("unrelated-facts-read-nothing", reads === 0);
events.emit("index.changed", { type: "index", overflow: false, facts: ["session.summary_changed"] });
check("change-waits-for-reader", reads === 0);
feedItem("new");
feedItem("new");
check("reader-reads-once", reads === 1);
await settle();
// A change while a read is in flight earns one follow-up read, not one per reader.
release = () => {};
events.emit("index.changed", { type: "index", overflow: true, facts: [] });
feedItem("new");
events.emit("index.changed", { type: "index", overflow: false, facts: ["session.summary_changed"] });
feedItem("new");
feedItem("new");
check("in-flight-holds", reads === 2);
release();
await settle();
check("change-in-flight-reads-again", reads === 3);
const last = release;
release = null;
last();
await settle();
check("burst-ends", reads === 3 && !feed.loading);
