// yuke:agents-ui — stored children and explicit user actions.
import { root } from "yuke:core";
import { ui } from "yuke:ui";
import { client } from "yuke:client";
import { focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { allChildren } from "yuke:agent-tools";
import { editSlot, recoverAgent } from "yuke:agents";

/** @typedef {import("yuke:ext").InjectContext} Context */
/** @typedef {import("yuke:engine-native").EngineEvent} EngineEvent */
/** @typedef {{ item: Wire.SessionListItem, depth: number }} AgentRow */
/** @param {unknown} error */
function failed(error) { notice.show("agents · " + (/** @type {Error} */ (error)?.message || String(error))); }
/** @param {Wire.SessionListItem} child */
export function childState(child) {
  const state = child.activity.state;
  const queued = child.activity.queued;
  let label = state.type === "idle" ? child.last_run?.type === "turn" ? "completed" : child.last_run?.type ?? "idle" : state.type;
  if (state.type === "running_tool") label = "tool · " + state.tool_name;
  if (state.type === "running") label = "working";
  if (state.type === "building") label = "starting";
  if (state.type === "retrying") label = "retry " + state.attempt + "/" + state.max_attempts;
  return label + (queued ? " · " + queued + " queued" : "");
}
/** @param {Wire.SessionListItem[]} items */
export function agentSummary(items) {
  let active = 0, queued = 0;
  for (const child of items) {
    if (child.activity.state.type !== "idle") active++;
    if (child.activity.queued > 0) queued++;
  }
  return items.length ? "agents · " + active + " active · " + queued + " queued · " + items.length + " total" : "agents · no children yet";
}
/** @param {string} sessionId @returns {Promise<Wire.SessionListItem>} */
async function rootSession(sessionId) {
  const seen = new Set(); let id = sessionId;
  while (true) {
    if (seen.has(id)) throw new Error("The session ancestry contains a cycle.");
    seen.add(id);
    const item = await client.sessionGet(id);
    if (item.session.origin.type !== "child") return item;
    id = item.session.origin.site.session_id;
  }
}
/** @param {string} sessionId @returns {Promise<AgentRow[]>} */
async function descendantRows(sessionId) {
  /** @type {AgentRow[]} */
  const rows = [];
  const seen = new Set([sessionId]);
  /** @param {string} parentId @param {number} parentDepth */
  async function visit(parentId, parentDepth) {
    const children = await allChildren(parentId);
    for (const child of children) {
      if (seen.has(child.session.id)) continue;
      seen.add(child.session.id);
      const depth = parentDepth + 1;
      rows.push({ item: child, depth });
      await visit(child.session.id, depth);
    }
  }
  await visit(sessionId, 0);
  return rows;
}
/** @param {string} sessionId @returns {Promise<[AgentRow, ...AgentRow[]]>} */
export async function agentRows(sessionId) {
  const main = await rootSession(sessionId);
  return [{ item: main, depth: 0 }, ...await descendantRows(main.session.id)];
}
/** @param {Context} ctx */
async function configure(ctx) {
  const current = await client.agentsGet();
  const choices = ["Small · " + (current.config.models?.small?.model ?? "Not configured"), "Medium · " + (current.config.models?.medium?.model ?? "Not configured")];
  const choice = await ctx.interaction.select("Agent models", choices);
  const slot = choice === choices[0] ? "small" : choice === choices[1] ? "medium" : null;
  if (!slot) return;
  await editSlot(ctx, slot);
}
/** @param {Context} ctx @param {Wire.SessionListItem} child */
async function repair(ctx, child) {
  if (child.activity.state.type !== "idle" || child.activity.queued) { notice.show("stop the child's work before repair"); return; }
  await recoverAgent(ctx, child.session.id, undefined, undefined);
  const input = await ctx.interaction.input("Continue " + child.session.name, "new instruction; completed tools stay in history");
  if (input?.trim()) await client.sessionSendInput(child.session.id, input);
}
/** @param {Context} ctx @param {string} sessionId */
export async function openAgents(ctx, sessionId) {
  let alive = true;
  const currentChat = focusedChat();
  let items = await agentRows(sessionId);
  const mainId = items[0].item.session.id;
  const childItems = () => items.filter((row) => row.item.session.origin.type === "child").map((row) => row.item);
  if (!ctx.scope.alive || currentChat !== focusedChat() || currentChat?.sessionId !== sessionId) return;
  const picker = ui.pick({
    title: agentSummary(childItems()), footer: "↵ open · x stop · X stop all agents · r repair · m models · esc close",
    border: "rounded", width: 0.9, height: 0.6, filter: false,
    items, key: (row) => row.item.session.id,
    format: (row) => ({ marker: row.item.session.id === sessionId ? "◆" : row.item.session.origin.type !== "child" ? "·" : row.item.activity.state.type === "idle" ? "·" : "●", indent: 2 + row.depth * 2, text: (row.item.session.name ?? (row.item.session.id === mainId ? "Main conversation" : row.item.session.id)) + (row.item.session.id === sessionId ? " (current)" : ""), detail: row.item.session.model, right: row.item.session.id === mainId ? "main" : childState(row.item) }),
    onAccept: (row) => { close(); if (currentChat && currentChat === focusedChat() && currentChat.sessionId === sessionId) currentChat.open(row.item.session.id); },
    onCancel: () => close(),
    keymap: {
      x: (_event, content) => { const row = content.list.selected(); if (row && row.item.session.origin.type === "child") run(() => client.sessionCancelRun(row.item.session.id, true)); },
      X: () => run(async () => { const result = await Promise.allSettled(childItems().map((child) => client.sessionCancelRun(child.session.id, true))); notice.show("agents · stopped " + result.filter((r) => r.status === "fulfilled").length + " · failed " + result.filter((r) => r.status === "rejected").length); }),
      r: (_event, content) => { const row = content.list.selected(); if (row && row.item.session.origin.type === "child") { close(); repair(ctx, row.item).catch(failed); } },
      m: () => { close(); configure(ctx).catch(failed); },
    },
  });
  picker.content.selectKey(sessionId);
  const release = ctx.tui.overlay(picker.win);
  // A new child lands in the index digest, which names no session; a listed child's state lands in its own digest.
  const off = ctx.on("index.changed", /** @param {EngineEvent} ev */ (ev) => { if (ev.facts.includes("session.summary_changed")) refresh(); });
  const offSession = ctx.on("session.changed", /** @param {Extract<EngineEvent, { type: "session" }>} ev */ (ev) => {
    if (!items.some((row) => row.item.session.id === ev.session)) return;
    if (ev.kind === "gone" || ev.facts.includes("session.activity_changed") || ev.facts.includes("run.done") || ev.facts.includes("session.summary_changed")) refresh();
  });
  const cleanup = ctx.effect(() => () => close());
  function close() {
    if (!alive) return;
    alive = false;
    off(); offSession(); release(); cleanup();
  }
  let refreshRunning = false;
  let refreshAgain = false;
  function refresh() {
    if (refreshRunning) { refreshAgain = true; return; }
    refreshRunning = true;
    (async () => {
      try {
        const next = await agentRows(mainId);
        if (alive) { items = next; picker.win.opts.title = agentSummary(childItems()); picker.content.setSource(next); root.invalidate(); }
      } catch (error) { if (alive) failed(error); }
      finally {
        refreshRunning = false;
        if (alive && refreshAgain) { refreshAgain = false; refresh(); }
      }
    })();
  }
  /** @param {() => Promise<unknown>} action */
  function run(action) { action().catch(failed); }
  return picker;
}

export const agentsUiPlugin = {
  name: "agents-ui",
  /** @param {import("yuke:ext").Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.command(() => focusedChat()?.sessionId != null, {
        "agents:open": () => { const id = focusedChat()?.sessionId; if (id) openAgents(ctx, id).catch(failed); },
      }, { "agents:open": { title: "Agents", description: "open or stop child agents", slash: "agents" } });
      ctx.tui.command(null, { "agents:models": () => configure(ctx).catch(failed) }, {
        "agents:models": { title: "Agent models", description: "set the small and medium model slots", slash: "agent-models" },
      });
    });
  },
};
