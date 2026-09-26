import { check, listSessions } from "yuke:internal/test";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { defaultModel, sessionsPlugin } from "yuke:internal/session";

plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
// Each entry counts the reads of its session, so a scan shows as a count.
let scans = 0;
/** @param {string} id @param {string} model @param {number} at */
const mk = (id, model, at) => {
  const session = { id, model, reasoning: "r-" + id, updated_at_ms: at };
  return { get session() { scans++; return session; }, activity: null };
};

await listSessions([]);
check("no-list-no-model", defaultModel().model === null);
await listSessions([mk("a", "old-model", 100), mk("b", "", 900), mk("c", "new-model", 500)]);
// "b" is newest but names no model, so the newest session that names one wins, with its reasoning.
const d = defaultModel();
check("newest-with-model", d.model === "new-model" && d.reasoning === "r-c");

// The status bar reads this on every frame, so an unchanged list costs no scan and no new answer.
scans = 0;
check("cache-avoids-scan", defaultModel() === d && scans === 0);
await listSessions([mk("d", "later-model", 1000)]);
check("recomputes-after-change", defaultModel().model === "later-model");
