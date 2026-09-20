// yuke:context — the context reading on the status bar and the `/context` breakdown window.
import { client } from "yuke:client";
import { showInfo } from "yuke:info-panel";
import { chatEntry } from "yuke:chat";
import { modelOf, contextWindowOf, defaultModel, tokenLabel } from "yuke:catalog";

/** @import { Context } from "yuke:ext" */
/** @typedef {{ model: string, count: number, usage: Wire.TokenUsage, total: Wire.TokenUsage, queued: number, compaction: boolean }} Reading */
/** @typedef {{ bar?: string }} ContextConfig */

const BAR_CELLS = 6;
// The full and the empty glyph. Block Elements by default, because the terminal draws them and a font glyph can bleed.
/** @type {readonly [string, string]} */
const BAR_GLYPHS = ["█", "░"];
/** @type {Wire.TokenUsage} */
const NO_TOKENS = { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 };

// The numbers the status line and the window read. With no session they describe the next chat.
/** @returns {Reading} */
export function reading() {
  const e = chatEntry();
  if (!e) return { model: defaultModel().model || "", count: 0, usage: NO_TOKENS, total: NO_TOKENS, queued: 0, compaction: false };
  const a = e.activity;
  return {
    model: e.session.model,
    count: e.session.message_count,
    usage: a.context_usage,
    total: e.session.usage_total,
    queued: a.queued,
    compaction: a.pending_compaction != null,
  };
}

// A bar of `cells` glyphs in proportion. `glyphs` holds the full glyph, then the empty one.
/** @param {number} used @param {number} window @param {number} [cells] @param {string | readonly [string, string]} [glyphs] @returns {string} */
export function contextBar(used, window, cells = BAR_CELLS, glyphs = BAR_GLYPHS) {
  const full = window > 0 ? Math.round(Math.min(1, used / window) * cells) : 0;
  const pair = typeof glyphs === "string" ? Array.from(glyphs) : glyphs;
  return "[" + String(pair[0]).repeat(full) + String(pair[1]).repeat(cells - full) + "]";
}

// The status words: the bar and the share of the window, or a token count for a model with no known window.
/** @param {Reading} r @param {readonly [string, string]} [glyphs] @returns {string} */
function contextLine(r, glyphs = BAR_GLYPHS) {
  const used = r.usage.input;
  const window = contextWindowOf(r.model);
  if (window > 0) return contextBar(used, window, BAR_CELLS, glyphs) + " " + Math.round((used / window) * 100) + "% context";
  return tokenLabel(used) + " context";
}

/** @param {number} n @returns {string} */
function thousands(n) {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// The cost of the tokens at the catalog prices in dollars per million. An unpriced kind costs nothing.
/** @param {Wire.TokenUsage} total @param {Wire.ModelCost} cost @returns {number} */
export function sessionCost(total, cost) {
  const per = (/** @type {number} */ n, /** @type {number | undefined} */ price) => (n / 1e6) * (price || 0);
  // The input total holds both cache subsets, so only the remainder pays the full input price.
  const fresh = Math.max(0, total.input - total.cache_read - total.cache_write);
  return per(fresh, cost.input) + per(total.output, cost.output) + per(total.cache_read, cost.cache_read) + per(total.cache_write, cost.cache_write);
}

/** @param {number} n @returns {string} */
export function money(n) {
  return "$" + n.toFixed(n < 1 ? 3 : 2);
}

// Build the label and value rows of the breakdown window. The cost row needs the model in the catalog.
/** @param {Reading} r @param {ReadonlyArray<Wire.InstructionSource>} [sources] @param {ReadonlyArray<Wire.SkillInfo>} [skills] @returns {[string, string][]} */
function contextRows(r, sources = [], skills = []) {
  const u = r.usage;
  const t = r.total;
  const model = modelOf(r.model);
  const window = (model && model.context_window) || 0;
  /** @type {[string, string][]} */
  const rows = [
    ["model", r.model],
    ["context", window > 0 ? thousands(u.input) + " / " + thousands(window) + " · " + Math.round((u.input / window) * 100) + "%" : thousands(u.input)],
    ["last turn", "in " + thousands(u.input) + " · out " + thousands(u.output) + " · reasoning " + thousands(u.reasoning)],
    ["cache", "read " + thousands(u.cache_read) + " · write " + thousands(u.cache_write)],
    ["session", "in " + thousands(t.input) + " · out " + thousands(t.output) + " · reasoning " + thousands(t.reasoning)],
    ["messages", String(r.count)],
    ["queued", String(r.queued)],
    ["compaction", r.compaction ? "pending" : "none"],
  ];
  if (model) {
    const cost = sessionCost(t, model.cost);
    rows.push(["cost", money(cost)]);
  }
  for (const source of sources) rows.push([source.scope + " AGENTS", source.path]);
  for (const skill of skills) rows.push([skill.scope + " skill", skill.name + " · " + skill.description]);
  return rows;
}


/** @param {ContextConfig} [cfg] */
export function contextUsage(cfg = {}) {
  return {
  name: "context",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    // Two glyphs, or the default. A user with a font that fits the parallelograms passes "▰▱" from index.js.
    // Normalize the pair once here, so a status render allocates nothing for it.
    const custom = typeof cfg.bar === "string" ? Array.from(cfg.bar) : null;
    const glyphs = custom && custom.length === 2 ? /** @type {[string, string]} */ ([custom[0], custom[1]]) : BAR_GLYPHS;
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.status({ side: "right", order: 20, render: () => contextLine(reading(), glyphs) });

      ctx.tui.command(null, {
        "context:show": async () => {
          const current = reading();
          const entry = chatEntry();
          const item = entry ? await client.sessionGet(entry.session.id) : null;
          showInfo(ctx, "context", contextRows(current, item?.instruction_sources || [], item?.skills || []));
        },
      }, {
        "context:show": { title: "Context", description: "show the context and usage of this chat", slash: "context" },
      });
    });
  },
  };
}
