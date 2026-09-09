import { check } from "yuke:test";
import { client } from "yuke:client";
import { feedOf } from "yuke:sessions";

const feed = feedOf();
feed.seed({ items: [{ session: { id: "old" }, activity: null }] });
client.sessionList = async () => ({ items: [{ session: { id: "new" }, activity: null }] });
await feed.refresh();
check("refresh-replaces-state", feed.loaded && !feed.loading && feed.items.has("new") && !feed.items.has("old"));
client.sessionList = async () => { throw new Error("read refused"); };
await feed.refresh();
check("refusal-retains-state", feed.loaded && !feed.loading && feed.items.has("new"));
