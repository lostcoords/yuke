import { check } from "yuke:internal/test";
import { client } from "yuke:internal/client";
import { catalogRefresh } from "yuke:internal/catalog";
import { money } from "yuke:internal/format";
import { hitRate, cacheRows, rateLabelOf } from "yuke:internal/cache";

const usage = { input: 1000000, output: 20000, reasoning: 5000, cache_read: 900000, cache_write: 0 };
const cold = { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 };
const priced = { total: 0.5, without_cache: 2, unpriced: 0 };

check("hit-rate", hitRate(usage) === 0.9 && hitRate(cold) === 0);

// Every price reads to the cent, so a column of rates lines up.
check("rate", rateLabelOf({ min_prompt_tokens: 0, input: 0.2, cache_read: 0.02, output: 1.2, reasoning: 1.2 }) === "$0.20 in · $0.02 cache · $1.20 out, per 1M");
// An unknown cache price reads "?", and never the input price.
check("rate-no-cache", rateLabelOf({ min_prompt_tokens: 0, input: 3, output: 15, reasoning: 15 }) === "$3.00 in · ? cache · $15.00 out, per 1M");
// A price under a cent keeps its own digits rather than round away to nothing.
check("rate-sub-cent", rateLabelOf({ min_prompt_tokens: 0, input: 0.005, cache_read: 0.001, output: 0.01, reasoning: 0.01 }) === "$0.005 in · $0.001 cache · $0.01 out, per 1M");
// A reasoning price that differs from the output price gets its own entry.
check("rate-reasoning", rateLabelOf({ min_prompt_tokens: 0, input: 2, output: 8, reasoning: 3 }) === "$2.00 in · ? cache · $8.00 out · $3.00 reasoning, per 1M");

const session = { id: "s1", model: "unknown/model", usage_total: usage, cost: priced };
const rows = cacheRows(session);
const label = (/** @type {string} */ name) => (rows.find((r) => r[0] === name) || [])[1];
check("rows-hit", String(label("hit")).indexOf("90.0%") > 0);
check("rows-cached", label("cached") === "900k");
// The input total holds the cached subset, so the fresh row is the remainder and never the whole input.
check("rows-fresh", label("fresh") === "100k");
check("rows-output", label("output") === "20k" && label("reasoning") === "5.0k");
// The engine priced each turn, so a model outside the catalog still states its cost and saving.
check("rows-cost", label("cost") === "$0.500" && label("saved") === "$1.50");
// A chat that spawned no agent lists no agent rows.
check("rows-no-agents", label("agents") === undefined);
// The session rate moves slowly, so the newest turn states its own rate.
const fresh = cacheRows(session, [], { input: 1000, output: 0, reasoning: 0, cache_read: 0, cache_write: 1000 });
check("rows-last-turn", (fresh.find((r) => r[0] === "last turn") || [])[1] === "0.0%");
check("rows-no-last-turn", label("last turn") === undefined);

// An unpriced turn makes the cost a floor, and the saving covers the priced turns alone.
const partial = cacheRows({ ...session, cost: { total: 0.5, without_cache: 0.4, unpriced: 2 } });
const plabel = (/** @type {string} */ name) => (partial.find((r) => r[0] === name) || [])[1];
check("rows-unpriced", plabel("cost") === "≥ $0.500 · 2 turns unpriced");
// A cache write costs more than a fresh token, so a cold cache saves less than nothing.
check("rows-loss", plabel("saved") === "-$0.100 · priced turns");
// A float rest below the shown precision is not a loss.
check("money-rest", money(-1e-18) === "$0.000" && money(-0.1) === "-$0.100" && money(12) === "$12.00");

const withKids = cacheRows(session, [{ name: "overview", total: usage, cost: priced }, { name: "tests", total: usage, cost: { total: 1, without_cache: 1, unpriced: 1 } }]);
check("rows-agents", (withKids.find((r) => r[0] === "agents") || [])[1] === "2 direct · saved $1.50 · priced turns");
check("rows-agent-line", withKids.some((r) => r[0] === "  overview"));

// A peer that reports more cached tokens than input tokens still reads one whole and no more.
check("hit-rate-over", hitRate({ input: 100, output: 0, reasoning: 0, cache_read: 150, cache_write: 0 }) === 1);
check("hit-rate-empty", hitRate({ input: 0, output: 0, reasoning: 0, cache_read: 50, cache_write: 0 }) === 0);

// A host that writes its cache reports those tokens, and they leave the fresh row.
const written = { input: 1000000, output: 0, reasoning: 0, cache_read: 100000, cache_write: 400000 };
const wrows = cacheRows({ id: "s2", model: "unknown/model", usage_total: written, cost: priced });
const wlabel = (/** @type {string} */ name) => (wrows.find((r) => r[0] === name) || [])[1];
check("rows-written", wlabel("written") === "400k" && wlabel("fresh") === "500k");
// A host that writes nothing shows no write row, because a zero row is noise on every other host.
check("rows-no-written", rows.find((r) => r[0] === "written") === undefined);
// A model outside the catalog still names itself, because the name explains the missing prices.
check("rows-model-always", wlabel("model") === "unknown/model" && wlabel("rate") === undefined);
// A write price joins the rate line only when the model names one.
check("rate-write", rateLabelOf({ min_prompt_tokens: 0, input: 3, cache_read: 0.3, cache_write: 3.75, output: 15, reasoning: 15 }) === "$3.00 in · $0.30 cache · $3.75 write · $15.00 out, per 1M");
// A failed child read is not a chat without agents, so the window says so.
const failed = cacheRows({ id: "s3", model: "unknown/model", usage_total: usage, cost: priced }, null);
check("rows-agents-failed", (failed.find((r) => r[0] === "agents") || [])[1] === "unavailable");

// A model with two bands shows one rate row each, and the second names the exact prompt size that it starts above.
client.catalogList = () => Promise.resolve({ type: "full", catalog_rev: "r1", providers: [], models: [{
  id: "gpt", provider: "p", selector: "p/gpt", name: "gpt", reasoning_levels: [], default_reasoning: "",
  cost: [{ min_prompt_tokens: 0, input: 4, output: 20, reasoning: 20 }, { min_prompt_tokens: 272001, input: 8, output: 30, reasoning: 30 }],
}] });
await catalogRefresh.run();
const banded = cacheRows({ ...session, model: "p/gpt" });
check("rows-bands", banded.filter((r) => r[1].endsWith("per 1M")).map((r) => r[0]).join("|") === "rate|  >272,000");
// Every label fits the twelve-column gutter, or it overruns the value beside it.
check("rows-fit", [withKids, failed, wrows, fresh, banded].every((all) => all.every((r) => r[0].length <= 12)));
