// The live child tree. The agents plugin opens it; it holds no policy.
import { root } from "yuke:internal/core";
import { ui } from "yuke:internal/ui";
import { client, allChildren } from "yuke:internal/client";
import { focusedChat } from "yuke:internal/chat";
import { notice } from "yuke:internal/notice";
import { errorText } from "yuke:internal/format";

/** @import { InjectContext as Context } from "./types/ext.js" */
/** @import { EngineEvent } from "yuke:internal/native/engine" */
/** @typedef {{ item: Wire.SessionListItem, depth: number }} AgentRow */
/** @param {unknown} error */
function failed(error) { notice.show("agents · " + errorText(error)); }
/** The state words of a child. A spawn row passes the view it keeps, so the shape is only what the words read. */
/** @param {{ activity: Wire.SessionActivity, last_run?: Wire.RunOutcome | null }} child */
export function childState(child) {
  const state = child.activity.state;
  const queued = child.activity.queued;
  let label = state.type === "idle" ? child.last_run?.type === "turn" ? "completed" : child.last_run?.type ?? "idle" : state.type;
  if (state.type === "running_tool") label = "tool · " + state.tool_name;
  if (state.type === "waiting") label = "waiting";
  if (state.type === "streaming") label = "working";
  if (state.type === "building") label = "starting";
  if (state.type === "retrying") label = "retry " + state.attempt + "/" + state.max_attempts;
  return label + (queued ? " · " + queued + " queued" : "");
}
/** @param {Wire.SessionListItem[]} items */
function agentSummary(items) {
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
/** @param {Context} ctx @param {string} sessionId */
export async function openAgents(ctx, sessionId) {
  let alive = true;
  const currentChat = focusedChat();
  let items = await agentRows(sessionId);
  const mainId = items[0].item.session.id;
  const childItems = () => items.filter((row) => row.item.session.origin.type === "child").map((row) => row.item);
  if (!ctx.alive || currentChat !== focusedChat() || currentChat?.sessionId !== sessionId) return;
  const picker = ui.pick({
    title: agentSummary(childItems()), footer: "↵ open · x stop · X stop all agents · esc close",
    border: "rounded", width: max => Math.round(max * 0.9), height: max => Math.round(max * 0.6), filter: false,
    items, key: (row) => row.item.session.id,
    format: (row) => ({ marker: row.item.session.id === sessionId ? "◆" : row.item.session.origin.type !== "child" ? "·" : row.item.activity.state.type === "idle" ? "·" : "●", indent: 2 + row.depth * 2, text: (row.item.session.name ?? (row.item.session.id === mainId ? "Main conversation" : row.item.session.id)) + (row.item.session.id === sessionId ? " (current)" : ""), detail: row.item.session.model, right: row.item.session.id === mainId ? "main" : childState(row.item) }),
    onAccept: (row) => { close(); if (currentChat && currentChat === focusedChat() && currentChat.sessionId === sessionId) currentChat.open(row.item.session.id); },
    onCancel: () => close(),
    keymap: {
      x: (_event, content) => { const row = content.list.selected(); if (row && row.item.session.origin.type === "child") run(() => client.sessionCancelRun(row.item.session.id, true)); },
      X: () => run(async () => { const result = await Promise.allSettled(childItems().map((child) => client.sessionCancelRun(child.session.id, true))); notice.show("agents · stopped " + result.filter((r) => r.status === "fulfilled").length + " · failed " + result.filter((r) => r.status === "rejected").length); }),
    },
  });
  picker.content.list.selectKey(sessionId);
  // A new child lands in the index digest, which names no session; a listed child's state lands in its own digest.
  const off = ctx.on("index.changed", /** @param {EngineEvent} ev */ (ev) => { if (ev.type === "index" && (ev.overflow || ev.facts.includes("session.summary_changed"))) refresh(); });
  const offSession = ctx.on("session.changed", /** @param {Extract<EngineEvent, { type: "session" }>} ev */ (ev) => {
    if (!items.some((row) => row.item.session.id === ev.session)) return;
    if (ev.kind === "gone" || ev.facts.includes("run.done") || ev.facts.includes("session.summary_changed")) refresh();
    else if (ev.facts.includes("session.activity_changed")) refresh(ev.session);
  });
  /** @type {Set<string>} */
  const pending = new Set();
  const close = ctx.tui.overlay(picker.win, () => { alive = false; pending.clear(); off(); offSession(); });
  let refreshRunning = false;
  let reload = false;
  /** @param {string} [session] */
  function refresh(session) {
    if (!alive) return;
    if (session) pending.add(session);
    else { reload = true; pending.clear(); }
    if (refreshRunning) return;
    refreshRunning = true;
    (async () => {
      try {
        while (alive && (reload || pending.size)) {
          const full = reload;
          const changed = Array.from(pending);
          reload = false; pending.clear();
          try {
            if (full) {
              const next = await agentRows(mainId);
              if (!alive) return;
              items = next;
            } else {
              for (const id of changed) {
                const row = items.find(row => row.item.session.id === id);
                if (!row) continue;
                const next = await client.sessionGet(id);
                if (!alive) return;
                if (reload) break;
                row.item = next;
              }
            }
            if (!reload) { picker.win.opts.title = agentSummary(childItems()); picker.content.setSource(items); root.invalidate(); }
          } catch (error) { if (alive) failed(error); }
        }
      } finally { refreshRunning = false; }
    })();
  }
  /** @param {() => Promise<unknown>} action */
  function run(action) { action().catch(failed); }
  return picker;
}
