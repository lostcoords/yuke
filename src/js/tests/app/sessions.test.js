import { check } from "yuke:test";
import "yuke:core";
import { plugins } from "yuke:ext";
import { sessionsPlugin, feedOf, newestLocalModelSession } from "yuke:sessions";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin, {});

const feed = feedOf();
const mk = (id, model, at) => ({ session: { id, model, reasoning: "", updated_at_ms: at }, activity: null });

// The model status segment reads this on every frame, so it must be cached and correct.
feed.clear();
check("no-feed-no-model", newestLocalModelSession() === null);
feed.seed({ items: [mk("a", "old-model", 100), mk("b", "", 900), mk("c", "new-model", 500)] });
// "b" is newest but names no model, so the newest session that names one wins.
check("newest-with-model", (newestLocalModelSession() || {}).id === "c");

// The cache must stop the scan, not merely return the same answer.
let scans = 0;
const realValues = feed.items.values.bind(feed.items);
feed.items.values = () => { scans++; return realValues(); };
newestLocalModelSession();
check("cache-avoids-scan", scans === 0);
feed.seed({ items: [mk("d", "later-model", 1000)] });
check("recomputes-after-change", (newestLocalModelSession() || {}).id === "d");
check("rescans-after-change", scans === 1);
feed.items.values = realValues;
