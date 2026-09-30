// The `/cache` window: how much of this chat the provider served from its prompt cache.
import { allChildren, client } from "yuke:internal/client";
import { showInfo } from "yuke:internal/info-panel";
import { currentEntry } from "yuke:internal/session";
import { modelOf } from "yuke:internal/catalog";
import { contextBar, costLabel, money, thousands, tokenLabel } from "yuke:internal/format";
import { notify } from "yuke:internal/kernel";

/** @import { Context } from "yuke:internal/ext" */
/** @typedef {{ name: string, total: Wire.TokenUsage, cost: Wire.SessionCost }} Child */

// The share of the input the provider read from its cache. A chat with no input reads nothing.
/** @param {Wire.TokenUsage} total @returns {number} */
export function hitRate(total) {
  if (total.input <= 0) return 0;
  // A peer that reports more cached tokens than input tokens still reads one whole and no more.
  return Math.min(1, total.cache_read / total.input);
}

// The saving of the priced turns. A cache write can cost more than a fresh token, so a cold cache can save less than nothing.
/** @param {Wire.SessionCost} cost @returns {string} */
function savedLabel(cost) {
  const saved = money(cost.without_cache - cost.total);
  return cost.unpriced > 0 ? saved + " · priced turns" : saved;
}

/** @param {number} share @returns {string} */
function percent(share) {
  return (share * 100).toFixed(1) + "%";
}

// Build the label and value rows. The engine priced each turn, so only the rate rows need the model in the catalog.
/** @param {Wire.Session} session @param {ReadonlyArray<Child> | null} [children] @param {Wire.TokenUsage | null} [last] @returns {[string, string][]} */
export function cacheRows(session, children = [], last = null) {
  const t = session.usage_total;
  const model = modelOf(session.model);
  const fresh = Math.max(0, t.input - t.cache_read - t.cache_write);
  const rate = hitRate(t);
  /** @type {[string, string][]} */
  const rows = [
    ["hit", contextBar(rate, 1, 10) + " " + percent(rate)],
  ];
  // The session rate moves slowly, so the newest turn shows a cold cache at once.
  if (last && last.input > 0) rows.push(["last turn", percent(hitRate(last))]);
  rows.push(["cached", tokenLabel(t.cache_read)]);
  rows.push(["fresh", tokenLabel(fresh)]);
  // Only a host that charges for a cache write reports one, so a zero row would be noise everywhere else.
  if (t.cache_write > 0) rows.push(["written", tokenLabel(t.cache_write)]);
  rows.push(["output", tokenLabel(t.output)]);
  rows.push(["reasoning", tokenLabel(t.reasoning)]);
  rows.push(["saved", savedLabel(session.cost)]);
  rows.push(["cost", costLabel(session.cost)]);
  // The model names itself even when the catalog prices it at nothing, because the name explains the rest.
  rows.push(["model", session.model]);
  // A later band prices the prompts above an exact size, so its label shows every digit.
  if (model) for (const band of model.cost) rows.push([band.min_prompt_tokens === 0 ? "rate" : "  >" + thousands(band.min_prompt_tokens - 1), rateLabelOf(band)]);
  // A null list is a read that failed, which must not read as a chat that spawned no agent.
  if (children === null) {
    rows.push(["agents", "unavailable"]);
  } else if (children.length > 0) {
    let total = 0, without_cache = 0, unpriced = 0;
    for (const c of children) {
      total += c.cost.total;
      without_cache += c.cost.without_cache;
      unpriced += c.cost.unpriced;
    }
    // This count covers one level, because a child of a child keeps its own window.
    rows.push(["agents", String(children.length) + " direct · saved " + savedLabel({ total, without_cache, unpriced })]);
    for (const c of children) rows.push(["  " + c.name, percent(hitRate(c.total)) + " · " + tokenLabel(c.total.input)]);
  }
  return rows;
}

// One price per million tokens. A price below a cent keeps its own digits rather than round to zero.
/** @param {number | null | undefined} price @returns {string} */
function rate(price) {
  if (price == null) return "?";
  return "$" + (price > 0 && price < 0.01 ? String(price) : price.toFixed(2));
}

// The prices of one band per million tokens. An unknown price reads "?", and never the input price.
/** @param {Wire.PriceBand} band @returns {string} */
export function rateLabelOf(band) {
  const write = band.cache_write == null ? "" : " · " + rate(band.cache_write) + " write";
  // Most vendors bill a reasoning token as an output token, so only a different price earns its own entry.
  const reasoning = band.reasoning === band.output ? "" : " · " + rate(band.reasoning) + " reasoning";
  return rate(band.input) + " in · " + rate(band.cache_read) + " cache" + write + " · " + rate(band.output) + " out" + reasoning + ", per 1M";
}


export const cachePlugin = {
  name: "cache",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.command.add("cache:show", {
        desc: "show what the provider served from its prompt cache",
        slash: "cache",
        run: async () => {
          const entry = currentEntry();
          // A chat with no session has read nothing, so the window would state zeros and explain none of them.
          if (!entry) return notify("info", "no session yet", "cache");
          // A null list says the read failed, so the window states that rather than claim no agent ran.
          const children = await allChildren(entry.session.id)
            .then((items) => items.map(({ session }) => ({ name: session.name || "agent", total: session.usage_total, cost: session.cost })))
            .catch(() => null);
          // A failed read drops only the last-turn row, because every other row reads the session.
          const info = await client.sessionContextInfo(entry.session.id).catch(() => null);
          showInfo(ctx, "cache", cacheRows(entry.session, children, info?.usage_last ?? null));
        },
      });
    });
  },
};
