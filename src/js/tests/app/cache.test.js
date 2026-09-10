import { check } from "yuke:test";
import { hitRate, cacheSaving, hitBar, cacheRows, rateLabelOf } from "yuke:cache";

const usage = { input: 1000000, output: 20000, reasoning: 5000, cache_read: 900000, cache_write: 0 };
const cold = { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 };

check("hit-rate", hitRate(usage) === 0.9 && hitRate(cold) === 0);
// A model that names no cache price reads every cached token at the input price, so it saves nothing.
check("saving", cacheSaving(usage, { input: 10, cache_read: 2 }) === 7.2 && cacheSaving(usage, { input: 10 }) === 0);
check("saving-unpriced", cacheSaving(usage, {}) === 0);
check("bar", hitBar(0) === "[░░░░░░░░░░]" && hitBar(1) === "[██████████]" && hitBar(0.5) === "[█████░░░░░]");
// A share outside the range still draws ten cells rather than a broken row.
check("bar-clamped", hitBar(-1) === "[░░░░░░░░░░]" && hitBar(9) === "[██████████]");

// Every price reads to the cent, so a column of rates lines up.
check("rate", rateLabelOf({ input: 0.2, cache_read: 0.02, output: 1.2 }) === "$0.20 in · $0.02 cache · $1.20 out, per 1M");
// A model that names no cache price reads the cached tokens at the input price.
check("rate-no-cache", rateLabelOf({ input: 3, output: 15 }) === "$3.00 in · $3.00 cache · $15.00 out, per 1M");
// A price under a cent keeps its own digits rather than round away to nothing.
check("rate-sub-cent", rateLabelOf({ input: 0.005, cache_read: 0.001, output: 0.01 }) === "$0.005 in · $0.001 cache · $0.01 out, per 1M");
check("rate-unpriced", rateLabelOf({}) === "? in · ? cache · ? out, per 1M");

const session = { id: "s1", model: "unknown/model", usage_total: usage };
const rows = cacheRows(session);
const label = (/** @type {string} */ name) => (rows.find((r) => r[0] === name) || [])[1];
check("rows-hit", String(label("hit")).indexOf("90.0%") > 0);
check("rows-cached", label("cached") === "900k");
// The input total holds the cached subset, so the fresh row is the remainder and never the whole input.
check("rows-fresh", label("fresh") === "100k");
check("rows-output", label("output") === "20k" && label("reasoning") === "5.0k");
// A model outside the catalog has no price, so the window shows the counts and drops the money rows.
check("rows-unpriced", label("saved") === undefined && label("cost") === undefined);
// A chat that spawned no agent lists no agent rows.
check("rows-no-agents", label("agents") === undefined);

const withKids = cacheRows(session, [{ name: "overview", total: usage, model: "unknown/model" }]);
check("rows-agents", (withKids.find((r) => r[0] === "agents") || [])[1] === "1 direct · saved $0.000");
check("rows-agent-line", withKids.some((r) => r[0] === "  overview"));

// A model with no input price cannot compare two prices, so it states no saving rather than a negative one.
check("saving-no-input", cacheSaving(usage, { cache_read: 2 }) === 0 && cacheSaving(usage, { input: null, cache_read: 2 }) === 0);
// A host that prices the cache at nothing saves the whole input price.
check("saving-free-cache", cacheSaving(usage, { input: 10, cache_read: 0 }) === 9);
// A peer that reports more cached tokens than input tokens still reads one whole and no more.
check("hit-rate-over", hitRate({ input: 100, output: 0, reasoning: 0, cache_read: 150, cache_write: 0 }) === 1);
check("hit-rate-empty", hitRate({ input: 0, output: 0, reasoning: 0, cache_read: 50, cache_write: 0 }) === 0);

// A host that writes its cache reports those tokens, and they leave the fresh row.
const written = { input: 1000000, output: 0, reasoning: 0, cache_read: 100000, cache_write: 400000 };
const wrows = cacheRows({ id: "s2", model: "unknown/model", usage_total: written });
const wlabel = (/** @type {string} */ name) => (wrows.find((r) => r[0] === name) || [])[1];
check("rows-written", wlabel("written") === "400k" && wlabel("fresh") === "500k");
// A host that writes nothing shows no write row, because a zero row is noise on every other host.
check("rows-no-written", rows.find((r) => r[0] === "written") === undefined);
// A model outside the catalog still names itself, because the name explains the missing prices.
check("rows-model-always", wlabel("model") === "unknown/model" && wlabel("rate") === undefined);
// A write price joins the rate line only when the model names one.
check("rate-write", rateLabelOf({ input: 3, cache_read: 0.3, cache_write: 3.75, output: 15 }) === "$3.00 in · $0.30 cache · $3.75 write · $15.00 out, per 1M");
// A failed child read is not a chat without agents, so the window says so.
const failed = cacheRows({ id: "s3", model: "unknown/model", usage_total: usage }, null);
check("rows-agents-failed", (failed.find((r) => r[0] === "agents") || [])[1] === "unavailable");
// Every label fits the twelve-column gutter, or it overruns the value beside it.
check("rows-fit", withKids.every((r) => r[0].length <= 12) && failed.every((r) => r[0].length <= 12) && wrows.every((r) => r[0].length <= 12));
