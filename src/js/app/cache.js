// yuke:cache — the `/cache` window: how much of this chat the provider served from its prompt cache.
import { root, text } from "yuke:core";
import { clip } from "yuke:text-input";
import { strokeOf } from "yuke:keys";
import { client } from "yuke:client";
import { Window } from "yuke:ui";
import { chatEntry } from "yuke:chat";
import { notice } from "yuke:notice";
import { catalogOf, tokenLabel } from "yuke:catalog";
import { sessionCost } from "yuke:context";

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

/** @param {number} n @returns {string} */
function money(n) {
  return "$" + n.toFixed(n < 1 ? 3 : 2);
}

/** @param {number} share @returns {string} */
function percent(share) {
  return (share * 100).toFixed(1) + "%";
}

// A ten-cell bar of the hit rate, so the window reads at a glance and not only as a number.
/** @param {number} share @returns {string} */
export function hitBar(share) {
  const full = Math.round(Math.max(0, Math.min(1, share)) * 10);
  return "[" + "█".repeat(full) + "░".repeat(10 - full) + "]";
}

// Build the label and value rows. The model must be in the catalog for the price rows to appear.
/** @param {Wire.Session} session @param {ReadonlyArray<Child> | null} [children] @returns {[string, string][]} */
export function cacheRows(session, children = []) {
  const t = session.usage_total;
  const model = catalogOf().models.find((m) => m.selector === session.model);
  const fresh = Math.max(0, t.input - t.cache_read - t.cache_write);
  /** @type {[string, string][]} */
  const rows = [
    ["hit", hitBar(hitRate(t)) + " " + percent(hitRate(t))],
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
  const model = catalogOf().models.find((m) => m.selector === selector);
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

class CachePanel {
  /** @param {Wire.Session} session @param {ReadonlyArray<Child>} children @param {() => void} onClose */
  constructor(session, children, onClose) {
    this.rows = cacheRows(session, children);
    this.onClose = onClose;
    /** @type {{ x: number, y: number, w: number, h: number }} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** @param {{ x: number, y: number, w: number, h: number }} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    for (let i = 0; i < this.rows.length; i++) {
      if (i >= h) break;
      const row = /** @type {[string, string]} */ (this.rows[i]);
      text(x, y + i, clip(row[0].padEnd(12), w), "UIDim");
      if (w > 12) text(x + 12, y + i, clip(row[1], w - 12), "UIQuery");
    }
  }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type === "key" && (strokeOf(event) === "esc" || strokeOf(event) === "q")) this.onClose();
    return true;
  }
}

/// One list answers a bounded page, so a chat with many agents needs this many reads at most.
const MAX_AGENT_PAGES = 32;

// Read the immediate children of one session. A chat that spawned no agent lists none.
/** @param {Wire.SessionId} id @returns {Promise<Child[]>} */
async function childrenOf(id) {
  /** @type {Child[]} */
  const out = [];
  /** @type {string | undefined} */
  let cursor = undefined;
  for (let page = 0; page < MAX_AGENT_PAGES; page++) {
    /** @type {Wire.SessionListResult} */
    const result = await client.sessionList({ population: { type: "children", parent_id: id }, cursor });
    for (const item of result.items) {
      out.push({ name: item.session.name || "agent", total: item.session.usage_total, model: item.session.model });
    }
    if (!result.next_cursor) return out;
    cursor = result.next_cursor;
  }
  return out;
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
          const children = await childrenOf(entry.session.id).catch(() => null);
          /** @type {(() => void)} */
          let release = () => {};
          const panel = new CachePanel(entry.session, children, () => release());
          const win = new Window({ title: "cache", footer: "esc close", border: "rounded", width: (max) => Math.round(max * 0.6), height: panel.rows.length + 2, content: panel });
          root.pushOverlay(win);
          release = ctx.tui.overlay(win);
        },
      }, {
        "cache:show": { title: "Cache", description: "show what the provider served from its prompt cache", slash: "cache" },
      });
    });
  },
};
