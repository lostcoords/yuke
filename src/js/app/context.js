// The context reading on the status bar and the `/context` breakdown window.
import { client } from "yuke:internal/client";
import { showInfo } from "yuke:internal/info-panel";
import { currentEntry, currentSession, defaultModel, feedItem } from "yuke:internal/session";
import { modelOf } from "yuke:internal/catalog";
import { contextBar, costLabel, thousands, tokenLabel } from "yuke:internal/format";

/** @import { Context } from "yuke:internal/ext" */
/** @typedef {{ model: string, count: number, tokens: number, total: Wire.TokenUsage, cost: Wire.SessionCost | null, queued: number, compaction: boolean }} Reading */

/** @type {Wire.TokenUsage} */
const NO_TOKENS = { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 };

// The numbers the status line and the window read. With no session they describe the next chat.
/** @returns {Reading} */
function reading() {
  const e = currentEntry();
  if (!e) return { model: defaultModel().model || "", count: 0, tokens: 0, total: NO_TOKENS, cost: null, queued: 0, compaction: false };
  const a = e.activity;
  return {
    model: e.session.model,
    count: e.session.message_count,
    tokens: a.context_tokens,
    total: e.session.usage_total,
    cost: e.session.cost,
    queued: a.queued,
    compaction: a.pending_compaction != null,
  };
}

// The status words (the bar and the window share, or a token count with no known window) run on each frame, so they read only the two drawn numbers from the list item.
/** @returns {string} */
function contextLine() {
  const session = currentSession();
  const item = session?.sessionId ? feedItem(session.sessionId) : null;
  const used = item ? (session?.activity ?? item.activity).context_tokens : 0;
  const window = modelOf(item ? item.session.model : defaultModel().model)?.context_window ?? 0;
  if (window > 0) return contextBar(used, window) + " " + Math.round((used / window) * 100) + "% context";
  return tokenLabel(used) + " context";
}

// Build the label and value rows of the breakdown window. The engine priced each turn, so the cost row reads the session.
/** @param {Reading} r @param {Wire.TokenUsage} u @param {ReadonlyArray<Wire.InstructionSource>} sources @param {ReadonlyArray<Wire.SkillInfo>} skills @returns {[string, string][]} */
function contextRows(r, u, sources, skills) {
  const t = r.total;
  const model = modelOf(r.model);
  const window = (model && model.context_window) || 0;
  /** @type {[string, string][]} */
  const rows = [
    ["model", r.model],
    ["context", window > 0 ? thousands(r.tokens) + " / " + thousands(window) + " · " + Math.round((r.tokens / window) * 100) + "%" : thousands(r.tokens)],
    ["last turn", "in " + thousands(u.input) + " · out " + thousands(u.output) + " · reasoning " + thousands(u.reasoning)],
    ["cache", "read " + thousands(u.cache_read) + " · write " + thousands(u.cache_write)],
    ["session", "in " + thousands(t.input) + " · out " + thousands(t.output) + " · reasoning " + thousands(t.reasoning)],
    ["messages", String(r.count)],
    ["queued", String(r.queued)],
    ["compaction", r.compaction ? "pending" : "none"],
  ];
  // With no session the window describes the next chat, which has spent nothing.
  if (r.cost) rows.push(["cost", costLabel(r.cost)]);
  for (const source of sources) rows.push([source.scope + " AGENTS", source.path]);
  for (const skill of skills) rows.push([skill.scope + " skill", skill.name + " · " + skill.description]);
  return rows;
}


export const contextUsage = {
  name: "context",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.status.add({ side: "right", order: 20, render: contextLine });

      ctx.tui.command.add("context:show", {
        desc: "show the context and usage of this chat",
        slash: "context",
        run: async () => {
          const current = reading();
          const entry = currentEntry();
          const item = entry ? await client.sessionContextInfo(entry.session.id) : null;
          showInfo(ctx, "context", contextRows(current, item?.usage_last || NO_TOKENS, item?.instruction_sources || [], item?.skills || []));
        },
      });
    });
  },
};
