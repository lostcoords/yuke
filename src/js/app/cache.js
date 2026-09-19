// yuke:cache — the `/cache` window: how much of this chat the provider served from its prompt cache.
import { allChildren } from "yuke:client";
import { showInfo } from "yuke:info-panel";
import { chatEntry } from "yuke:chat";
import { notice } from "yuke:notice";
import { modelOf, tokenLabel } from "yuke:catalog";
import { contextBar, money, sessionCost } from "yuke:context";

/** @import { Context } from "yuke:ext" */
/** @typedef {{ name: string, total: Wire.TokenUsage, model: string }} Child */

// The share of the input the provider read from its cache. A chat with no input reads nothing.
/** @param {Wire.TokenUsage} total @returns {number} */
export function hitRate(total) {
  if (total.input <= 0) return 0;
  // A peer that reports more cached tokens than input tokens still reads one whole and no more.
  return Math.min(1, total.cache_read / total.input);
}

// The saving compares the fresh price of the cached tokens with the price the cache charged.
/** @param {Wire.TokenUsage} total @param {Wire.ModelCost} cost @returns {number} */
export function cacheSaving(total, cost) {
  // Without an input price there is nothing to compare, so the cache saved an unknown amount.
  if (cost.input == null) return 0;
  const cached = cost.cache_read == null ? cost.input : cost.cache_read;
  return (total.cache_read / 1e6) * (cost.input - cached);
}

/** @param {number} share @returns {string} */
function percent(share) {
  return (share * 100).toFixed(1) + "%";
}

// Build the label and value rows. The model must be in the catalog for the price rows to appear.
/** @param {Wire.Session} session @param {ReadonlyArray<Child> | null} [children] @returns {[string, string][]} */
export function cacheRows(session, children = []) {
  const t = session.usage_total;
  const model = modelOf(session.model);
  const fresh = Math.max(0, t.input - t.cache_read - t.cache_write);
  const rate = hitRate(t);
  /** @type {[string, string][]} */
  const rows = [
    ["hit", contextBar(rate, 1, 10) + " " + percent(rate)],
    ["cached", tokenLabel(t.cache_read)],
    ["fresh", tokenLabel(fresh)],
  ];
  // Only a host that charges for a cache write reports one, so a zero row would be noise everywhere else.
  if (t.cache_write > 0) rows.push(["written", tokenLabel(t.cache_write)]);
  rows.push(["output", tokenLabel(t.output)]);
  rows.push(["reasoning", tokenLabel(t.reasoning)]);
  if (model) {
    rows.push(["saved", money(cacheSaving(t, model.cost))]);
    rows.push(["cost", money(sessionCost(t, model.cost))]);
  }
  // The model names itself even when the catalog prices it at nothing, because the name explains the rest.
  rows.push(["model", session.model]);
  if (model) rows.push(["rate", rateLabelOf(model.cost)]);
  // A null list is a read that failed, which must not read as a chat that spawned no agent.
  if (children === null) {
    rows.push(["agents", "unavailable"]);
  } else if (children.length > 0) {
    const sum = children.reduce((n, c) => n + cacheSaving(c.total, costOf(c.model)), 0);
    // This count covers one level, because a child of a child keeps its own window.
    rows.push(["agents", String(children.length) + " direct · saved " + money(sum)]);
    for (const c of children) rows.push(["  " + c.name, percent(hitRate(c.total)) + " · " + tokenLabel(c.total.input)]);
  }
  return rows;
}

/** @param {string} selector @returns {Wire.ModelCost} */
function costOf(selector) {
  const model = modelOf(selector);
  return model ? model.cost : {};
}

// One price per million tokens. A price below a cent keeps its own digits rather than round to zero.
/** @param {number | null | undefined} price @returns {string} */
function rate(price) {
  if (price == null) return "?";
  return "$" + (price > 0 && price < 0.01 ? String(price) : price.toFixed(2));
}

// The three prices one million tokens pay. A model that names no cache price reads at the input price.
/** @param {Wire.ModelCost} cost @returns {string} */
export function rateLabelOf(cost) {
  const write = cost.cache_write == null ? "" : " · " + rate(cost.cache_write) + " write";
  return rate(cost.input) + " in · " + rate(cost.cache_read == null ? cost.input : cost.cache_read) + " cache" + write + " · " + rate(cost.output) + " out, per 1M";
}


export const cachePlugin = {
  name: "cache",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.command(null, {
        "cache:show": async () => {
          const entry = chatEntry();
          // A chat with no session has read nothing, so the window would state zeros and explain none of them.
          if (!entry) return notice.show("no session yet");
          // A null list says the read failed, so the window states that rather than claim no agent ran.
          const children = await allChildren(entry.session.id)
            .then((items) => items.map(({ session }) => ({ name: session.name || "agent", total: session.usage_total, model: session.model })))
            .catch(() => null);
          showInfo(ctx, "cache", cacheRows(entry.session, children));
        },
      }, {
        "cache:show": { title: "Cache", description: "show what the provider served from its prompt cache", slash: "cache" },
      });
    });
  },
};
