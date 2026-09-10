// yuke:context — the context reading on the status bar and the `/context` breakdown window.
import { root, text } from "yuke:core";
import { clip } from "yuke:text-input";
import { strokeOf } from "yuke:keys";
import { client } from "yuke:client";
import { Window } from "yuke:ui";
import { chatEntry } from "yuke:chat";
import { catalogOf, contextWindowOf, defaultModel, tokenLabel } from "yuke:catalog";

/** @import { Context } from "yuke:ext" */
/** @typedef {{ model: string, count: number, usage: Wire.TokenUsage, total: Wire.TokenUsage, queued: number, compaction: boolean }} Reading */
/** @typedef {{ bar?: string }} ContextConfig */

const BAR_CELLS = 6;
// The full and the empty glyph. Block Elements by default, because the terminal draws them and a font glyph can bleed.
const BAR_GLYPHS = "█░";
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
/** @param {number} used @param {number} window @param {number} [cells] @param {string} [glyphs] @returns {string} */
export function contextBar(used, window, cells = BAR_CELLS, glyphs = BAR_GLYPHS) {
  const full = window > 0 ? Math.round(Math.min(1, used / window) * cells) : 0;
  const pair = Array.from(glyphs);
  return "[" + String(pair[0]).repeat(full) + String(pair[1]).repeat(cells - full) + "]";
}

// The status words: the bar and the share of the window, or a token count for a model with no known window.
/** @param {Reading} r @param {string} [glyphs] @returns {string} */
export function contextLine(r, glyphs = BAR_GLYPHS) {
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
  return per(total.input, cost.input) + per(total.output, cost.output) + per(total.cache_read, cost.cache_read) + per(total.cache_write, cost.cache_write);
}

// Build the label and value rows of the breakdown window. The cost row needs the model in the catalog.
/** @param {Reading} r @param {ReadonlyArray<Wire.InstructionSource>} [sources] @param {ReadonlyArray<Wire.SkillInfo>} [skills] @returns {[string, string][]} */
export function contextRows(r, sources = [], skills = []) {
  const u = r.usage;
  const t = r.total;
  const model = catalogOf().models.find((m) => m.selector === r.model);
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
    rows.push(["cost", "$" + cost.toFixed(cost < 1 ? 3 : 2)]);
  }
  for (const source of sources) rows.push([source.scope + " AGENTS", source.path]);
  for (const skill of skills) rows.push([skill.scope + " skill", skill.name + " · " + skill.description]);
  return rows;
}

class ContextPanel {
  /** @param {Reading} r @param {ReadonlyArray<Wire.InstructionSource>} sources @param {ReadonlyArray<Wire.SkillInfo>} skills @param {() => void} onClose */
  constructor(r, sources, skills, onClose) {
    this.rows = contextRows(r, sources, skills);
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

export const contextPlugin = {
  name: "context",
  /** @param {Context} ctx @param {unknown} config @returns {void} */
  apply(ctx, config) {
    const cfg = /** @type {ContextConfig} */ (config || {});
    // Two glyphs, or the default. A user with a font that fits the parallelograms passes "▰▱" from index.js.
    const glyphs = typeof cfg.bar === "string" && Array.from(cfg.bar).length === 2 ? cfg.bar : BAR_GLYPHS;
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.status({ side: "right", order: 20, render: () => contextLine(reading(), glyphs) });

      ctx.tui.command(null, {
        "context:show": async () => {
          const current = reading();
          const entry = chatEntry();
          const item = entry ? await client.sessionGet(entry.session.id) : null;
          /** @type {(() => void)} */
          let release = () => {};
          const panel = new ContextPanel(current, item?.instruction_sources || [], item?.skills || [], () => release());
          const win = new Window({ title: "context", footer: "esc close", border: "rounded", width: max => Math.round(max * 0.6), height: panel.rows.length + 2, content: panel });
          root.pushOverlay(win);
          release = ctx.tui.overlay(win);
        },
      }, {
        "context:show": { title: "Context", description: "show the context and usage of this chat", slash: "context" },
      });
    });
  },
};
