// yuke:agents-ui — stored children and explicit user actions.
import { root } from "yuke:core";
import { ui } from "yuke:ui";
import { client } from "yuke:client";
import { focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { allChildren, stopAllChildren } from "yuke:agent-tools";
import { editSlot, recoverAgent } from "yuke:agents";

/** @typedef {import("yuke:ext").InjectContext} Context */
/** @typedef {import("yuke:engine-native").EngineEvent} EngineEvent */
/** @param {unknown} error */
function failed(error) { notice.show("agents · " + (/** @type {Error} */ (error)?.message || String(error))); }
/** @param {Wire.SessionListItem} child */
export function childState(child) {
  const state = child.activity.state.type;
  const queued = child.activity.queued ? " · queued " + child.activity.queued : "";
  const last = child.last_run ? " · last " + (child.last_run.type === "turn" ? "completed" : child.last_run.type) : "";
  return state + queued + last;
}
/** @param {Context} ctx */
async function configure(ctx) {
  const slot = await ctx.interaction.select("Subagent model slot", ["small", "medium"]);
  if (slot !== "small" && slot !== "medium") return;
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
  const parentId = sessionId;
  let alive = true;
  let generation = 0;
  let items = await allChildren(parentId);
  if (!ctx.scope.alive) return;
  const picker = ui.pick({
    title: "agents", footer: "↵ open · x stop · X stop all · r repair · m models · esc close",
    border: "rounded", width: 0.9, height: 0.6, filter: false,
    items, key: (child) => child.session.id,
    format: (child) => ({ text: child.session.name ?? child.session.id, detail: child.session.model, right: childState(child) }),
    onAccept: (child) => { close(); const chat = focusedChat(); if (chat) chat.open(child.session.id); },
    onCancel: () => close(),
    keymap: {
      x: (_event, content) => { const child = content.list.selected(); if (child) run(() => client.sessionCancelRun(child.session.id, true)); },
      X: () => run(async () => { const result = await stopAllChildren(parentId); notice.show("agents · stopped " + result.stopped + " · unchanged " + result.unchanged + " · failed " + result.failed); }),
      r: (_event, content) => { const child = content.list.selected(); if (child) { close(); repair(ctx, child).catch(failed); } },
      m: () => { close(); configure(ctx).catch(failed); },
    },
  });
  const release = ctx.tui.overlay(picker.win);
  // A new child lands in the index digest, which names no session; a listed child's state lands in its own digest.
  const off = ctx.on("index.changed", /** @param {EngineEvent} ev */ (ev) => { if (ev.facts.includes("session.summary_changed")) refresh(); });
  const offSession = ctx.on("session.changed", /** @param {Extract<EngineEvent, { type: "session" }>} ev */ (ev) => {
    if (!items.some((child) => child.session.id === ev.session)) return;
    if (ev.kind === "gone" || ev.facts.includes("session.activity_changed")) refresh();
  });
  const cleanup = ctx.effect(() => () => close());
  function close() {
    if (!alive) return;
    alive = false;
    generation++;
    off(); offSession(); release(); cleanup();
  }
  async function refresh() {
    const gen = ++generation;
    try { const next = await allChildren(parentId); if (alive && gen === generation) { items = next; picker.content.setSource(next); root.invalidate(); } }
    catch (error) { if (alive) failed(error); }
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
